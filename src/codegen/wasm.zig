const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const testing = std.testing;
const leb = std.leb;
const mem = std.mem;
const wasm = std.wasm;

const Module = @import("../Module.zig");
const Decl = Module.Decl;
const Type = @import("../type.zig").Type;
const Value = @import("../value.zig").Value;
const Compilation = @import("../Compilation.zig");
const LazySrcLoc = Module.LazySrcLoc;
const link = @import("../link.zig");
const TypedValue = @import("../TypedValue.zig");
const Air = @import("../Air.zig");
const Liveness = @import("../Liveness.zig");

/// Wasm Value, created when generating an instruction
const WValue = union(enum) {
    /// May be referenced but is unused
    none: void,
    /// Index of the local variable
    local: u32,
    /// Instruction holding a constant `Value`
    constant: *Inst,
    /// Offset position in the list of bytecode instructions
    code_offset: usize,
    /// Used for variables that create multiple locals on the stack when allocated
    /// such as structs and optionals.
    multi_value: struct {
        /// The index of the first local variable
        index: u32,
        /// The count of local variables this `WValue` consists of.
        /// i.e. an ErrorUnion has a 'count' of 2.
        count: u32,
    },
};

/// Wasm ops, but without input/output/signedness information
/// Used for `buildOpcode`
const Op = enum {
    @"unreachable",
    nop,
    block,
    loop,
    @"if",
    @"else",
    end,
    br,
    br_if,
    br_table,
    @"return",
    call,
    call_indirect,
    drop,
    select,
    local_get,
    local_set,
    local_tee,
    global_get,
    global_set,
    load,
    store,
    memory_size,
    memory_grow,
    @"const",
    eqz,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    clz,
    ctz,
    popcnt,
    add,
    sub,
    mul,
    div,
    rem,
    @"and",
    @"or",
    xor,
    shl,
    shr,
    rotl,
    rotr,
    abs,
    neg,
    ceil,
    floor,
    trunc,
    nearest,
    sqrt,
    min,
    max,
    copysign,
    wrap,
    convert,
    demote,
    promote,
    reinterpret,
    extend,
};

/// Contains the settings needed to create an `Opcode` using `buildOpcode`.
///
/// The fields correspond to the opcode name. Here is an example
///          i32_trunc_f32_s
///          ^   ^     ^   ^
///          |   |     |   |
///   valtype1   |     |   |
///     = .i32   |     |   |
///              |     |   |
///             op     |   |
///       = .trunc     |   |
///                    |   |
///             valtype2   |
///               = .f32   |
///                        |
///                width   |
///               = null   |
///                        |
///                   signed
///                   = true
///
/// There can be missing fields, here are some more examples:
///   i64_load8_u
///     --> .{ .valtype1 = .i64, .op = .load, .width = 8, signed = false }
///   i32_mul
///     --> .{ .valtype1 = .i32, .op = .trunc }
///   nop
///     --> .{ .op = .nop }
const OpcodeBuildArguments = struct {
    /// First valtype in the opcode (usually represents the type of the output)
    valtype1: ?wasm.Valtype = null,
    /// The operation (e.g. call, unreachable, div, min, sqrt, etc.)
    op: Op,
    /// Width of the operation (e.g. 8 for i32_load8_s, 16 for i64_extend16_i32_s)
    width: ?u8 = null,
    /// Second valtype in the opcode name (usually represents the type of the input)
    valtype2: ?wasm.Valtype = null,
    /// Signedness of the op
    signedness: ?std.builtin.Signedness = null,
};

