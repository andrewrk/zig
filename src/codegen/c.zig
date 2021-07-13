const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const log = std.log.scoped(.c);

const link = @import("../link.zig");
const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const ir = @import("../air.zig");
const Inst = ir.Inst;
const Value = @import("../value.zig").Value;
const Type = @import("../type.zig").Type;
const TypedValue = @import("../TypedValue.zig");
const C = link.File.C;
const Decl = Module.Decl;
const trace = @import("../tracy.zig").trace;
const LazySrcLoc = Module.LazySrcLoc;

const Mutability = enum { Const, Mut };

pub const CValue = union(enum) {
    none: void,
    /// Index into local_names
    local: usize,
    /// Index into local_names, but take the address.
    local_ref: usize,
    /// A constant instruction, to be rendered inline.
    constant: *Inst,
    /// Index into the parameters
    arg: usize,
    /// By-value
    decl: *Decl,
    decl_ref: *Decl,
};

const BlockData = struct {
    block_id: usize,
    result: CValue,
};

pub const CValueMap = std.AutoHashMap(*Inst, CValue);
pub const TypedefMap = std.ArrayHashMap(
    Type,
    struct { name: []const u8, rendered: []u8 },
    Type.HashContext32,
    true,
);

fn formatTypeAsCIdentifier(
    data: Type,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    var buffer = [1]u8{0} ** 128;
    // We don't care if it gets cut off, it's still more unique than a number
    var buf = std.fmt.bufPrint(&buffer, "{}", .{data}) catch &buffer;
    return formatIdent(buf, "", .{}, writer);
}

pub fn typeToCIdentifier(t: Type) std.fmt.Formatter(formatTypeAsCIdentifier) {
    return .{ .data = t };
}

fn formatIdent(
    ident: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    for (ident) |c, i| {
        switch (c) {
            'a'...'z', 'A'...'Z', '_' => try writer.writeByte(c),
            '.' => try writer.writeByte('_'),
            '0'...'9' => if (i == 0) {
                try writer.print("_{x:2}", .{c});
            } else {
                try writer.writeByte(c);
            },
            else => try writer.print("_{x:2}", .{c}),
        }
    }
}

pub fn fmtIdent(ident: []const u8) std.fmt.Formatter(formatIdent) {
    return .{ .data = ident };
}

/// This data is available when outputting .c code for a Module.
/// It is not available when generating .h file.
pub const Object = struct {
    dg: DeclGen,
    gpa: *mem.Allocator,
    code: std.ArrayList(u8),
    value_map: CValueMap,
    blocks: std.AutoHashMapUnmanaged(*ir.Inst.Block, BlockData) = .{},
    next_arg_index: usize = 0,
    next_local_index: usize = 0,
    next_block_index: usize = 0,
    indent_writer: IndentWriter(std.ArrayList(u8).Writer),

    fn resolveInst(o: *Object, inst: *Inst) !CValue {
        if (inst.value()) |_| {
            return CValue{ .constant = inst };
        }
        return o.value_map.get(inst).?; // Instruction does not dominate all uses!
    }

    fn allocLocalValue(o: *Object) CValue {
        const result = o.next_local_index;
        o.next_local_index += 1;
        return .{ .local = result };
    }

    fn allocLocal(o: *Object, ty: Type, mutability: Mutability) !CValue {
        const local_value = o.allocLocalValue();
        try o.renderTypeAndName(o.writer(), ty, local_value, mutability);
        return local_value;
    }

    fn writer(o: *Object) IndentWriter(std.ArrayList(u8).Writer).Writer {
        return o.indent_writer.writer();
    }

    fn writeCValue(o: *Object, w: anytype, c_value: CValue) !void {
        switch (c_value) {
            .none => unreachable,
            .local => |i| return w.print("t{d}", .{i}),
            .local_ref => |i| return w.print("&t{d}", .{i}),
            .constant => |inst| return o.dg.renderValue(w, inst.ty, inst.value().?),
            .arg => |i| return w.print("a{d}", .{i}),
            .decl => |decl| return w.writeAll(mem.span(decl.name)),
            .decl_ref => |decl| return w.print("&{s}", .{decl.name}),
        }
    }

    fn renderTypeAndName(
        o: *Object,
        w: anytype,
        ty: Type,
        name: CValue,
        mutability: Mutability,
    ) error{ OutOfMemory, AnalysisFail }!void {
        var suffix = std.ArrayList(u8).init(o.gpa);
        defer suffix.deinit();

        var render_ty = ty;
        while (render_ty.zigTypeTag() == .Array) {
            const sentinel_bit = @boolToInt(render_ty.sentinel() != null);
            const c_len = render_ty.arrayLen() + sentinel_bit;
            try suffix.writer().print("[{d}]", .{c_len});
            render_ty = render_ty.elemType();
        }

        if (render_ty.zigTypeTag() == .Fn) {
            const ret_ty = render_ty.fnReturnType();
            if (ret_ty.zigTypeTag() == .NoReturn) {
                // noreturn attribute is not allowed here.
                try w.writeAll("void");
            } else {
                try o.dg.renderType(w, ret_ty);
            }
            try w.writeAll(" (*");
            switch (mutability) {
                .Const => try w.writeAll("const "),
                .Mut => {},
            }
            try o.writeCValue(w, name);
            try w.writeAll(")(");
            const param_len = render_ty.fnParamLen();
            const is_var_args = render_ty.fnIsVarArgs();
            if (param_len == 0 and !is_var_args)
                try w.writeAll("void")
            else {
                var index: usize = 0;
                while (index < param_len) : (index += 1) {
                    if (index > 0) {
                        try w.writeAll(", ");
                    }
                    try o.dg.renderType(w, render_ty.fnParamType(index));
                }
            }
            if (is_var_args) {
                if (param_len != 0) try w.writeAll(", ");
                try w.writeAll("...");
            }
            try w.writeByte(')');
        } else {
            try o.dg.renderType(w, render_ty);

            const const_prefix = switch (mutability) {
                .Const => "const ",
                .Mut => "",
            };
            try w.print(" {s}", .{const_prefix});
            try o.writeCValue(w, name);
        }
        try w.writeAll(suffix.items);
    }
};

/// This data is available both when outputting .c code and when outputting an .h file.
pub const DeclGen = struct {
    module: *Module,
    decl: *Decl,
    fwd_decl: std.ArrayList(u8),
    error_msg: ?*Module.ErrorMsg,
    typedefs: TypedefMap,

    fn fail(dg: *DeclGen, src: LazySrcLoc, comptime format: []const u8, args: anytype) error{ AnalysisFail, OutOfMemory } {
        @setCold(true);
        const src_loc = src.toSrcLocWithDecl(dg.decl);
        dg.error_msg = try Module.ErrorMsg.create(dg.module.gpa, src_loc, format, args);
        return error.AnalysisFail;
    }

    fn renderValue(
        dg: *DeclGen,
        writer: anytype,
        t: Type,
        val: Value,
    ) error{ OutOfMemory, AnalysisFail }!void {
        if (val.isUndef()) {
            // This should lower to 0xaa bytes in safe modes, and for unsafe modes should
            // lower to leaving variables uninitialized (that might need to be implemented
            // outside of this function).
            return dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement renderValue undef", .{});
        }
        switch (t.zigTypeTag()) {
            .Int => {
                if (t.isSignedInt())
                    return writer.print("{d}", .{val.toSignedInt()});
                return writer.print("{d}", .{val.toUnsignedInt()});
            },
            .Pointer => switch (t.ptrSize()) {
                .Slice => {
                    try writer.writeByte('(');
                    try dg.renderType(writer, t);
                    try writer.writeAll("){");
                    var buf: Type.Payload.ElemType = undefined;
                    try dg.renderValue(writer, t.slicePtrFieldType(&buf), val);
                    try writer.writeAll(", ");
                    try writer.print("{d}", .{val.sliceLen()});
                    try writer.writeAll("}");
                },
                else => switch (val.tag()) {
                    .null_value, .zero => try writer.writeAll("NULL"),
                    .one => try writer.writeAll("1"),
                    .decl_ref => {
                        const decl = val.castTag(.decl_ref).?.data;

                        // Determine if we must pointer cast.
                        assert(decl.has_tv);
                        if (t.eql(decl.ty)) {
                            try writer.print("&{s}", .{decl.name});
                        } else {
                            try writer.writeAll("(");
                            try dg.renderType(writer, t);
                            try writer.print(")&{s}", .{decl.name});
                        }
                    },
                    .function => {
                        const func = val.castTag(.function).?.data;
                        try writer.print("{s}", .{func.owner_decl.name});
                    },
                    .extern_fn => {
                        const decl = val.castTag(.extern_fn).?.data;
                        try writer.print("{s}", .{decl.name});
                    },
                    else => switch (t.ptrSize()) {
                        .Slice => unreachable,
                        .Many => {
                            if (val.castTag(.ref_val)) |ref_val_payload| {
                                const sub_val = ref_val_payload.data;
                                if (sub_val.castTag(.bytes)) |bytes_payload| {
                                    const bytes = bytes_payload.data;
                                    try writer.writeByte('(');
                                    try dg.renderType(writer, t);
                                    // TODO: make our own C string escape instead of using std.zig.fmtEscapes
                                    try writer.print(")\"{}\"", .{std.zig.fmtEscapes(bytes)});
                                } else {
                                    unreachable;
                                }
                            } else {
                                unreachable;
                            }
                        },
                        .One => {
                            var arena = std.heap.ArenaAllocator.init(dg.module.gpa);
                            defer arena.deinit();

                            const elem_ty = t.elemType();
                            const elem_val = try val.pointerDeref(&arena.allocator);

                            try writer.writeAll("&");
                            try dg.renderValue(writer, elem_ty, elem_val);
                        },
                        .C => unreachable,
                    },
                },
            },
            .Array => {
                // First try specific tag representations for more efficiency.
                switch (val.tag()) {
                    .undef, .empty_struct_value, .empty_array => try writer.writeAll("{}"),
                    .bytes => {
                        const bytes = val.castTag(.bytes).?.data;
                        // TODO: make our own C string escape instead of using std.zig.fmtEscapes
                        try writer.print("\"{}\"", .{std.zig.fmtEscapes(bytes)});
                    },
                    else => {
                        // Fall back to generic implementation.
                        var arena = std.heap.ArenaAllocator.init(dg.module.gpa);
                        defer arena.deinit();

                        try writer.writeAll("{");
                        var index: usize = 0;
                        const len = t.arrayLen();
                        const elem_ty = t.elemType();
                        while (index < len) : (index += 1) {
                            if (index != 0) try writer.writeAll(",");
                            const elem_val = try val.elemValue(&arena.allocator, index);
                            try dg.renderValue(writer, elem_ty, elem_val);
                        }
                        if (t.sentinel()) |sentinel_val| {
                            if (index != 0) try writer.writeAll(",");
                            try dg.renderValue(writer, elem_ty, sentinel_val);
                        }
                        try writer.writeAll("}");
                    },
                }
            },
            .Bool => return writer.print("{}", .{val.toBool()}),
            .Optional => {
                var opt_buf: Type.Payload.ElemType = undefined;
                const child_type = t.optionalChild(&opt_buf);
                if (t.isPtrLikeOptional()) {
                    return dg.renderValue(writer, child_type, val);
                }
                try writer.writeByte('(');
                try dg.renderType(writer, t);
                if (val.tag() == .null_value) {
                    try writer.writeAll("){ .is_null = true }");
                } else {
                    try writer.writeAll("){ .is_null = false, .payload = ");
                    try dg.renderValue(writer, child_type, val);
                    try writer.writeAll(" }");
                }
            },
            .ErrorSet => {
                const payload = val.castTag(.@"error").?;
                // error values will be #defined at the top of the file
                return writer.print("zig_error_{s}", .{payload.data.name});
            },
            .ErrorUnion => {
                const error_type = t.errorUnionSet();
                const payload_type = t.errorUnionChild();
                const data = val.castTag(.error_union).?.data;

                if (!payload_type.hasCodeGenBits()) {
                    // We use the error type directly as the type.
                    return dg.renderValue(writer, error_type, data);
                }

                try writer.writeByte('(');
                try dg.renderType(writer, t);
                try writer.writeAll("){");
                if (val.getError()) |_| {
                    try writer.writeAll(" .error = ");
                    try dg.renderValue(
                        writer,
                        error_type,
                        data,
                    );
                    try writer.writeAll(" }");
                } else {
                    try writer.writeAll(" .payload = ");
                    try dg.renderValue(
                        writer,
                        payload_type,
                        data,
                    );
                    try writer.writeAll(", .error = 0 }");
                }
            },
            .Enum => {
                switch (val.tag()) {
                    .enum_field_index => {
                        const field_index = val.castTag(.enum_field_index).?.data;
                        switch (t.tag()) {
                            .enum_simple => return writer.print("{d}", .{field_index}),
                            .enum_full, .enum_nonexhaustive => {
                                const enum_full = t.cast(Type.Payload.EnumFull).?.data;
                                if (enum_full.values.count() != 0) {
                                    const tag_val = enum_full.values.keys()[field_index];
                                    return dg.renderValue(writer, enum_full.tag_ty, tag_val);
                                } else {
                                    return writer.print("{d}", .{field_index});
                                }
                            },
                            else => unreachable,
                        }
                    },
                    else => {
                        var int_tag_ty_buffer: Type.Payload.Bits = undefined;
                        const int_tag_ty = t.intTagType(&int_tag_ty_buffer);
                        return dg.renderValue(writer, int_tag_ty, val);
                    },
                }
            },
            .Fn => switch (val.tag()) {
                .null_value, .zero => try writer.writeAll("NULL"),
                .one => try writer.writeAll("1"),
                .decl_ref => {
                    const decl = val.castTag(.decl_ref).?.data;

                    // Determine if we must pointer cast.
                    assert(decl.has_tv);
                    if (t.eql(decl.ty)) {
                        try writer.print("&{s}", .{decl.name});
                    } else {
                        try writer.writeAll("(");
                        try dg.renderType(writer, t);
                        try writer.print(")&{s}", .{decl.name});
                    }
                },
                .function => {
                    const func = val.castTag(.function).?.data;
                    try writer.print("{s}", .{func.owner_decl.name});
                },
                .extern_fn => {
                    const decl = val.castTag(.extern_fn).?.data;
                    try writer.print("{s}", .{decl.name});
                },
                else => unreachable,
            },
            else => |e| return dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement value {s}", .{
                @tagName(e),
            }),
        }
    }

    fn renderFunctionSignature(dg: *DeclGen, w: anytype, is_global: bool) !void {
        if (!is_global) {
            try w.writeAll("static ");
        }
        if (dg.decl.val.castTag(.function)) |func_payload| {
            const func: *Module.Fn = func_payload.data;
            if (func.is_cold) {
                try w.writeAll("ZIG_COLD ");
            }
        }
        try dg.renderType(w, dg.decl.ty.fnReturnType());
        const decl_name = mem.span(dg.decl.name);
        try w.print(" {s}(", .{decl_name});
        const param_len = dg.decl.ty.fnParamLen();
        const is_var_args = dg.decl.ty.fnIsVarArgs();
        if (param_len == 0 and !is_var_args)
            try w.writeAll("void")
        else {
            var index: usize = 0;
            while (index < param_len) : (index += 1) {
                if (index > 0) {
                    try w.writeAll(", ");
                }
                try dg.renderType(w, dg.decl.ty.fnParamType(index));
                try w.print(" a{d}", .{index});
            }
        }
        if (is_var_args) {
            if (param_len != 0) try w.writeAll(", ");
            try w.writeAll("...");
        }
        try w.writeByte(')');
    }

    fn renderType(dg: *DeclGen, w: anytype, t: Type) error{ OutOfMemory, AnalysisFail }!void {
        switch (t.zigTypeTag()) {
            .NoReturn => {
                try w.writeAll("zig_noreturn void");
            },
            .Void => try w.writeAll("void"),
            .Bool => try w.writeAll("bool"),
            .Int => {
                switch (t.tag()) {
                    .u8 => try w.writeAll("uint8_t"),
                    .i8 => try w.writeAll("int8_t"),
                    .u16 => try w.writeAll("uint16_t"),
                    .i16 => try w.writeAll("int16_t"),
                    .u32 => try w.writeAll("uint32_t"),
                    .i32 => try w.writeAll("int32_t"),
                    .u64 => try w.writeAll("uint64_t"),
                    .i64 => try w.writeAll("int64_t"),
                    .usize => try w.writeAll("uintptr_t"),
                    .isize => try w.writeAll("intptr_t"),
                    .c_short => try w.writeAll("short"),
                    .c_ushort => try w.writeAll("unsigned short"),
                    .c_int => try w.writeAll("int"),
                    .c_uint => try w.writeAll("unsigned int"),
                    .c_long => try w.writeAll("long"),
                    .c_ulong => try w.writeAll("unsigned long"),
                    .c_longlong => try w.writeAll("long long"),
                    .c_ulonglong => try w.writeAll("unsigned long long"),
                    .int_signed, .int_unsigned => {
                        const info = t.intInfo(dg.module.getTarget());
                        const sign_prefix = switch (info.signedness) {
                            .signed => "",
                            .unsigned => "u",
                        };
                        inline for (.{ 8, 16, 32, 64, 128 }) |nbits| {
                            if (info.bits <= nbits) {
                                try w.print("{s}int{d}_t", .{ sign_prefix, nbits });
                                break;
                            }
                        } else {
                            return dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement integer types larger than 128 bits", .{});
                        }
                    },
                    else => unreachable,
                }
            },

            .Float => return dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement type Float", .{}),

            .Pointer => {
                if (t.isSlice()) {
                    if (dg.typedefs.get(t)) |some| {
                        return w.writeAll(some.name);
                    }

                    var buffer = std.ArrayList(u8).init(dg.typedefs.allocator);
                    defer buffer.deinit();
                    const bw = buffer.writer();

                    try bw.writeAll("typedef struct { ");
                    const elem_type = t.elemType();
                    try dg.renderType(bw, elem_type);
                    try bw.writeAll(" *");
                    if (t.isConstPtr()) {
                        try bw.writeAll("const ");
                    }
                    if (t.isVolatilePtr()) {
                        try bw.writeAll("volatile ");
                    }
                    try bw.writeAll("ptr; size_t len; } ");
                    const name_index = buffer.items.len;
                    try bw.print("zig_L_{s};\n", .{typeToCIdentifier(elem_type)});

                    const rendered = buffer.toOwnedSlice();
                    errdefer dg.typedefs.allocator.free(rendered);
                    const name = rendered[name_index .. rendered.len - 2];

                    try dg.typedefs.ensureUnusedCapacity(1);
                    try w.writeAll(name);
                    dg.typedefs.putAssumeCapacityNoClobber(t, .{ .name = name, .rendered = rendered });
                } else {
                    try dg.renderType(w, t.elemType());
                    try w.writeAll(" *");
                    if (t.isConstPtr()) {
                        try w.writeAll("const ");
                    }
                    if (t.isVolatilePtr()) {
                        try w.writeAll("volatile ");
                    }
                }
            },
            .Array => {
                try dg.renderType(w, t.elemType());
                try w.writeAll(" *");
            },
            .Optional => {
                var opt_buf: Type.Payload.ElemType = undefined;
                const child_type = t.optionalChild(&opt_buf);
                if (t.isPtrLikeOptional()) {
                    return dg.renderType(w, child_type);
                } else if (dg.typedefs.get(t)) |some| {
                    return w.writeAll(some.name);
                }

                var buffer = std.ArrayList(u8).init(dg.typedefs.allocator);
                defer buffer.deinit();
                const bw = buffer.writer();

                try bw.writeAll("typedef struct { ");
                try dg.renderType(bw, child_type);
                try bw.writeAll(" payload; bool is_null; } ");
                const name_index = buffer.items.len;
                try bw.print("zig_Q_{s};\n", .{typeToCIdentifier(child_type)});

                const rendered = buffer.toOwnedSlice();
                errdefer dg.typedefs.allocator.free(rendered);
                const name = rendered[name_index .. rendered.len - 2];

                try dg.typedefs.ensureUnusedCapacity(1);
                try w.writeAll(name);
                dg.typedefs.putAssumeCapacityNoClobber(t, .{ .name = name, .rendered = rendered });
            },
            .ErrorSet => {
                comptime std.debug.assert(Type.initTag(.anyerror).abiSize(std.Target.current) == 2);
                try w.writeAll("uint16_t");
            },
            .ErrorUnion => {
                if (dg.typedefs.get(t)) |some| {
                    return w.writeAll(some.name);
                }
                const child_type = t.errorUnionChild();
                const err_set_type = t.errorUnionSet();

                if (!child_type.hasCodeGenBits()) {
                    return dg.renderType(w, err_set_type);
                }

                var buffer = std.ArrayList(u8).init(dg.typedefs.allocator);
                defer buffer.deinit();
                const bw = buffer.writer();

                try bw.writeAll("typedef struct { ");
                try dg.renderType(bw, child_type);
                try bw.writeAll(" payload; uint16_t error; } ");
                const name_index = buffer.items.len;
                if (err_set_type.castTag(.error_set_inferred)) |inf_err_set_payload| {
                    const func = inf_err_set_payload.data.func;
                    try bw.print("zig_E_{s};\n", .{func.owner_decl.name});
                } else {
                    try bw.print("zig_E_{s}_{s};\n", .{
                        typeToCIdentifier(err_set_type), typeToCIdentifier(child_type),
                    });
                }

                const rendered = buffer.toOwnedSlice();
                errdefer dg.typedefs.allocator.free(rendered);
                const name = rendered[name_index .. rendered.len - 2];

                try dg.typedefs.ensureUnusedCapacity(1);
                try w.writeAll(name);
                dg.typedefs.putAssumeCapacityNoClobber(t, .{ .name = name, .rendered = rendered });
            },
            .Struct => {
                if (dg.typedefs.get(t)) |some| {
                    return w.writeAll(some.name);
                }
                const struct_obj = t.castTag(.@"struct").?.data; // Handle 0 bit types elsewhere.
                const fqn = try struct_obj.getFullyQualifiedName(dg.typedefs.allocator);
                defer dg.typedefs.allocator.free(fqn);

                var buffer = std.ArrayList(u8).init(dg.typedefs.allocator);
                defer buffer.deinit();

                try buffer.appendSlice("typedef struct {\n");
                {
                    var it = struct_obj.fields.iterator();
                    while (it.next()) |entry| {
                        try buffer.append(' ');
                        try dg.renderType(buffer.writer(), entry.value_ptr.ty);
                        try buffer.writer().print(" {s};\n", .{fmtIdent(entry.key_ptr.*)});
                    }
                }
                try buffer.appendSlice("} ");

                const name_start = buffer.items.len;
                try buffer.writer().print("zig_S_{s};\n", .{fmtIdent(fqn)});

                const rendered = buffer.toOwnedSlice();
                errdefer dg.typedefs.allocator.free(rendered);
                const name = rendered[name_start .. rendered.len - 2];

                try dg.typedefs.ensureUnusedCapacity(1);
                try w.writeAll(name);
                dg.typedefs.putAssumeCapacityNoClobber(t, .{ .name = name, .rendered = rendered });
            },
            .Enum => {
                // For enums, we simply use the integer tag type.
                var int_tag_ty_buffer: Type.Payload.Bits = undefined;
                const int_tag_ty = t.intTagType(&int_tag_ty_buffer);

                try dg.renderType(w, int_tag_ty);
            },
            .Union => return dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement type Union", .{}),
            .Fn => {
                try dg.renderType(w, t.fnReturnType());
                try w.writeAll(" (*)(");
                const param_len = t.fnParamLen();
                const is_var_args = t.fnIsVarArgs();
                if (param_len == 0 and !is_var_args)
                    try w.writeAll("void")
                else {
                    var index: usize = 0;
                    while (index < param_len) : (index += 1) {
                        if (index > 0) {
                            try w.writeAll(", ");
                        }
                        try dg.renderType(w, t.fnParamType(index));
                    }
                }
                if (is_var_args) {
                    if (param_len != 0) try w.writeAll(", ");
                    try w.writeAll("...");
                }
                try w.writeByte(')');
            },
            .Opaque => return dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement type Opaque", .{}),
            .Frame => return dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement type Frame", .{}),
            .AnyFrame => return dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement type AnyFrame", .{}),
            .Vector => return dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement type Vector", .{}),

            .Null,
            .Undefined,
            .EnumLiteral,
            .ComptimeFloat,
            .ComptimeInt,
            .Type,
            => unreachable, // must be const or comptime

            .BoundFn => unreachable, // this type will be deleted from the language
        }
    }

    fn declIsGlobal(dg: *DeclGen, tv: TypedValue) bool {
        switch (tv.val.tag()) {
            .extern_fn => return true,
            .function => {
                const func = tv.val.castTag(.function).?.data;
                return dg.module.decl_exports.contains(func.owner_decl);
            },
            .variable => {
                const variable = tv.val.castTag(.variable).?.data;
                return dg.module.decl_exports.contains(variable.owner_decl);
            },
            else => unreachable,
        }
    }
};