/// Helper function that builds an Opcode given the arguments needed
fn buildOpcode(args: OpcodeBuildArguments) wasm.Opcode {
    switch (args.op) {
        .@"unreachable" => return .@"unreachable",
        .nop => return .nop,
        .block => return .block,
        .loop => return .loop,
        .@"if" => return .@"if",
        .@"else" => return .@"else",
        .end => return .end,
        .br => return .br,
        .br_if => return .br_if,
        .br_table => return .br_table,
        .@"return" => return .@"return",
        .call => return .call,
        .call_indirect => return .call_indirect,
        .drop => return .drop,
        .select => return .select,
        .local_get => return .local_get,
        .local_set => return .local_set,
        .local_tee => return .local_tee,
        .global_get => return .global_get,
        .global_set => return .global_set,

        .load => if (args.width) |width| switch (width) {
            8 => switch (args.valtype1.?) {
                .i32 => if (args.signedness.? == .signed) return .i32_load8_s else return .i32_load8_u,
                .i64 => if (args.signedness.? == .signed) return .i64_load8_s else return .i64_load8_u,
                .f32, .f64 => unreachable,
            },
            16 => switch (args.valtype1.?) {
                .i32 => if (args.signedness.? == .signed) return .i32_load16_s else return .i32_load16_u,
                .i64 => if (args.signedness.? == .signed) return .i64_load16_s else return .i64_load16_u,
                .f32, .f64 => unreachable,
            },
            32 => switch (args.valtype1.?) {
                .i64 => if (args.signedness.? == .signed) return .i64_load32_s else return .i64_load32_u,
                .i32, .f32, .f64 => unreachable,
            },
            else => unreachable,
        } else switch (args.valtype1.?) {
            .i32 => return .i32_load,
            .i64 => return .i64_load,
            .f32 => return .f32_load,
            .f64 => return .f64_load,
        },
        .store => if (args.width) |width| {
            switch (width) {
                8 => switch (args.valtype1.?) {
                    .i32 => return .i32_store8,
                    .i64 => return .i64_store8,
                    .f32, .f64 => unreachable,
                },
                16 => switch (args.valtype1.?) {
                    .i32 => return .i32_store16,
                    .i64 => return .i64_store16,
                    .f32, .f64 => unreachable,
                },
                32 => switch (args.valtype1.?) {
                    .i64 => return .i64_store32,
                    .i32, .f32, .f64 => unreachable,
                },
                else => unreachable,
            }
        } else {
            switch (args.valtype1.?) {
                .i32 => return .i32_store,
                .i64 => return .i64_store,
                .f32 => return .f32_store,
                .f64 => return .f64_store,
            }
        },

        .memory_size => return .memory_size,
        .memory_grow => return .memory_grow,

        .@"const" => switch (args.valtype1.?) {
            .i32 => return .i32_const,
            .i64 => return .i64_const,
            .f32 => return .f32_const,
            .f64 => return .f64_const,
        },

        .eqz => switch (args.valtype1.?) {
            .i32 => return .i32_eqz,
            .i64 => return .i64_eqz,
            .f32, .f64 => unreachable,
        },
        .eq => switch (args.valtype1.?) {
            .i32 => return .i32_eq,
            .i64 => return .i64_eq,
            .f32 => return .f32_eq,
            .f64 => return .f64_eq,
        },
        .ne => switch (args.valtype1.?) {
            .i32 => return .i32_ne,
            .i64 => return .i64_ne,
            .f32 => return .f32_ne,
            .f64 => return .f64_ne,
        },

        .lt => switch (args.valtype1.?) {
            .i32 => if (args.signedness.? == .signed) return .i32_lt_s else return .i32_lt_u,
            .i64 => if (args.signedness.? == .signed) return .i64_lt_s else return .i64_lt_u,
            .f32 => return .f32_lt,
            .f64 => return .f64_lt,
        },
        .gt => switch (args.valtype1.?) {
            .i32 => if (args.signedness.? == .signed) return .i32_gt_s else return .i32_gt_u,
            .i64 => if (args.signedness.? == .signed) return .i64_gt_s else return .i64_gt_u,
            .f32 => return .f32_gt,
            .f64 => return .f64_gt,
        },
        .le => switch (args.valtype1.?) {
            .i32 => if (args.signedness.? == .signed) return .i32_le_s else return .i32_le_u,
            .i64 => if (args.signedness.? == .signed) return .i64_le_s else return .i64_le_u,
            .f32 => return .f32_le,
            .f64 => return .f64_le,
        },
        .ge => switch (args.valtype1.?) {
            .i32 => if (args.signedness.? == .signed) return .i32_ge_s else return .i32_ge_u,
            .i64 => if (args.signedness.? == .signed) return .i64_ge_s else return .i64_ge_u,
            .f32 => return .f32_ge,
            .f64 => return .f64_ge,
        },

        .clz => switch (args.valtype1.?) {
            .i32 => return .i32_clz,
            .i64 => return .i64_clz,
            .f32, .f64 => unreachable,
        },
        .ctz => switch (args.valtype1.?) {
            .i32 => return .i32_ctz,
            .i64 => return .i64_ctz,
            .f32, .f64 => unreachable,
        },
        .popcnt => switch (args.valtype1.?) {
            .i32 => return .i32_popcnt,
            .i64 => return .i64_popcnt,
            .f32, .f64 => unreachable,
        },

        .add => switch (args.valtype1.?) {
            .i32 => return .i32_add,
            .i64 => return .i64_add,
            .f32 => return .f32_add,
            .f64 => return .f64_add,
        },
        .sub => switch (args.valtype1.?) {
            .i32 => return .i32_sub,
            .i64 => return .i64_sub,
            .f32 => return .f32_sub,
            .f64 => return .f64_sub,
        },
        .mul => switch (args.valtype1.?) {
            .i32 => return .i32_mul,
            .i64 => return .i64_mul,
            .f32 => return .f32_mul,
            .f64 => return .f64_mul,
        },

        .div => switch (args.valtype1.?) {
            .i32 => if (args.signedness.? == .signed) return .i32_div_s else return .i32_div_u,
            .i64 => if (args.signedness.? == .signed) return .i64_div_s else return .i64_div_u,
            .f32 => return .f32_div,
            .f64 => return .f64_div,
        },
        .rem => switch (args.valtype1.?) {
            .i32 => if (args.signedness.? == .signed) return .i32_rem_s else return .i32_rem_u,
            .i64 => if (args.signedness.? == .signed) return .i64_rem_s else return .i64_rem_u,
            .f32, .f64 => unreachable,
        },

        .@"and" => switch (args.valtype1.?) {
            .i32 => return .i32_and,
            .i64 => return .i64_and,
            .f32, .f64 => unreachable,
        },
        .@"or" => switch (args.valtype1.?) {
            .i32 => return .i32_or,
            .i64 => return .i64_or,
            .f32, .f64 => unreachable,
        },
        .xor => switch (args.valtype1.?) {
            .i32 => return .i32_xor,
            .i64 => return .i64_xor,
            .f32, .f64 => unreachable,
        },

        .shl => switch (args.valtype1.?) {
            .i32 => return .i32_shl,
            .i64 => return .i64_shl,
            .f32, .f64 => unreachable,
        },
        .shr => switch (args.valtype1.?) {
            .i32 => if (args.signedness.? == .signed) return .i32_shr_s else return .i32_shr_u,
            .i64 => if (args.signedness.? == .signed) return .i64_shr_s else return .i64_shr_u,
            .f32, .f64 => unreachable,
        },
        .rotl => switch (args.valtype1.?) {
            .i32 => return .i32_rotl,
            .i64 => return .i64_rotl,
            .f32, .f64 => unreachable,
        },
        .rotr => switch (args.valtype1.?) {
            .i32 => return .i32_rotr,
            .i64 => return .i64_rotr,
            .f32, .f64 => unreachable,
        },

        .abs => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => return .f32_abs,
            .f64 => return .f64_abs,
        },
        .neg => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => return .f32_neg,
            .f64 => return .f64_neg,
        },
        .ceil => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => return .f32_ceil,
            .f64 => return .f64_ceil,
        },
        .floor => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => return .f32_floor,
            .f64 => return .f64_floor,
        },
        .trunc => switch (args.valtype1.?) {
            .i32 => switch (args.valtype2.?) {
                .i32 => unreachable,
                .i64 => unreachable,
                .f32 => if (args.signedness.? == .signed) return .i32_trunc_f32_s else return .i32_trunc_f32_u,
                .f64 => if (args.signedness.? == .signed) return .i32_trunc_f64_s else return .i32_trunc_f64_u,
            },
            .i64 => unreachable,
            .f32 => return .f32_trunc,
            .f64 => return .f64_trunc,
        },
        .nearest => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => return .f32_nearest,
            .f64 => return .f64_nearest,
        },
        .sqrt => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => return .f32_sqrt,
            .f64 => return .f64_sqrt,
        },
        .min => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => return .f32_min,
            .f64 => return .f64_min,
        },
        .max => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => return .f32_max,
            .f64 => return .f64_max,
        },
        .copysign => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => return .f32_copysign,
            .f64 => return .f64_copysign,
        },

        .wrap => switch (args.valtype1.?) {
            .i32 => switch (args.valtype2.?) {
                .i32 => unreachable,
                .i64 => return .i32_wrap_i64,
                .f32, .f64 => unreachable,
            },
            .i64, .f32, .f64 => unreachable,
        },
        .convert => switch (args.valtype1.?) {
            .i32, .i64 => unreachable,
            .f32 => switch (args.valtype2.?) {
                .i32 => if (args.signedness.? == .signed) return .f32_convert_i32_s else return .f32_convert_i32_u,
                .i64 => if (args.signedness.? == .signed) return .f32_convert_i64_s else return .f32_convert_i64_u,
                .f32, .f64 => unreachable,
            },
            .f64 => switch (args.valtype2.?) {
                .i32 => if (args.signedness.? == .signed) return .f64_convert_i32_s else return .f64_convert_i32_u,
                .i64 => if (args.signedness.? == .signed) return .f64_convert_i64_s else return .f64_convert_i64_u,
                .f32, .f64 => unreachable,
            },
        },
        .demote => if (args.valtype1.? == .f32 and args.valtype2.? == .f64) return .f32_demote_f64 else unreachable,
        .promote => if (args.valtype1.? == .f64 and args.valtype2.? == .f32) return .f64_promote_f32 else unreachable,
        .reinterpret => switch (args.valtype1.?) {
            .i32 => if (args.valtype2.? == .f32) return .i32_reinterpret_f32 else unreachable,
            .i64 => if (args.valtype2.? == .f64) return .i64_reinterpret_f64 else unreachable,
            .f32 => if (args.valtype2.? == .i32) return .f32_reinterpret_i32 else unreachable,
            .f64 => if (args.valtype2.? == .i64) return .f64_reinterpret_i64 else unreachable,
        },
        .extend => switch (args.valtype1.?) {
            .i32 => switch (args.width.?) {
                8 => if (args.signedness.? == .signed) return .i32_extend8_s else unreachable,
                16 => if (args.signedness.? == .signed) return .i32_extend16_s else unreachable,
                else => unreachable,
            },
            .i64 => switch (args.width.?) {
                8 => if (args.signedness.? == .signed) return .i64_extend8_s else unreachable,
                16 => if (args.signedness.? == .signed) return .i64_extend16_s else unreachable,
                32 => if (args.signedness.? == .signed) return .i64_extend32_s else unreachable,
                else => unreachable,
            },
            .f32, .f64 => unreachable,
        },
    }
}