pub fn genDecl(o: *Object) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const tv: TypedValue = .{
        .ty = o.dg.decl.ty,
        .val = o.dg.decl.val,
    };
    if (tv.val.castTag(.function)) |func_payload| {
        const func: *Module.Fn = func_payload.data;
        if (func.owner_decl == o.dg.decl) {
            const is_global = o.dg.declIsGlobal(tv);
            const fwd_decl_writer = o.dg.fwd_decl.writer();
            if (is_global) {
                try fwd_decl_writer.writeAll("ZIG_EXTERN_C ");
            }
            try o.dg.renderFunctionSignature(fwd_decl_writer, is_global);
            try fwd_decl_writer.writeAll(";\n");

            try o.indent_writer.insertNewline();
            try o.dg.renderFunctionSignature(o.writer(), is_global);

            try o.writer().writeByte(' ');
            try genBody(o, func.body);

            try o.indent_writer.insertNewline();
            return;
        }
    }
    if (tv.val.tag() == .extern_fn) {
        const writer = o.writer();
        try writer.writeAll("ZIG_EXTERN_C ");
        try o.dg.renderFunctionSignature(writer, true);
        try writer.writeAll(";\n");
    } else if (tv.val.castTag(.variable)) |var_payload| {
        const variable: *Module.Var = var_payload.data;
        const is_global = o.dg.declIsGlobal(tv);
        const fwd_decl_writer = o.dg.fwd_decl.writer();
        if (is_global or variable.is_extern) {
            try fwd_decl_writer.writeAll("ZIG_EXTERN_C ");
        }
        if (variable.is_threadlocal) {
            try fwd_decl_writer.writeAll("zig_threadlocal ");
        }
        try o.dg.renderType(fwd_decl_writer, o.dg.decl.ty);
        const decl_name = mem.span(o.dg.decl.name);
        try fwd_decl_writer.print(" {s};\n", .{decl_name});

        try o.indent_writer.insertNewline();
        const w = o.writer();
        try o.dg.renderType(w, o.dg.decl.ty);
        try w.print(" {s} = ", .{decl_name});
        if (variable.init.tag() != .unreachable_value) {
            try o.dg.renderValue(w, tv.ty, variable.init);
        }
        try w.writeAll(";");
        try o.indent_writer.insertNewline();
    } else {
        const writer = o.writer();
        try writer.writeAll("static ");

        // TODO ask the Decl if it is const
        // https://github.com/ziglang/zig/issues/7582

        const decl_c_value: CValue = .{ .decl = o.dg.decl };
        try o.renderTypeAndName(writer, tv.ty, decl_c_value, .Mut);

        try writer.writeAll(" = ");
        try o.dg.renderValue(writer, tv.ty, tv.val);
        try writer.writeAll(";\n");
    }
}

pub fn genHeader(dg: *DeclGen) error{ AnalysisFail, OutOfMemory }!void {
    const tracy = trace(@src());
    defer tracy.end();

    const tv: TypedValue = .{
        .ty = dg.decl.ty,
        .val = dg.decl.val,
    };
    const writer = dg.fwd_decl.writer();

    switch (tv.ty.zigTypeTag()) {
        .Fn => {
            const is_global = dg.declIsGlobal(tv);
            if (is_global) {
                try writer.writeAll("ZIG_EXTERN_C ");
                try dg.renderFunctionSignature(writer, is_global);
                try dg.fwd_decl.appendSlice(";\n");
            }
        },
        else => {},
    }
}

pub fn genBody(o: *Object, body: ir.Body) error{ AnalysisFail, OutOfMemory }!void {
    const writer = o.writer();
    if (body.instructions.len == 0) {
        try writer.writeAll("{}");
        return;
    }

    try writer.writeAll("{\n");
    o.indent_writer.pushIndent();

    for (body.instructions) |inst| {
        const result_value = switch (inst.tag) {
            // TODO use a different strategy for add that communicates to the optimizer
            // that wrapping is UB.
            .add => try genBinOp(o, inst.castTag(.add).?, " + "),
            .addwrap => try genWrapOp(o, inst.castTag(.addwrap).?, " + ", "addw_"),
            // TODO use a different strategy for sub that communicates to the optimizer
            // that wrapping is UB.
            .sub => try genBinOp(o, inst.castTag(.sub).?, " - "),
            .subwrap => try genWrapOp(o, inst.castTag(.subwrap).?, " - ", "subw_"),
            // TODO use a different strategy for mul that communicates to the optimizer
            // that wrapping is UB.
            .mul => try genBinOp(o, inst.castTag(.sub).?, " * "),
            .mulwrap => try genWrapOp(o, inst.castTag(.mulwrap).?, " * ", "mulw_"),
            // TODO use a different strategy for div that communicates to the optimizer
            // that wrapping is UB.
            .div => try genBinOp(o, inst.castTag(.div).?, " / "),

            .constant => unreachable, // excluded from function bodies
            .alloc => try genAlloc(o, inst.castTag(.alloc).?),
            .arg => genArg(o),
            .assembly => try genAsm(o, inst.castTag(.assembly).?),
            .block => try genBlock(o, inst.castTag(.block).?),
            .bitcast => try genBitcast(o, inst.castTag(.bitcast).?),
            .breakpoint => try genBreakpoint(o, inst.castTag(.breakpoint).?),
            .call => try genCall(o, inst.castTag(.call).?),
            .cmp_eq => try genBinOp(o, inst.castTag(.cmp_eq).?, " == "),
            .cmp_gt => try genBinOp(o, inst.castTag(.cmp_gt).?, " > "),
            .cmp_gte => try genBinOp(o, inst.castTag(.cmp_gte).?, " >= "),
            .cmp_lt => try genBinOp(o, inst.castTag(.cmp_lt).?, " < "),
            .cmp_lte => try genBinOp(o, inst.castTag(.cmp_lte).?, " <= "),
            .cmp_neq => try genBinOp(o, inst.castTag(.cmp_neq).?, " != "),
            .dbg_stmt => try genDbgStmt(o, inst.castTag(.dbg_stmt).?),
            .intcast => try genCast(o, inst.castTag(.intcast).?),
            .load => try genLoad(o, inst.castTag(.load).?),
            .ret => try genRet(o, inst.castTag(.ret).?),
            .retvoid => try genRetVoid(o),
            .store => try genStore(o, inst.castTag(.store).?),
            .unreach => try genUnreach(o, inst.castTag(.unreach).?),
            .loop => try genLoop(o, inst.castTag(.loop).?),
            .condbr => try genCondBr(o, inst.castTag(.condbr).?),
            .br => try genBr(o, inst.castTag(.br).?),
            .br_void => try genBrVoid(o, inst.castTag(.br_void).?.block),
            .switchbr => try genSwitchBr(o, inst.castTag(.switchbr).?),
            // bool_and and bool_or are non-short-circuit operations
            .bool_and => try genBinOp(o, inst.castTag(.bool_and).?, " & "),
            .bool_or => try genBinOp(o, inst.castTag(.bool_or).?, " | "),
            .bit_and => try genBinOp(o, inst.castTag(.bit_and).?, " & "),
            .bit_or => try genBinOp(o, inst.castTag(.bit_or).?, " | "),
            .xor => try genBinOp(o, inst.castTag(.xor).?, " ^ "),
            .not => try genUnOp(o, inst.castTag(.not).?, "!"),
            .is_null => try genIsNull(o, inst.castTag(.is_null).?),
            .is_non_null => try genIsNull(o, inst.castTag(.is_non_null).?),
            .is_null_ptr => try genIsNull(o, inst.castTag(.is_null_ptr).?),
            .is_non_null_ptr => try genIsNull(o, inst.castTag(.is_non_null_ptr).?),
            .wrap_optional => try genWrapOptional(o, inst.castTag(.wrap_optional).?),
            .optional_payload => try genOptionalPayload(o, inst.castTag(.optional_payload).?),
            .optional_payload_ptr => try genOptionalPayload(o, inst.castTag(.optional_payload_ptr).?),
            .ref => try genRef(o, inst.castTag(.ref).?),
            .struct_field_ptr => try genStructFieldPtr(o, inst.castTag(.struct_field_ptr).?),

            .is_err => try genIsErr(o, inst.castTag(.is_err).?, "", ".", "!="),
            .is_non_err => try genIsErr(o, inst.castTag(.is_non_err).?, "", ".", "=="),
            .is_err_ptr => try genIsErr(o, inst.castTag(.is_err_ptr).?, "*", "->", "!="),
            .is_non_err_ptr => try genIsErr(o, inst.castTag(.is_non_err_ptr).?, "*", "->", "=="),

            .unwrap_errunion_payload => try genUnwrapErrUnionPay(o, inst.castTag(.unwrap_errunion_payload).?),
            .unwrap_errunion_err => try genUnwrapErrUnionErr(o, inst.castTag(.unwrap_errunion_err).?),
            .unwrap_errunion_payload_ptr => try genUnwrapErrUnionPay(o, inst.castTag(.unwrap_errunion_payload_ptr).?),
            .unwrap_errunion_err_ptr => try genUnwrapErrUnionErr(o, inst.castTag(.unwrap_errunion_err_ptr).?),
            .wrap_errunion_payload => try genWrapErrUnionPay(o, inst.castTag(.wrap_errunion_payload).?),
            .wrap_errunion_err => try genWrapErrUnionErr(o, inst.castTag(.wrap_errunion_err).?),
            .br_block_flat => return o.dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement codegen for br_block_flat", .{}),
            .ptrtoint => try genCast(o, inst.castTag(.ptrtoint).?),
            .varptr => try genVarPtr(o, inst.castTag(.varptr).?),
            .floatcast => return o.dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement codegen for floatcast", .{}),
        };
        switch (result_value) {
            .none => {},
            else => try o.value_map.putNoClobber(inst, result_value),
        }
    }

    o.indent_writer.popIndent();
    try writer.writeAll("}");
}