test "Wasm - buildOpcode" {
    // Make sure buildOpcode is referenced, and test some examples
    const i32_const = buildOpcode(.{ .op = .@"const", .valtype1 = .i32 });
    const end = buildOpcode(.{ .op = .end });
    const local_get = buildOpcode(.{ .op = .local_get });
    const i64_extend32_s = buildOpcode(.{ .op = .extend, .valtype1 = .i64, .width = 32, .signedness = .signed });
    const f64_reinterpret_i64 = buildOpcode(.{ .op = .reinterpret, .valtype1 = .f64, .valtype2 = .i64 });

    try testing.expectEqual(@as(wasm.Opcode, .i32_const), i32_const);
    try testing.expectEqual(@as(wasm.Opcode, .end), end);
    try testing.expectEqual(@as(wasm.Opcode, .local_get), local_get);
    try testing.expectEqual(@as(wasm.Opcode, .i64_extend32_s), i64_extend32_s);
    try testing.expectEqual(@as(wasm.Opcode, .f64_reinterpret_i64), f64_reinterpret_i64);
}

pub const Result = union(enum) {
    /// The codegen bytes have been appended to `Context.code`
    appended: void,
    /// The data is managed externally and are part of the `Result`
    externally_managed: []const u8,
};

/// Hashmap to store generated `WValue` for each `Inst`
pub const ValueTable = std.AutoHashMapUnmanaged(*Inst, WValue);