fn genVarPtr(o: *Object, inst: *Inst.VarPtr) !CValue {
    _ = o;
    return CValue{ .decl_ref = inst.variable.owner_decl };
}

fn genAlloc(o: *Object, alloc: *Inst.NoOp) !CValue {
    const writer = o.writer();

    // First line: the variable used as data storage.
    const elem_type = alloc.base.ty.elemType();
    const mutability: Mutability = if (alloc.base.ty.isConstPtr()) .Const else .Mut;
    const local = try o.allocLocal(elem_type, mutability);
    try writer.writeAll(";\n");

    return CValue{ .local_ref = local.local };
}

fn genArg(o: *Object) CValue {
    const i = o.next_arg_index;
    o.next_arg_index += 1;
    return .{ .arg = i };
}

fn genRetVoid(o: *Object) !CValue {
    try o.writer().print("return;\n", .{});
    return CValue.none;
}

fn genLoad(o: *Object, inst: *Inst.UnOp) !CValue {
    const operand = try o.resolveInst(inst.operand);
    const writer = o.writer();
    const local = try o.allocLocal(inst.base.ty, .Const);
    switch (operand) {
        .local_ref => |i| {
            const wrapped: CValue = .{ .local = i };
            try writer.writeAll(" = ");
            try o.writeCValue(writer, wrapped);
            try writer.writeAll(";\n");
        },
        .decl_ref => |decl| {
            const wrapped: CValue = .{ .decl = decl };
            try writer.writeAll(" = ");
            try o.writeCValue(writer, wrapped);
            try writer.writeAll(";\n");
        },
        else => {
            try writer.writeAll(" = *");
            try o.writeCValue(writer, operand);
            try writer.writeAll(";\n");
        },
    }
    return local;
}

fn genRet(o: *Object, inst: *Inst.UnOp) !CValue {
    const operand = try o.resolveInst(inst.operand);
    const writer = o.writer();
    try writer.writeAll("return ");
    try o.writeCValue(writer, operand);
    try writer.writeAll(";\n");
    return CValue.none;
}

fn genCast(o: *Object, inst: *Inst.UnOp) !CValue {
    if (inst.base.isUnused())
        return CValue.none;

    const from = try o.resolveInst(inst.operand);
    // it looks like Sema is not generating alloca for constant local variables and it is
    // causing to generate code like:
    // uintptr_t const t0 = (uintptr_t)&72;
    if (from == .constant and inst.base.tag == .ptrtoint) {
        return o.dg.fail(.{ .node_offset = 0 }, "TODO: C backend: support constants in @ptrToInt", .{});
    }

    const writer = o.writer();
    const local = try o.allocLocal(inst.base.ty, .Const);
    try writer.writeAll(" = (");
    try o.dg.renderType(writer, inst.base.ty);
    try writer.writeAll(")");
    try o.writeCValue(writer, from);
    try writer.writeAll(";\n");
    return local;
}

fn genStore(o: *Object, inst: *Inst.BinOp) !CValue {
    // *a = b;
    const dest_ptr = try o.resolveInst(inst.lhs);
    const src_val = try o.resolveInst(inst.rhs);

    const writer = o.writer();
    switch (dest_ptr) {
        .local_ref => |i| {
            const dest: CValue = .{ .local = i };
            try o.writeCValue(writer, dest);
            try writer.writeAll(" = ");
            try o.writeCValue(writer, src_val);
            try writer.writeAll(";\n");
        },
        .decl_ref => |decl| {
            const dest: CValue = .{ .decl = decl };
            try o.writeCValue(writer, dest);
            try writer.writeAll(" = ");
            try o.writeCValue(writer, src_val);
            try writer.writeAll(";\n");
        },
        else => {
            try writer.writeAll("*");
            try o.writeCValue(writer, dest_ptr);
            try writer.writeAll(" = ");
            try o.writeCValue(writer, src_val);
            try writer.writeAll(";\n");
        },
    }
    return CValue.none;
}

fn genWrapOp(o: *Object, inst: *Inst.BinOp, str_op: [*:0]const u8, fn_op: [*:0]const u8) !CValue {
    if (inst.base.isUnused())
        return CValue.none;

    const int_info = inst.base.ty.intInfo(o.dg.module.getTarget());
    const bits = int_info.bits;

    // if it's an unsigned int with non-arbitrary bit size then we can just add
    if (int_info.signedness == .unsigned) {
        const ok_bits = switch (bits) {
            8, 16, 32, 64, 128 => true,
            else => false,
        };
        if (ok_bits or inst.base.ty.tag() != .int_unsigned) {
            return try genBinOp(o, inst, str_op);
        }
    }

    if (bits > 64) {
        return o.dg.fail(.{ .node_offset = 0 }, "TODO: C backend: genWrapOp for large integers", .{});
    }

    var min_buf: [80]u8 = undefined;
    const min = switch (int_info.signedness) {
        .unsigned => "0",
        else => switch (inst.base.ty.tag()) {
            .c_short => "SHRT_MIN",
            .c_int => "INT_MIN",
            .c_long => "LONG_MIN",
            .c_longlong => "LLONG_MIN",
            .isize => "INTPTR_MIN",
            else => blk: {
                const val = -1 * std.math.pow(i64, 2, @intCast(i64, bits - 1));
                break :blk std.fmt.bufPrint(&min_buf, "{d}", .{val}) catch |err| switch (err) {
                    error.NoSpaceLeft => unreachable,
                    else => |e| return e,
                };
            },
        },
    };

    var max_buf: [80]u8 = undefined;
    const max = switch (inst.base.ty.tag()) {
        .c_short => "SHRT_MAX",
        .c_ushort => "USHRT_MAX",
        .c_int => "INT_MAX",
        .c_uint => "UINT_MAX",
        .c_long => "LONG_MAX",
        .c_ulong => "ULONG_MAX",
        .c_longlong => "LLONG_MAX",
        .c_ulonglong => "ULLONG_MAX",
        .isize => "INTPTR_MAX",
        .usize => "UINTPTR_MAX",
        else => blk: {
            const pow_bits = switch (int_info.signedness) {
                .signed => bits - 1,
                .unsigned => bits,
            };
            const val = std.math.pow(u64, 2, pow_bits) - 1;
            break :blk std.fmt.bufPrint(&max_buf, "{}", .{val}) catch |err| switch (err) {
                error.NoSpaceLeft => unreachable,
                else => |e| return e,
            };
        },
    };

    const lhs = try o.resolveInst(inst.lhs);
    const rhs = try o.resolveInst(inst.rhs);
    const w = o.writer();

    const ret = try o.allocLocal(inst.base.ty, .Mut);
    try w.print(" = zig_{s}", .{fn_op});

    switch (inst.base.ty.tag()) {
        .isize => try w.writeAll("isize"),
        .c_short => try w.writeAll("short"),
        .c_int => try w.writeAll("int"),
        .c_long => try w.writeAll("long"),
        .c_longlong => try w.writeAll("longlong"),
        else => {
            const prefix_byte: u8 = switch (int_info.signedness) {
                .signed => 'i',
                .unsigned => 'u',
            };
            for ([_]u8{ 8, 16, 32, 64 }) |nbits| {
                if (bits <= nbits) {
                    try w.print("{c}{d}", .{ prefix_byte, nbits });
                    break;
                }
            } else {
                unreachable;
            }
        },
    }

    try w.writeByte('(');
    try o.writeCValue(w, lhs);
    try w.writeAll(", ");
    try o.writeCValue(w, rhs);

    if (int_info.signedness == .signed) {
        try w.print(", {s}", .{min});
    }

    try w.print(", {s});", .{max});
    try o.indent_writer.insertNewline();

    return ret;
}

fn genBinOp(o: *Object, inst: *Inst.BinOp, operator: [*:0]const u8) !CValue {
    if (inst.base.isUnused())
        return CValue.none;

    const lhs = try o.resolveInst(inst.lhs);
    const rhs = try o.resolveInst(inst.rhs);

    const writer = o.writer();
    const local = try o.allocLocal(inst.base.ty, .Const);

    try writer.writeAll(" = ");
    try o.writeCValue(writer, lhs);
    try writer.print("{s}", .{operator});
    try o.writeCValue(writer, rhs);
    try writer.writeAll(";\n");

    return local;
}

fn genUnOp(o: *Object, inst: *Inst.UnOp, operator: []const u8) !CValue {
    if (inst.base.isUnused())
        return CValue.none;

    const operand = try o.resolveInst(inst.operand);

    const writer = o.writer();
    const local = try o.allocLocal(inst.base.ty, .Const);

    try writer.print(" = {s}", .{operator});
    try o.writeCValue(writer, operand);
    try writer.writeAll(";\n");

    return local;
}

fn genCall(o: *Object, inst: *Inst.Call) !CValue {
    if (inst.func.castTag(.constant)) |func_inst| {
        const fn_decl = if (func_inst.val.castTag(.extern_fn)) |extern_fn|
            extern_fn.data
        else if (func_inst.val.castTag(.function)) |func_payload|
            func_payload.data.owner_decl
        else
            unreachable;

        const fn_ty = fn_decl.ty;
        const ret_ty = fn_ty.fnReturnType();
        const unused_result = inst.base.isUnused();
        var result_local: CValue = .none;

        const writer = o.writer();
        if (unused_result) {
            if (ret_ty.hasCodeGenBits()) {
                try writer.print("(void)", .{});
            }
        } else {
            result_local = try o.allocLocal(ret_ty, .Const);
            try writer.writeAll(" = ");
        }
        const fn_name = mem.spanZ(fn_decl.name);
        try writer.print("{s}(", .{fn_name});
        if (inst.args.len != 0) {
            for (inst.args) |arg, i| {
                if (i > 0) {
                    try writer.writeAll(", ");
                }
                if (arg.value()) |val| {
                    try o.dg.renderValue(writer, arg.ty, val);
                } else {
                    const val = try o.resolveInst(arg);
                    try o.writeCValue(writer, val);
                }
            }
        }
        try writer.writeAll(");\n");
        return result_local;
    } else {
        return o.dg.fail(.{ .node_offset = 0 }, "TODO: C backend: implement function pointers", .{});
    }
}