/// Code represents the `Code` section of wasm that
/// belongs to a function
pub const Context = struct {
    /// Reference to the function declaration the code
    /// section belongs to
    decl: *Decl,
    air: Air,
    liveness: Liveness,
    gpa: *mem.Allocator,
    /// Table to save `WValue`'s generated by an `Inst`
    values: ValueTable,
    /// Mapping from *Inst.Block to block ids
    blocks: std.AutoArrayHashMapUnmanaged(*Inst.Block, u32) = .{},
    /// `bytes` contains the wasm bytecode belonging to the 'code' section.
    code: ArrayList(u8),
    /// Contains the generated function type bytecode for the current function
    /// found in `decl`
    func_type_data: ArrayList(u8),
    /// The index the next local generated will have
    /// NOTE: arguments share the index with locals therefore the first variable
    /// will have the index that comes after the last argument's index
    local_index: u32 = 0,
    /// If codegen fails, an error messages will be allocated and saved in `err_msg`
    err_msg: *Module.ErrorMsg,
    /// Current block depth. Used to calculate the relative difference between a break
    /// and block
    block_depth: u32 = 0,
    /// List of all locals' types generated throughout this declaration
    /// used to emit locals count at start of 'code' section.
    locals: std.ArrayListUnmanaged(u8),
    /// The Target we're emitting (used to call intInfo)
    target: std.Target,
    /// Table with the global error set. Consists of every error found in
    /// the compiled code. Each error name maps to a `Module.ErrorInt` which is emitted
    /// during codegen to determine the error value.
    global_error_set: std.StringHashMapUnmanaged(Module.ErrorInt),

    const InnerError = error{
        OutOfMemory,
        CodegenFail,
        /// Can occur when dereferencing a pointer that points to a `Decl` of which the analysis has failed
        AnalysisFail,
    };

    pub fn deinit(self: *Context) void {
        self.values.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
        self.locals.deinit(self.gpa);
        self.* = undefined;
    }

    /// Sets `err_msg` on `Context` and returns `error.CodegemFail` which is caught in link/Wasm.zig
    fn fail(self: *Context, src: LazySrcLoc, comptime fmt: []const u8, args: anytype) InnerError {
        const src_loc = src.toSrcLocWithDecl(self.decl);
        self.err_msg = try Module.ErrorMsg.create(self.gpa, src_loc, fmt, args);
        return error.CodegenFail;
    }

    /// Resolves the `WValue` for the given instruction `inst`
    /// When the given instruction has a `Value`, it returns a constant instead
    fn resolveInst(self: Context, inst: *Inst) WValue {
        if (!inst.ty.hasCodeGenBits()) return .none;

        if (inst.value()) |_| {
            return WValue{ .constant = inst };
        }

        return self.values.get(inst).?; // Instruction does not dominate all uses!
    }

    /// Using a given `Type`, returns the corresponding wasm Valtype
    fn typeToValtype(self: *Context, src: LazySrcLoc, ty: Type) InnerError!wasm.Valtype {
        return switch (ty.zigTypeTag()) {
            .Float => blk: {
                const bits = ty.floatBits(self.target);
                if (bits == 16 or bits == 32) break :blk wasm.Valtype.f32;
                if (bits == 64) break :blk wasm.Valtype.f64;
                return self.fail(src, "Float bit size not supported by wasm: '{d}'", .{bits});
            },
            .Int => blk: {
                const info = ty.intInfo(self.target);
                if (info.bits <= 32) break :blk wasm.Valtype.i32;
                if (info.bits > 32 and info.bits <= 64) break :blk wasm.Valtype.i64;
                return self.fail(src, "Integer bit size not supported by wasm: '{d}'", .{info.bits});
            },
            .Enum => switch (ty.tag()) {
                .enum_simple => wasm.Valtype.i32,
                else => self.typeToValtype(
                    src,
                    ty.cast(Type.Payload.EnumFull).?.data.tag_ty,
                ),
            },
            .Bool,
            .Pointer,
            .ErrorSet,
            => wasm.Valtype.i32,
            .Struct, .ErrorUnion => unreachable, // Multi typed, must be handled individually.
            else => self.fail(src, "TODO - Wasm valtype for type '{s}'", .{ty.zigTypeTag()}),
        };
    }

    /// Using a given `Type`, returns the byte representation of its wasm value type
    fn genValtype(self: *Context, src: LazySrcLoc, ty: Type) InnerError!u8 {
        return wasm.valtype(try self.typeToValtype(src, ty));
    }

    /// Using a given `Type`, returns the corresponding wasm value type
    /// Differently from `genValtype` this also allows `void` to create a block
    /// with no return type
    fn genBlockType(self: *Context, src: LazySrcLoc, ty: Type) InnerError!u8 {
        return switch (ty.tag()) {
            .void, .noreturn => wasm.block_empty,
            else => self.genValtype(src, ty),
        };
    }

    /// Writes the bytecode depending on the given `WValue` in `val`
    fn emitWValue(self: *Context, val: WValue) InnerError!void {
        const writer = self.code.writer();
        switch (val) {
            .multi_value => unreachable, // multi_value can never be written directly, and must be accessed individually
            .none, .code_offset => {}, // no-op
            .local => |idx| {
                try writer.writeByte(wasm.opcode(.local_get));
                try leb.writeULEB128(writer, idx);
            },
            .constant => |inst| try self.emitConstant(inst.src, inst.value().?, inst.ty), // creates a new constant onto the stack
        }
    }

    /// Creates one or multiple locals for a given `Type`.
    /// Returns a corresponding `Wvalue` that can either be of tag
    /// local or multi_value
    fn allocLocal(self: *Context, ty: Type) InnerError!WValue {
        const initial_index = self.local_index;
        switch (ty.zigTypeTag()) {
            .Struct => {
                // for each struct field, generate a local
                const struct_data: *Module.Struct = ty.castTag(.@"struct").?.data;
                const fields_len = @intCast(u32, struct_data.fields.count());
                try self.locals.ensureCapacity(self.gpa, self.locals.items.len + fields_len);
                for (struct_data.fields.values()) |*value| {
                    const val_type = try self.genValtype(
                        .{ .node_offset = struct_data.node_offset },
                        value.ty,
                    );
                    self.locals.appendAssumeCapacity(val_type);
                    self.local_index += 1;
                }
                return WValue{ .multi_value = .{
                    .index = initial_index,
                    .count = fields_len,
                } };
            },
            .ErrorUnion => {
                const payload_type = ty.errorUnionChild();
                const val_type = try self.genValtype(.{ .node_offset = 0 }, payload_type);

                // we emit the error value as the first local, and the payload as the following.
                // The first local is also used to find the index of the error and payload.
                //
                // TODO: Add support where the payload is a type that contains multiple locals such as a struct.
                try self.locals.ensureCapacity(self.gpa, self.locals.items.len + 2);
                self.locals.appendAssumeCapacity(wasm.valtype(.i32)); // error values are always i32
                self.locals.appendAssumeCapacity(val_type);
                self.local_index += 2;

                return WValue{ .multi_value = .{
                    .index = initial_index,
                    .count = 2,
                } };
            },
            else => {
                const valtype = try self.genValtype(.{ .node_offset = 0 }, ty);
                try self.locals.append(self.gpa, valtype);
                self.local_index += 1;
                return WValue{ .local = initial_index };
            },
        }
    }

    fn genFunctype(self: *Context) InnerError!void {
        assert(self.decl.has_tv);
        const ty = self.decl.ty;
        const writer = self.func_type_data.writer();

        try writer.writeByte(wasm.function_type);

        // param types
        try leb.writeULEB128(writer, @intCast(u32, ty.fnParamLen()));
        if (ty.fnParamLen() != 0) {
            const params = try self.gpa.alloc(Type, ty.fnParamLen());
            defer self.gpa.free(params);
            ty.fnParamTypes(params);
            for (params) |param_type| {
                // Can we maybe get the source index of each param?
                const val_type = try self.genValtype(.{ .node_offset = 0 }, param_type);
                try writer.writeByte(val_type);
            }
        }

        // return type
        const return_type = ty.fnReturnType();
        switch (return_type.zigTypeTag()) {
            .Void, .NoReturn => try leb.writeULEB128(writer, @as(u32, 0)),
            .Struct => return self.fail(.{ .node_offset = 0 }, "TODO: Implement struct as return type for wasm", .{}),
            .Optional => return self.fail(.{ .node_offset = 0 }, "TODO: Implement optionals as return type for wasm", .{}),
            .ErrorUnion => {
                const val_type = try self.genValtype(
                    .{ .node_offset = 0 },
                    return_type.errorUnionChild(),
                );

                // write down the amount of return values
                try leb.writeULEB128(writer, @as(u32, 2));
                try writer.writeByte(wasm.valtype(.i32)); // error code is always an i32 integer.
                try writer.writeByte(val_type);
            },
            else => {
                try leb.writeULEB128(writer, @as(u32, 1));
                // Can we maybe get the source index of the return type?
                const val_type = try self.genValtype(.{ .node_offset = 0 }, return_type);
                try writer.writeByte(val_type);
            },
        }
    }

    pub fn genFunc(self: *Context, func: *Module.Fn) InnerError!Result {
        try self.genFunctype();

        // Write instructions
        // TODO: check for and handle death of instructions

        // Reserve space to write the size after generating the code as well as space for locals count
        try self.code.resize(10);

        try self.genBody(func.body);

        // finally, write our local types at the 'offset' position
        {
            leb.writeUnsignedFixed(5, self.code.items[5..10], @intCast(u32, self.locals.items.len));

            // offset into 'code' section where we will put our locals types
            var local_offset: usize = 10;

            // emit the actual locals amount
            for (self.locals.items) |local| {
                var buf: [6]u8 = undefined;
                leb.writeUnsignedFixed(5, buf[0..5], @as(u32, 1));
                buf[5] = local;
                try self.code.insertSlice(local_offset, &buf);
                local_offset += 6;
            }
        }

        const writer = self.code.writer();
        try writer.writeByte(wasm.opcode(.end));

        // Fill in the size of the generated code to the reserved space at the
        // beginning of the buffer.
        const size = self.code.items.len - 5 + self.decl.fn_link.wasm.idx_refs.items.len * 5;
        leb.writeUnsignedFixed(5, self.code.items[0..5], @intCast(u32, size));

        // codegen data has been appended to `code`
        return Result.appended;
    }

    /// Generates the wasm bytecode for the function declaration belonging to `Context`
    pub fn gen(self: *Context, typed_value: TypedValue) InnerError!Result {
        switch (typed_value.ty.zigTypeTag()) {
            .Fn => {
                try self.genFunctype();
                if (typed_value.val.castTag(.extern_fn)) |_| return Result.appended; // don't need code body for extern functions
                return self.fail("TODO implement wasm codegen for function pointers", .{});
            },
            .Array => {
                if (typed_value.val.castTag(.bytes)) |payload| {
                    if (typed_value.ty.sentinel()) |sentinel| {
                        try self.code.appendSlice(payload.data);

                        switch (try self.gen(.{
                            .ty = typed_value.ty.elemType(),
                            .val = sentinel,
                        })) {
                            .appended => return Result.appended,
                            .externally_managed => |data| {
                                try self.code.appendSlice(data);
                                return Result.appended;
                            },
                        }
                    }
                    return Result{ .externally_managed = payload.data };
                } else return self.fail(.{ .node_offset = 0 }, "TODO implement gen for more kinds of arrays", .{});
            },
            .Int => {
                const info = typed_value.ty.intInfo(self.target);
                if (info.bits == 8 and info.signedness == .unsigned) {
                    const int_byte = typed_value.val.toUnsignedInt();
                    try self.code.append(@intCast(u8, int_byte));
                    return Result.appended;
                }
                return self.fail(.{ .node_offset = 0 }, "TODO: Implement codegen for int type: '{}'", .{typed_value.ty});
            },
            else => |tag| return self.fail(.{ .node_offset = 0 }, "TODO: Implement zig type codegen for type: '{s}'", .{tag}),
        }
    }

    fn genInst(self: *Context, inst: *Inst) InnerError!WValue {
        return switch (inst.tag) {
            .add => self.genBinOp(inst.castTag(.add).?, .add),
            .alloc => self.genAlloc(inst.castTag(.alloc).?),
            .arg => self.genArg(inst.castTag(.arg).?),
            .bit_and => self.genBinOp(inst.castTag(.bit_and).?, .@"and"),
            .bitcast => self.genBitcast(inst.castTag(.bitcast).?),
            .bit_or => self.genBinOp(inst.castTag(.bit_or).?, .@"or"),
            .block => self.genBlock(inst.castTag(.block).?),
            .bool_and => self.genBinOp(inst.castTag(.bool_and).?, .@"and"),
            .bool_or => self.genBinOp(inst.castTag(.bool_or).?, .@"or"),
            .breakpoint => self.genBreakpoint(inst.castTag(.breakpoint).?),
            .br => self.genBr(inst.castTag(.br).?),
            .call => self.genCall(inst.castTag(.call).?),
            .cmp_eq => self.genCmp(inst.castTag(.cmp_eq).?, .eq),
            .cmp_gte => self.genCmp(inst.castTag(.cmp_gte).?, .gte),
            .cmp_gt => self.genCmp(inst.castTag(.cmp_gt).?, .gt),
            .cmp_lte => self.genCmp(inst.castTag(.cmp_lte).?, .lte),
            .cmp_lt => self.genCmp(inst.castTag(.cmp_lt).?, .lt),
            .cmp_neq => self.genCmp(inst.castTag(.cmp_neq).?, .neq),
            .condbr => self.genCondBr(inst.castTag(.condbr).?),
            .constant => unreachable,
            .dbg_stmt => WValue.none,
            .div => self.genBinOp(inst.castTag(.div).?, .div),
            .is_err => self.genIsErr(inst.castTag(.is_err).?, .i32_ne),
            .is_non_err => self.genIsErr(inst.castTag(.is_non_err).?, .i32_eq),
            .load => self.genLoad(inst.castTag(.load).?),
            .loop => self.genLoop(inst.castTag(.loop).?),
            .mul => self.genBinOp(inst.castTag(.mul).?, .mul),
            .not => self.genNot(inst.castTag(.not).?),
            .ret => self.genRet(inst.castTag(.ret).?),
            .retvoid => WValue.none,
            .store => self.genStore(inst.castTag(.store).?),
            .struct_field_ptr => self.genStructFieldPtr(inst.castTag(.struct_field_ptr).?),
            .sub => self.genBinOp(inst.castTag(.sub).?, .sub),
            .switchbr => self.genSwitchBr(inst.castTag(.switchbr).?),
            .unreach => self.genUnreachable(inst.castTag(.unreach).?),
            .unwrap_errunion_payload => self.genUnwrapErrUnionPayload(inst.castTag(.unwrap_errunion_payload).?),
            .wrap_errunion_payload => self.genWrapErrUnionPayload(inst.castTag(.wrap_errunion_payload).?),
            .xor => self.genBinOp(inst.castTag(.xor).?, .xor),
            else => self.fail(.{ .node_offset = 0 }, "TODO: Implement wasm inst: {s}", .{inst.tag}),
        };
    }

    fn genBody(self: *Context, body: ir.Body) InnerError!void {
        for (body.instructions) |inst| {
            const result = try self.genInst(inst);
            try self.values.putNoClobber(self.gpa, inst, result);
        }
    }

    fn genRet(self: *Context, inst: *Inst.UnOp) InnerError!WValue {
        // TODO: Implement tail calls
        const operand = self.resolveInst(inst.operand);
        try self.emitWValue(operand);
        try self.code.append(wasm.opcode(.@"return"));
        return .none;
    }

    fn genCall(self: *Context, inst: *Inst.Call) InnerError!WValue {
        const func_val = inst.func.value().?;

        const target: *Decl = blk: {
            if (func_val.castTag(.function)) |func| {
                break :blk func.data.owner_decl;
            } else if (func_val.castTag(.extern_fn)) |ext_fn| {
                break :blk ext_fn.data;
            }
            return self.fail(inst.base.src, "Expected a function, but instead found type '{s}'", .{func_val.tag()});
        };

        for (inst.args) |arg| {
            const arg_val = self.resolveInst(arg);
            try self.emitWValue(arg_val);
        }

        try self.code.append(wasm.opcode(.call));

        // The function index immediate argument will be filled in using this data
        // in link.Wasm.flush().
        try self.decl.fn_link.wasm.idx_refs.append(self.gpa, .{
            .offset = @intCast(u32, self.code.items.len),
            .decl = target,
        });

        return .none;
    }

    fn genAlloc(self: *Context, inst: *Inst.NoOp) InnerError!WValue {
        const elem_type = inst.base.ty.elemType();
        return self.allocLocal(elem_type);
    }

    fn genStore(self: *Context, inst: *Inst.BinOp) InnerError!WValue {
        const writer = self.code.writer();

        const lhs = self.resolveInst(inst.lhs);
        const rhs = self.resolveInst(inst.rhs);

        switch (lhs) {
            .multi_value => |multi_value| switch (rhs) {
                // When assigning a value to a multi_value such as a struct,
                // we simply assign the local_index to the rhs one.
                // This allows us to update struct fields without having to individually
                // set each local as each field's index will be calculated off the struct's base index
                .multi_value => self.values.put(self.gpa, inst.lhs, rhs) catch unreachable, // Instruction does not dominate all uses!
                .constant, .none => {
                    // emit all values onto the stack if constant
                    try self.emitWValue(rhs);

                    // for each local, pop the stack value into the local
                    // As the last element is on top of the stack, we must populate the locals
                    // in reverse.
                    var i: u32 = multi_value.count;
                    while (i > 0) : (i -= 1) {
                        try writer.writeByte(wasm.opcode(.local_set));
                        try leb.writeULEB128(writer, multi_value.index + i - 1);
                    }
                },
                else => unreachable,
            },
            .local => |local| {
                try self.emitWValue(rhs);
                try writer.writeByte(wasm.opcode(.local_set));
                try leb.writeULEB128(writer, local);
            },
            else => unreachable,
        }
        return .none;
    }

    fn genLoad(self: *Context, inst: *Inst.UnOp) InnerError!WValue {
        return self.resolveInst(inst.operand);
    }

    fn genArg(self: *Context, inst: *Inst.Arg) InnerError!WValue {
        _ = inst;
        // arguments share the index with locals
        defer self.local_index += 1;
        return WValue{ .local = self.local_index };
    }

    fn genBinOp(self: *Context, inst: *Inst.BinOp, op: Op) InnerError!WValue {
        const lhs = self.resolveInst(inst.lhs);
        const rhs = self.resolveInst(inst.rhs);

        // it's possible for both lhs and/or rhs to return an offset as well,
        // in which case we return the first offset occurance we find.
        const offset = blk: {
            if (lhs == .code_offset) break :blk lhs.code_offset;
            if (rhs == .code_offset) break :blk rhs.code_offset;
            break :blk self.code.items.len;
        };

        try self.emitWValue(lhs);
        try self.emitWValue(rhs);

        const opcode: wasm.Opcode = buildOpcode(.{
            .op = op,
            .valtype1 = try self.typeToValtype(inst.base.src, inst.base.ty),
            .signedness = if (inst.base.ty.isSignedInt()) .signed else .unsigned,
        });
        try self.code.append(wasm.opcode(opcode));
        return WValue{ .code_offset = offset };
    }

    fn emitConstant(self: *Context, src: LazySrcLoc, value: Value, ty: Type) InnerError!void {
        const writer = self.code.writer();
        switch (ty.zigTypeTag()) {
            .Int => {
                // write opcode
                const opcode: wasm.Opcode = buildOpcode(.{
                    .op = .@"const",
                    .valtype1 = try self.typeToValtype(src, ty),
                });
                try writer.writeByte(wasm.opcode(opcode));
                // write constant
                switch (ty.intInfo(self.target).signedness) {
                    .signed => try leb.writeILEB128(writer, value.toSignedInt()),
                    .unsigned => try leb.writeILEB128(writer, value.toUnsignedInt()),
                }
            },
            .Bool => {
                // write opcode
                try writer.writeByte(wasm.opcode(.i32_const));
                // write constant
                try leb.writeILEB128(writer, value.toSignedInt());
            },
            .Float => {
                // write opcode
                const opcode: wasm.Opcode = buildOpcode(.{
                    .op = .@"const",
                    .valtype1 = try self.typeToValtype(src, ty),
                });
                try writer.writeByte(wasm.opcode(opcode));
                // write constant
                switch (ty.floatBits(self.target)) {
                    0...32 => try writer.writeIntLittle(u32, @bitCast(u32, value.toFloat(f32))),
                    64 => try writer.writeIntLittle(u64, @bitCast(u64, value.toFloat(f64))),
                    else => |bits| return self.fail(src, "Wasm TODO: emitConstant for float with {d} bits", .{bits}),
                }
            },
            .Pointer => {
                if (value.castTag(.decl_ref)) |payload| {
                    const decl = payload.data;

                    // offset into the offset table within the 'data' section
                    const ptr_width = self.target.cpu.arch.ptrBitWidth() / 8;
                    try writer.writeByte(wasm.opcode(.i32_const));
                    try leb.writeULEB128(writer, decl.link.wasm.offset_index * ptr_width);

                    // memory instruction followed by their memarg immediate
                    // memarg ::== x:u32, y:u32 => {align x, offset y}
                    try writer.writeByte(wasm.opcode(.i32_load));
                    try leb.writeULEB128(writer, @as(u32, 0));
                    try leb.writeULEB128(writer, @as(u32, 0));
                } else return self.fail(src, "Wasm TODO: emitConstant for other const pointer tag {s}", .{value.tag()});
            },
            .Void => {},
            .Enum => {
                if (value.castTag(.enum_field_index)) |field_index| {
                    switch (ty.tag()) {
                        .enum_simple => {
                            try writer.writeByte(wasm.opcode(.i32_const));
                            try leb.writeULEB128(writer, field_index.data);
                        },
                        .enum_full, .enum_nonexhaustive => {
                            const enum_full = ty.cast(Type.Payload.EnumFull).?.data;
                            if (enum_full.values.count() != 0) {
                                const tag_val = enum_full.values.keys()[field_index.data];
                                try self.emitConstant(src, tag_val, enum_full.tag_ty);
                            } else {
                                try writer.writeByte(wasm.opcode(.i32_const));
                                try leb.writeULEB128(writer, field_index.data);
                            }
                        },
                        else => unreachable,
                    }
                } else {
                    var int_tag_buffer: Type.Payload.Bits = undefined;
                    const int_tag_ty = ty.intTagType(&int_tag_buffer);
                    try self.emitConstant(src, value, int_tag_ty);
                }
            },
            .ErrorSet => {
                const error_index = self.global_error_set.get(value.getError().?).?;
                try writer.writeByte(wasm.opcode(.i32_const));
                try leb.writeULEB128(writer, error_index);
            },
            .ErrorUnion => {
                const data = value.castTag(.error_union).?.data;
                const error_type = ty.errorUnionSet();
                const payload_type = ty.errorUnionChild();
                if (value.getError()) |_| {
                    // write the error value
                    try self.emitConstant(src, data, error_type);

                    // no payload, so write a '0' const
                    const opcode: wasm.Opcode = buildOpcode(.{
                        .op = .@"const",
                        .valtype1 = try self.typeToValtype(src, payload_type),
                    });
                    try writer.writeByte(wasm.opcode(opcode));
                    try leb.writeULEB128(writer, @as(u32, 0));
                } else {
                    // no error, so write a '0' const
                    try writer.writeByte(wasm.opcode(.i32_const));
                    try leb.writeULEB128(writer, @as(u32, 0));
                    // after the error code, we emit the payload
                    try self.emitConstant(src, data, payload_type);
                }
            },
            else => |zig_type| return self.fail(src, "Wasm TODO: emitConstant for zigTypeTag {s}", .{zig_type}),
        }
    }

    fn genBlock(self: *Context, block: *Inst.Block) InnerError!WValue {
        const block_ty = try self.genBlockType(block.base.src, block.base.ty);

        try self.startBlock(.block, block_ty, null);
        // Here we set the current block idx, so breaks know the depth to jump
        // to when breaking out.
        try self.blocks.putNoClobber(self.gpa, block, self.block_depth);
        try self.genBody(block.body);
        try self.endBlock();

        return .none;
    }

    /// appends a new wasm block to the code section and increases the `block_depth` by 1
    fn startBlock(self: *Context, block_type: wasm.Opcode, valtype: u8, with_offset: ?usize) !void {
        self.block_depth += 1;
        if (with_offset) |offset| {
            try self.code.insert(offset, wasm.opcode(block_type));
            try self.code.insert(offset + 1, valtype);
        } else {
            try self.code.append(wasm.opcode(block_type));
            try self.code.append(valtype);
        }
    }

    /// Ends the current wasm block and decreases the `block_depth` by 1
    fn endBlock(self: *Context) !void {
        try self.code.append(wasm.opcode(.end));
        self.block_depth -= 1;
    }

    fn genLoop(self: *Context, loop: *Inst.Loop) InnerError!WValue {
        const loop_ty = try self.genBlockType(loop.base.src, loop.base.ty);

        try self.startBlock(.loop, loop_ty, null);
        try self.genBody(loop.body);

        // breaking to the index of a loop block will continue the loop instead
        try self.code.append(wasm.opcode(.br));
        try leb.writeULEB128(self.code.writer(), @as(u32, 0));

        try self.endBlock();

        return .none;
    }

    fn genCondBr(self: *Context, condbr: *Inst.CondBr) InnerError!WValue {
        const condition = self.resolveInst(condbr.condition);
        const writer = self.code.writer();

        // TODO: Handle death instructions for then and else body

        // insert blocks at the position of `offset` so
        // the condition can jump to it
        const offset = switch (condition) {
            .code_offset => |offset| offset,
            else => blk: {
                const offset = self.code.items.len;
                try self.emitWValue(condition);
                break :blk offset;
            },
        };
        const block_ty = try self.genBlockType(condbr.base.src, condbr.base.ty);
        try self.startBlock(.block, block_ty, offset);

        // we inserted the block in front of the condition
        // so now check if condition matches. If not, break outside this block
        // and continue with the then codepath
        try writer.writeByte(wasm.opcode(.br_if));
        try leb.writeULEB128(writer, @as(u32, 0));

        try self.genBody(condbr.else_body);
        try self.endBlock();

        // Outer block that matches the condition
        try self.genBody(condbr.then_body);

        return .none;
    }

    fn genCmp(self: *Context, inst: *Inst.BinOp, op: std.math.CompareOperator) InnerError!WValue {
        // save offset, so potential conditions can insert blocks in front of
        // the comparison that we can later jump back to
        const offset = self.code.items.len;

        const lhs = self.resolveInst(inst.lhs);
        const rhs = self.resolveInst(inst.rhs);

        try self.emitWValue(lhs);
        try self.emitWValue(rhs);

        const signedness: std.builtin.Signedness = blk: {
            // by default we tell the operand type is unsigned (i.e. bools and enum values)
            if (inst.lhs.ty.zigTypeTag() != .Int) break :blk .unsigned;

            // incase of an actual integer, we emit the correct signedness
            break :blk inst.lhs.ty.intInfo(self.target).signedness;
        };
        const opcode: wasm.Opcode = buildOpcode(.{
            .valtype1 = try self.typeToValtype(inst.base.src, inst.lhs.ty),
            .op = switch (op) {
                .lt => .lt,
                .lte => .le,
                .eq => .eq,
                .neq => .ne,
                .gte => .ge,
                .gt => .gt,
            },
            .signedness = signedness,
        });
        try self.code.append(wasm.opcode(opcode));
        return WValue{ .code_offset = offset };
    }

    fn genBr(self: *Context, br: *Inst.Br) InnerError!WValue {
        // if operand has codegen bits we should break with a value
        if (br.operand.ty.hasCodeGenBits()) {
            const operand = self.resolveInst(br.operand);
            try self.emitWValue(operand);
        }

        // We map every block to its block index.
        // We then determine how far we have to jump to it by substracting it from current block depth
        const idx: u32 = self.block_depth - self.blocks.get(br.block).?;
        const writer = self.code.writer();
        try writer.writeByte(wasm.opcode(.br));
        try leb.writeULEB128(writer, idx);

        return .none;
    }

    fn genNot(self: *Context, not: *Inst.UnOp) InnerError!WValue {
        const offset = self.code.items.len;

        const operand = self.resolveInst(not.operand);
        try self.emitWValue(operand);

        // wasm does not have booleans nor the `not` instruction, therefore compare with 0
        // to create the same logic
        const writer = self.code.writer();
        try writer.writeByte(wasm.opcode(.i32_const));
        try leb.writeILEB128(writer, @as(i32, 0));

        try writer.writeByte(wasm.opcode(.i32_eq));

        return WValue{ .code_offset = offset };
    }

    fn genBreakpoint(self: *Context, breakpoint: *Inst.NoOp) InnerError!WValue {
        _ = self;
        _ = breakpoint;
        // unsupported by wasm itself. Can be implemented once we support DWARF
        // for wasm
        return .none;
    }

    fn genUnreachable(self: *Context, unreach: *Inst.NoOp) InnerError!WValue {
        _ = unreach;
        try self.code.append(wasm.opcode(.@"unreachable"));
        return .none;
    }

    fn genBitcast(self: *Context, bitcast: *Inst.UnOp) InnerError!WValue {
        return self.resolveInst(bitcast.operand);
    }

    fn genStructFieldPtr(self: *Context, inst: *Inst.StructFieldPtr) InnerError!WValue {
        const struct_ptr = self.resolveInst(inst.struct_ptr);

        return WValue{ .local = struct_ptr.multi_value.index + @intCast(u32, inst.field_index) };
    }

    fn genSwitchBr(self: *Context, inst: *Inst.SwitchBr) InnerError!WValue {
        const target = self.resolveInst(inst.target);
        const target_ty = inst.target.ty;
        const valtype = try self.typeToValtype(.{ .node_offset = 0 }, target_ty);
        const blocktype = try self.genBlockType(inst.base.src, inst.base.ty);

        const signedness: std.builtin.Signedness = blk: {
            // by default we tell the operand type is unsigned (i.e. bools and enum values)
            if (target_ty.zigTypeTag() != .Int) break :blk .unsigned;

            // incase of an actual integer, we emit the correct signedness
            break :blk target_ty.intInfo(self.target).signedness;
        };
        for (inst.cases) |case| {
            // create a block for each case, when the condition does not match we break out of it
            try self.startBlock(.block, blocktype, null);
            try self.emitWValue(target);
            try self.emitConstant(.{ .node_offset = 0 }, case.item, target_ty);
            const opcode = buildOpcode(.{
                .valtype1 = valtype,
                .op = .ne, // not equal because we jump out the block if it does not match the condition
                .signedness = signedness,
            });
            try self.code.append(wasm.opcode(opcode));
            try self.code.append(wasm.opcode(.br_if));
            try leb.writeULEB128(self.code.writer(), @as(u32, 0));

            // emit our block code
            try self.genBody(case.body);

            // end the block we created earlier
            try self.endBlock();
        }

        // finally, emit the else case if it exists. Here we will not have to
        // check for a condition, so also no need to emit a block.
        try self.genBody(inst.else_body);

        return .none;
    }

    fn genIsErr(self: *Context, inst: *Inst.UnOp, opcode: wasm.Opcode) InnerError!WValue {
        const operand = self.resolveInst(inst.operand);
        const offset = self.code.items.len;
        const writer = self.code.writer();

        // load the error value which is positioned at multi_value's index
        try self.emitWValue(.{ .local = operand.multi_value.index });
        // Compare the error value with '0'
        try writer.writeByte(wasm.opcode(.i32_const));
        try leb.writeILEB128(writer, @as(i32, 0));

        try writer.writeByte(@enumToInt(opcode));

        return WValue{ .code_offset = offset };
    }

    fn genUnwrapErrUnionPayload(self: *Context, inst: *Inst.UnOp) InnerError!WValue {
        const operand = self.resolveInst(inst.operand);
        // The index of multi_value contains the error code. To get the initial index of the payload we get
        // the following index. Next, convert it to a `WValue.local`
        //
        // TODO: Check if payload is a type that requires a multi_value as well and emit that instead. i.e. a struct.
        return WValue{ .local = operand.multi_value.index + 1 };
    }

    fn genWrapErrUnionPayload(self: *Context, inst: *Inst.UnOp) InnerError!WValue {
        return self.resolveInst(inst.operand);
    }
};