fn genDbgStmt(o: *Object, inst: *Inst.DbgStmt) !CValue {
    _ = o;
    _ = inst;
    // TODO emit #line directive here with line number and filename
    return CValue.none;
}

fn genBlock(o: *Object, inst: *Inst.Block) !CValue {
    const block_id: usize = o.next_block_index;
    o.next_block_index += 1;
    const writer = o.writer();

    const result = if (inst.base.ty.tag() != .void and !inst.base.isUnused()) blk: {
        // allocate a location for the result
        const local = try o.allocLocal(inst.base.ty, .Mut);
        try writer.writeAll(";\n");
        break :blk local;
    } else CValue{ .none = {} };

    try o.blocks.putNoClobber(o.gpa, inst, .{
        .block_id = block_id,
        .result = result,
    });

    try genBody(o, inst.body);
    try o.indent_writer.insertNewline();
    // label must be followed by an expression, add an empty one.
    try writer.print("zig_block_{d}:;\n", .{block_id});
    return result;
}

fn genBr(o: *Object, inst: *Inst.Br) !CValue {
    const result = o.blocks.get(inst.block).?.result;
    const writer = o.writer();

    // If result is .none then the value of the block is unused.
    if (inst.operand.ty.tag() != .void and result != .none) {
        const operand = try o.resolveInst(inst.operand);
        try o.writeCValue(writer, result);
        try writer.writeAll(" = ");
        try o.writeCValue(writer, operand);
        try writer.writeAll(";\n");
    }

    return genBrVoid(o, inst.block);
}

fn genBrVoid(o: *Object, block: *Inst.Block) !CValue {
    try o.writer().print("goto zig_block_{d};\n", .{o.blocks.get(block).?.block_id});
    return CValue.none;
}

fn genBitcast(o: *Object, inst: *Inst.UnOp) !CValue {
    const operand = try o.resolveInst(inst.operand);

    const writer = o.writer();
    if (inst.base.ty.zigTypeTag() == .Pointer and inst.operand.ty.zigTypeTag() == .Pointer) {
        const local = try o.allocLocal(inst.base.ty, .Const);
        try writer.writeAll(" = (");
        try o.dg.renderType(writer, inst.base.ty);

        try writer.writeAll(")");
        try o.writeCValue(writer, operand);
        try writer.writeAll(";\n");
        return local;
    }

    const local = try o.allocLocal(inst.base.ty, .Mut);
    try writer.writeAll(";\n");

    try writer.writeAll("memcpy(&");
    try o.writeCValue(writer, local);
    try writer.writeAll(", &");
    try o.writeCValue(writer, operand);
    try writer.writeAll(", sizeof ");
    try o.writeCValue(writer, local);
    try writer.writeAll(");\n");

    return local;
}

fn genBreakpoint(o: *Object, inst: *Inst.NoOp) !CValue {
    _ = inst;
    try o.writer().writeAll("zig_breakpoint();\n");
    return CValue.none;
}

fn genUnreach(o: *Object, inst: *Inst.NoOp) !CValue {
    _ = inst;
    try o.writer().writeAll("zig_unreachable();\n");
    return CValue.none;
}

fn genLoop(o: *Object, inst: *Inst.Loop) !CValue {
    try o.writer().writeAll("while (true) ");
    try genBody(o, inst.body);
    try o.indent_writer.insertNewline();
    return CValue.none;
}

fn genCondBr(o: *Object, inst: *Inst.CondBr) !CValue {
    const cond = try o.resolveInst(inst.condition);
    const writer = o.writer();

    try writer.writeAll("if (");
    try o.writeCValue(writer, cond);
    try writer.writeAll(") ");
    try genBody(o, inst.then_body);
    try writer.writeAll(" else ");
    try genBody(o, inst.else_body);
    try o.indent_writer.insertNewline();

    return CValue.none;
}

fn genSwitchBr(o: *Object, inst: *Inst.SwitchBr) !CValue {
    const target = try o.resolveInst(inst.target);
    const writer = o.writer();

    try writer.writeAll("switch (");
    try o.writeCValue(writer, target);
    try writer.writeAll(") {\n");
    o.indent_writer.pushIndent();

    for (inst.cases) |case| {
        try writer.writeAll("case ");
        try o.dg.renderValue(writer, inst.target.ty, case.item);
        try writer.writeAll(": ");
        // the case body must be noreturn so we don't need to insert a break
        try genBody(o, case.body);
        try o.indent_writer.insertNewline();
    }

    try writer.writeAll("default: ");
    try genBody(o, inst.else_body);
    try o.indent_writer.insertNewline();

    o.indent_writer.popIndent();
    try writer.writeAll("}\n");
    return CValue.none;
}

fn genAsm(o: *Object, as: *Inst.Assembly) !CValue {
    if (as.base.isUnused() and !as.is_volatile)
        return CValue.none;

    const writer = o.writer();
    for (as.inputs) |i, index| {
        if (i[0] == '{' and i[i.len - 1] == '}') {
            const reg = i[1 .. i.len - 1];
            const arg = as.args[index];
            const arg_c_value = try o.resolveInst(arg);
            try writer.writeAll("register ");
            try o.dg.renderType(writer, arg.ty);

            try writer.print(" {s}_constant __asm__(\"{s}\") = ", .{ reg, reg });
            try o.writeCValue(writer, arg_c_value);
            try writer.writeAll(";\n");
        } else {
            return o.dg.fail(.{ .node_offset = 0 }, "TODO non-explicit inline asm regs", .{});
        }
    }
    const volatile_string: []const u8 = if (as.is_volatile) "volatile " else "";
    try writer.print("__asm {s}(\"{s}\"", .{ volatile_string, as.asm_source });
    if (as.output_constraint) |_| {
        return o.dg.fail(.{ .node_offset = 0 }, "TODO: CBE inline asm output", .{});
    }
    if (as.inputs.len > 0) {
        if (as.output_constraint == null) {
            try writer.writeAll(" :");
        }
        try writer.writeAll(": ");
        for (as.inputs) |i, index| {
            if (i[0] == '{' and i[i.len - 1] == '}') {
                const reg = i[1 .. i.len - 1];
                if (index > 0) {
                    try writer.writeAll(", ");
                }
                try writer.print("\"r\"({s}_constant)", .{reg});
            } else {
                // This is blocked by the earlier test
                unreachable;
            }
        }
    }
    try writer.writeAll(");\n");

    if (as.base.isUnused())
        return CValue.none;

    return o.dg.fail(.{ .node_offset = 0 }, "TODO: C backend: inline asm expression result used", .{});
}

fn genIsNull(o: *Object, inst: *Inst.UnOp) !CValue {
    const writer = o.writer();
    const invert_logic = inst.base.tag == .is_non_null or inst.base.tag == .is_non_null_ptr;
    const operator = if (invert_logic) "!=" else "==";
    const maybe_deref = if (inst.base.tag == .is_null_ptr or inst.base.tag == .is_non_null_ptr) "[0]" else "";
    const operand = try o.resolveInst(inst.operand);

    const local = try o.allocLocal(Type.initTag(.bool), .Const);
    try writer.writeAll(" = (");
    try o.writeCValue(writer, operand);

    if (inst.operand.ty.isPtrLikeOptional()) {
        // operand is a regular pointer, test `operand !=/== NULL`
        try writer.print("){s} {s} NULL;\n", .{ maybe_deref, operator });
    } else {
        try writer.print("){s}.is_null {s} true;\n", .{ maybe_deref, operator });
    }
    return local;
}

fn genOptionalPayload(o: *Object, inst: *Inst.UnOp) !CValue {
    const writer = o.writer();
    const operand = try o.resolveInst(inst.operand);

    const opt_ty = if (inst.operand.ty.zigTypeTag() == .Pointer)
        inst.operand.ty.elemType()
    else
        inst.operand.ty;

    if (opt_ty.isPtrLikeOptional()) {
        // the operand is just a regular pointer, no need to do anything special.
        // *?*T -> **T and ?*T -> *T are **T -> **T and *T -> *T in C
        return operand;
    }

    const maybe_deref = if (inst.operand.ty.zigTypeTag() == .Pointer) "->" else ".";
    const maybe_addrof = if (inst.base.ty.zigTypeTag() == .Pointer) "&" else "";

    const local = try o.allocLocal(inst.base.ty, .Const);
    try writer.print(" = {s}(", .{maybe_addrof});
    try o.writeCValue(writer, operand);

    try writer.print("){s}payload;\n", .{maybe_deref});
    return local;
}

fn genRef(o: *Object, inst: *Inst.UnOp) !CValue {
    const writer = o.writer();
    const operand = try o.resolveInst(inst.operand);

    const local = try o.allocLocal(inst.base.ty, .Const);
    try writer.writeAll(" = ");
    try o.writeCValue(writer, operand);
    try writer.writeAll(";\n");
    return local;
}

fn genStructFieldPtr(o: *Object, inst: *Inst.StructFieldPtr) !CValue {
    const writer = o.writer();
    const struct_ptr = try o.resolveInst(inst.struct_ptr);
    const struct_obj = inst.struct_ptr.ty.elemType().castTag(.@"struct").?.data;
    const field_name = struct_obj.fields.keys()[inst.field_index];

    const local = try o.allocLocal(inst.base.ty, .Const);
    switch (struct_ptr) {
        .local_ref => |i| {
            try writer.print(" = &t{d}.{};\n", .{ i, fmtIdent(field_name) });
        },
        else => {
            try writer.writeAll(" = &");
            try o.writeCValue(writer, struct_ptr);
            try writer.print("->{};\n", .{fmtIdent(field_name)});
        },
    }
    return local;
}

// *(E!T) -> E NOT *E
fn genUnwrapErrUnionErr(o: *Object, inst: *Inst.UnOp) !CValue {
    if (inst.base.isUnused())
        return CValue.none;

    const writer = o.writer();
    const operand = try o.resolveInst(inst.operand);

    const payload_ty = inst.operand.ty.errorUnionChild();
    if (!payload_ty.hasCodeGenBits()) {
        if (inst.operand.ty.zigTypeTag() == .Pointer) {
            const local = try o.allocLocal(inst.base.ty, .Const);
            try writer.writeAll(" = *");
            try o.writeCValue(writer, operand);
            try writer.writeAll(";\n");
            return local;
        } else {
            return operand;
        }
    }

    const maybe_deref = if (inst.operand.ty.zigTypeTag() == .Pointer) "->" else ".";

    const local = try o.allocLocal(inst.base.ty, .Const);
    try writer.writeAll(" = (");
    try o.writeCValue(writer, operand);

    try writer.print("){s}error;\n", .{maybe_deref});
    return local;
}

fn genUnwrapErrUnionPay(o: *Object, inst: *Inst.UnOp) !CValue {
    if (inst.base.isUnused())
        return CValue.none;

    const writer = o.writer();
    const operand = try o.resolveInst(inst.operand);

    const payload_ty = inst.operand.ty.errorUnionChild();
    if (!payload_ty.hasCodeGenBits()) {
        return CValue.none;
    }

    const maybe_deref = if (inst.operand.ty.zigTypeTag() == .Pointer) "->" else ".";
    const maybe_addrof = if (inst.base.ty.zigTypeTag() == .Pointer) "&" else "";

    const local = try o.allocLocal(inst.base.ty, .Const);
    try writer.print(" = {s}(", .{maybe_addrof});
    try o.writeCValue(writer, operand);

    try writer.print("){s}payload;\n", .{maybe_deref});
    return local;
}

fn genWrapOptional(o: *Object, inst: *Inst.UnOp) !CValue {
    const writer = o.writer();
    const operand = try o.resolveInst(inst.operand);

    if (inst.base.ty.isPtrLikeOptional()) {
        // the operand is just a regular pointer, no need to do anything special.
        return operand;
    }

    // .wrap_optional is used to convert non-optionals into optionals so it can never be null.
    const local = try o.allocLocal(inst.base.ty, .Const);
    try writer.writeAll(" = { .is_null = false, .payload =");
    try o.writeCValue(writer, operand);
    try writer.writeAll("};\n");
    return local;
}
fn genWrapErrUnionErr(o: *Object, inst: *Inst.UnOp) !CValue {
    const writer = o.writer();
    const operand = try o.resolveInst(inst.operand);

    const local = try o.allocLocal(inst.base.ty, .Const);
    try writer.writeAll(" = { .error = ");
    try o.writeCValue(writer, operand);
    try writer.writeAll(" };\n");
    return local;
}
fn genWrapErrUnionPay(o: *Object, inst: *Inst.UnOp) !CValue {
    const writer = o.writer();
    const operand = try o.resolveInst(inst.operand);

    const local = try o.allocLocal(inst.base.ty, .Const);
    try writer.writeAll(" = { .error = 0, .payload = ");
    try o.writeCValue(writer, operand);
    try writer.writeAll(" };\n");
    return local;
}

fn genIsErr(
    o: *Object,
    inst: *Inst.UnOp,
    deref_prefix: [*:0]const u8,
    deref_suffix: [*:0]const u8,
    op_str: [*:0]const u8,
) !CValue {
    const writer = o.writer();
    const operand = try o.resolveInst(inst.operand);
    const local = try o.allocLocal(Type.initTag(.bool), .Const);
    const payload_ty = inst.operand.ty.errorUnionChild();
    if (!payload_ty.hasCodeGenBits()) {
        try writer.print(" = {s}", .{deref_prefix});
        try o.writeCValue(writer, operand);
        try writer.print(" {s} 0;\n", .{op_str});
    } else {
        try writer.writeAll(" = ");
        try o.writeCValue(writer, operand);
        try writer.print("{s}error {s} 0;\n", .{ deref_suffix, op_str });
    }
    return local;
}

fn IndentWriter(comptime UnderlyingWriter: type) type {
    return struct {
        const Self = @This();
        pub const Error = UnderlyingWriter.Error;
        pub const Writer = std.io.Writer(*Self, Error, write);

        pub const indent_delta = 1;

        underlying_writer: UnderlyingWriter,
        indent_count: usize = 0,
        current_line_empty: bool = true,

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            if (bytes.len == 0) return @as(usize, 0);

            const current_indent = self.indent_count * Self.indent_delta;
            if (self.current_line_empty and current_indent > 0) {
                try self.underlying_writer.writeByteNTimes(' ', current_indent);
            }
            self.current_line_empty = false;

            return self.writeNoIndent(bytes);
        }

        pub fn insertNewline(self: *Self) Error!void {
            _ = try self.writeNoIndent("\n");
        }

        pub fn pushIndent(self: *Self) void {
            self.indent_count += 1;
        }

        pub fn popIndent(self: *Self) void {
            assert(self.indent_count != 0);
            self.indent_count -= 1;
        }

        fn writeNoIndent(self: *Self, bytes: []const u8) Error!usize {
            if (bytes.len == 0) return @as(usize, 0);

            try self.underlying_writer.writeAll(bytes);
            if (bytes[bytes.len - 1] == '\n') {
                self.current_line_empty = true;
            }
            return bytes.len;
        }
    };
}
