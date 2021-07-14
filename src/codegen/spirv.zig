const std = @import("std");
const Allocator = std.mem.Allocator;
const Target = std.Target;
const log = std.log.scoped(.codegen);
const assert = std.debug.assert;

const spec = @import("spirv/spec.zig");
const Opcode = spec.Opcode;

const Module = @import("../Module.zig");
const Decl = Module.Decl;
const Type = @import("../type.zig").Type;
const Value = @import("../value.zig").Value;
const LazySrcLoc = Module.LazySrcLoc;
const Air = @import("../Air.zig");

pub const Word = u32;
pub const ResultId = u32;

pub const TypeMap = std.HashMap(Type, u32, Type.HashContext64, std.hash_map.default_max_load_percentage);
pub const InstMap = std.AutoHashMap(Air.Inst.Index, ResultId);

const IncomingBlock = struct {
    src_label_id: ResultId,
    break_value_id: ResultId,
};

pub const BlockMap = std.AutoHashMap(Air.Inst.Index, struct {
    label_id: ResultId,
    incoming_blocks: *std.ArrayListUnmanaged(IncomingBlock),
});

pub fn writeOpcode(code: *std.ArrayList(Word), opcode: Opcode, arg_count: u16) !void {
    const word_count: Word = arg_count + 1;
    try code.append((word_count << 16) | @enumToInt(opcode));
}

pub fn writeInstruction(code: *std.ArrayList(Word), opcode: Opcode, args: []const Word) !void {
    try writeOpcode(code, opcode, @intCast(u16, args.len));
    try code.appendSlice(args);
}

pub fn writeInstructionWithString(code: *std.ArrayList(Word), opcode: Opcode, args: []const Word, str: []const u8) !void {
    // Str needs to be written zero-terminated, so we need to add one to the length.
    const zero_terminated_len = str.len + 1;
    const str_words = (zero_terminated_len + @sizeOf(Word) - 1) / @sizeOf(Word);

    try writeOpcode(code, opcode, @intCast(u16, args.len + str_words));
    try code.ensureUnusedCapacity(args.len + str_words);
    code.appendSliceAssumeCapacity(args);

    // TODO: Not actually sure whether this is correct for big-endian.
    // See https://www.khronos.org/registry/spir-v/specs/unified1/SPIRV.html#Literal
    var i: usize = 0;
    while (i < zero_terminated_len) : (i += @sizeOf(Word)) {
        var word: Word = 0;

        var j: usize = 0;
        while (j < @sizeOf(Word) and i + j < str.len) : (j += 1) {
            word |= @as(Word, str[i + j]) << @intCast(std.math.Log2Int(Word), j * std.meta.bitCount(u8));
        }

        code.appendAssumeCapacity(word);
    }
}

/// This structure represents a SPIR-V (binary) module being compiled, and keeps track of all relevant information.
/// That includes the actual instructions, the current result-id bound, and data structures for querying result-id's
/// of data which needs to be persistent over different calls to Decl code generation.
pub const SPIRVModule = struct {
    /// A general-purpose allocator which may be used to allocate temporary resources required for compilation.
    gpa: *Allocator,

    /// The parent module.
    module: *Module,

    /// SPIR-V instructions return result-ids. This variable holds the module-wide counter for these.
    next_result_id: ResultId,

    /// Code of the actual SPIR-V binary, divided into the relevant logical sections.
    /// Note: To save some bytes, these could also be unmanaged, but since there is only one instance of SPIRVModule
    /// and this removes some clutter in the rest of the backend, it's fine like this.
    binary: struct {
        /// OpCapability and OpExtension instructions (in that order).
        capabilities_and_extensions: std.ArrayList(Word),

        /// OpString, OpSourceExtension, OpSource, OpSourceContinued.
        debug_strings: std.ArrayList(Word),

        /// Type declaration instructions, constant instructions, global variable declarations, OpUndef instructions.
        types_globals_constants: std.ArrayList(Word),

        /// Regular functions.
        fn_decls: std.ArrayList(Word),
    },

    /// Global type cache to reduce the amount of generated types.
    types: TypeMap,

    /// Cache for results of OpString instructions for module file names fed to OpSource.
    /// Since OpString is pretty much only used for those, we don't need to keep track of all strings,
    /// just the ones for OpLine. Note that OpLine needs the result of OpString, and not that of OpSource.
    file_names: std.StringHashMap(ResultId),

    pub fn init(gpa: *Allocator, module: *Module) SPIRVModule {
        return .{
            .gpa = gpa,
            .module = module,
            .next_result_id = 1, // 0 is an invalid SPIR-V result ID.
            .binary = .{
                .capabilities_and_extensions = std.ArrayList(Word).init(gpa),
                .debug_strings = std.ArrayList(Word).init(gpa),
                .types_globals_constants = std.ArrayList(Word).init(gpa),
                .fn_decls = std.ArrayList(Word).init(gpa),
            },
            .types = TypeMap.init(gpa),
            .file_names = std.StringHashMap(ResultId).init(gpa),
        };
    }

    pub fn deinit(self: *SPIRVModule) void {
        self.file_names.deinit();
        self.types.deinit();

        self.binary.fn_decls.deinit();
        self.binary.types_globals_constants.deinit();
        self.binary.debug_strings.deinit();
        self.binary.capabilities_and_extensions.deinit();
    }

    pub fn allocResultId(self: *SPIRVModule) Word {
        defer self.next_result_id += 1;
        return self.next_result_id;
    }

    pub fn resultIdBound(self: *SPIRVModule) Word {
        return self.next_result_id;
    }

    fn resolveSourceFileName(self: *SPIRVModule, decl: *Decl) !ResultId {
        const path = decl.namespace.file_scope.sub_file_path;
        const result = try self.file_names.getOrPut(path);
        if (!result.found_existing) {
            result.value_ptr.* = self.allocResultId();
            try writeInstructionWithString(&self.binary.debug_strings, .OpString, &[_]Word{result.value_ptr.*}, path);
            try writeInstruction(&self.binary.debug_strings, .OpSource, &[_]Word{
                @enumToInt(spec.SourceLanguage.Unknown), // TODO: Register Zig source language.
                0, // TODO: Zig version as u32?
                result.value_ptr.*,
            });
        }

        return result.value_ptr.*;
    }
};

/// This structure is used to compile a declaration, and contains all relevant meta-information to deal with that.
pub const DeclGen = struct {
    /// The SPIR-V module  code should be put in.
    spv: *SPIRVModule,

    air: Air,
    liveness: Liveness,

    /// An array of function argument result-ids. Each index corresponds with the
    /// function argument of the same index.
    args: std.ArrayList(ResultId),

    /// A counter to keep track of how many `arg` instructions we've seen yet.
    next_arg_index: u32,

    /// A map keeping track of which instruction generated which result-id.
    inst_results: InstMap,

    /// We need to keep track of result ids for block labels, as well as the 'incoming'
    /// blocks for a block.
    blocks: BlockMap,

    /// The label of the SPIR-V block we are currently generating.
    current_block_label_id: ResultId,

    /// The actual instructions for this function. We need to declare all locals in
    /// the first block, and because we don't know which locals there are going to be,
    /// we're just going to generate everything after the locals-section in this array.
    /// Note: It will not contain OpFunction, OpFunctionParameter, OpVariable and the
    /// initial OpLabel. These will be generated into spv.binary.fn_decls directly.
    code: std.ArrayList(Word),

    /// The decl we are currently generating code for.
    decl: *Decl,

    /// If `gen` returned `Error.AnalysisFail`, this contains an explanatory message.
    /// Memory is owned by `module.gpa`.
    error_msg: ?*Module.ErrorMsg,

    /// Possible errors the `gen` function may return.
    const Error = error{ AnalysisFail, OutOfMemory };

    /// This structure is used to return information about a type typically used for
    /// arithmetic operations. These types may either be integers, floats, or a vector
    /// of these. Most scalar operations also work on vectors, so we can easily represent
    /// those as arithmetic types. If the type is a scalar, 'inner type' refers to the
    /// scalar type. Otherwise, if its a vector, it refers to the vector's element type.
    const ArithmeticTypeInfo = struct {
        /// A classification of the inner type.
        const Class = enum {
            /// A boolean.
            bool,

            /// A regular, **native**, integer.
            /// This is only returned when the backend supports this int as a native type (when
            /// the relevant capability is enabled).
            integer,

            /// A regular float. These are all required to be natively supported. Floating points
            /// for which the relevant capability is not enabled are not emulated.
            float,

            /// An integer of a 'strange' size (which' bit size is not the same as its backing
            /// type. **Note**: this may **also** include power-of-2 integers for which the
            /// relevant capability is not enabled), but still within the limits of the largest
            /// natively supported integer type.
            strange_integer,

            /// An integer with more bits than the largest natively supported integer type.
            composite_integer,
        };

        /// The number of bits in the inner type.
        /// This is the actual number of bits of the type, not the size of the backing integer.
        bits: u16,

        /// Whether the type is a vector.
        is_vector: bool,

        /// Whether the inner type is signed. Only relevant for integers.
        signedness: std.builtin.Signedness,

        /// A classification of the inner type. These scenarios
        /// will all have to be handled slightly different.
        class: Class,
    };

    /// Initialize the common resources of a DeclGen. Some fields are left uninitialized,
    /// only set when `gen` is called.
    pub fn init(spv: *SPIRVModule) DeclGen {
        return .{
            .spv = spv,
            .air = undefined,
            .args = std.ArrayList(ResultId).init(spv.gpa),
            .next_arg_index = undefined,
            .inst_results = InstMap.init(spv.gpa),
            .blocks = BlockMap.init(spv.gpa),
            .current_block_label_id = undefined,
            .code = std.ArrayList(Word).init(spv.gpa),
            .decl = undefined,
            .error_msg = undefined,
        };
    }

    /// Generate the code for `decl`. If a reportable error occured during code generation,
    /// a message is returned by this function. Callee owns the memory. If this function returns such
    /// a reportable error, it is valid to be called again for a different decl.
    pub fn gen(self: *DeclGen, decl: *Decl, air: Air) !?*Module.ErrorMsg {
        // Reset internal resources, we don't want to re-allocate these.
        self.air = &air;
        self.args.items.len = 0;
        self.next_arg_index = 0;
        self.inst_results.clearRetainingCapacity();
        self.blocks.clearRetainingCapacity();
        self.current_block_label_id = undefined;
        self.code.items.len = 0;
        self.decl = decl;
        self.error_msg = null;

        try self.genDecl();
        return self.error_msg;
    }

    /// Free resources owned by the DeclGen.
    pub fn deinit(self: *DeclGen) void {
        self.args.deinit();
        self.inst_results.deinit();
        self.blocks.deinit();
        self.code.deinit();
    }

    fn getTarget(self: *DeclGen) std.Target {
        return self.spv.module.getTarget();
    }

    fn fail(self: *DeclGen, comptime format: []const u8, args: anytype) Error {
        @setCold(true);
        const src: LazySrcLoc = .{ .node_offset = 0 };
        const src_loc = src.toSrcLocWithDecl(self.decl);
        self.error_msg = try Module.ErrorMsg.create(self.spv.module.gpa, src_loc, format, args);
        return error.AnalysisFail;
    }

    fn resolve(self: *DeclGen, inst: Air.Inst.Index) !ResultId {
        if (inst.value()) |val| {
            return self.genConstant(inst.ty, val);
        }

        return self.inst_results.get(inst).?; // Instruction does not dominate all uses!
    }

    fn beginSPIRVBlock(self: *DeclGen, label_id: ResultId) !void {
        try writeInstruction(&self.code, .OpLabel, &[_]Word{label_id});
        self.current_block_label_id = label_id;
    }

    /// SPIR-V requires enabling specific integer sizes through capabilities, and so if they are not enabled, we need
    /// to emulate them in other instructions/types. This function returns, given an integer bit width (signed or unsigned, sign
    /// included), the width of the underlying type which represents it, given the enabled features for the current target.
    /// If the result is `null`, the largest type the target platform supports natively is not able to perform computations using
    /// that size. In this case, multiple elements of the largest type should be used.
    /// The backing type will be chosen as the smallest supported integer larger or equal to it in number of bits.
    /// The result is valid to be used with OpTypeInt.
    /// TODO: The extension SPV_INTEL_arbitrary_precision_integers allows any integer size (at least up to 32 bits).
    /// TODO: This probably needs an ABI-version as well (especially in combination with SPV_INTEL_arbitrary_precision_integers).
    /// TODO: Should the result of this function be cached?
    fn backingIntBits(self: *DeclGen, bits: u16) ?u16 {
        const target = self.getTarget();

        // The backend will never be asked to compiler a 0-bit integer, so we won't have to handle those in this function.
        assert(bits != 0);

        // 8, 16 and 64-bit integers require the Int8, Int16 and Inr64 capabilities respectively.
        // 32-bit integers are always supported (see spec, 2.16.1, Data rules).
        const ints = [_]struct { bits: u16, feature: ?Target.spirv.Feature }{
            .{ .bits = 8, .feature = .Int8 },
            .{ .bits = 16, .feature = .Int16 },
            .{ .bits = 32, .feature = null },
            .{ .bits = 64, .feature = .Int64 },
        };

        for (ints) |int| {
            const has_feature = if (int.feature) |feature|
                Target.spirv.featureSetHas(target.cpu.features, feature)
            else
                true;

            if (bits <= int.bits and has_feature) {
                return int.bits;
            }
        }

        return null;
    }

    /// Return the amount of bits in the largest supported integer type. This is either 32 (always supported), or 64 (if
    /// the Int64 capability is enabled).
    /// Note: The extension SPV_INTEL_arbitrary_precision_integers allows any integer size (at least up to 32 bits).
    /// In theory that could also be used, but since the spec says that it only guarantees support up to 32-bit ints there
    /// is no way of knowing whether those are actually supported.
    /// TODO: Maybe this should be cached?
    fn largestSupportedIntBits(self: *DeclGen) u16 {
        const target = self.getTarget();
        return if (Target.spirv.featureSetHas(target.cpu.features, .Int64))
            64
        else
            32;
    }

    /// Checks whether the type is "composite int", an integer consisting of multiple native integers. These are represented by
    /// arrays of largestSupportedIntBits().
    /// Asserts `ty` is an integer.
    fn isCompositeInt(self: *DeclGen, ty: Type) bool {
        return self.backingIntBits(ty) == null;
    }

    fn arithmeticTypeInfo(self: *DeclGen, ty: Type) !ArithmeticTypeInfo {
        const target = self.getTarget();
        return switch (ty.zigTypeTag()) {
            .Bool => ArithmeticTypeInfo{
                .bits = 1, // Doesn't matter for this class.
                .is_vector = false,
                .signedness = .unsigned, // Technically, but doesn't matter for this class.
                .class = .bool,
            },
            .Float => ArithmeticTypeInfo{
                .bits = ty.floatBits(target),
                .is_vector = false,
                .signedness = .signed, // Technically, but doesn't matter for this class.
                .class = .float,
            },
            .Int => blk: {
                const int_info = ty.intInfo(target);
                // TODO: Maybe it's useful to also return this value.
                const maybe_backing_bits = self.backingIntBits(int_info.bits);
                break :blk ArithmeticTypeInfo{ .bits = int_info.bits, .is_vector = false, .signedness = int_info.signedness, .class = if (maybe_backing_bits) |backing_bits|
                    if (backing_bits == int_info.bits)
                        ArithmeticTypeInfo.Class.integer
                    else
                        ArithmeticTypeInfo.Class.strange_integer
                else
                    .composite_integer };
            },
            // As of yet, there is no vector support in the self-hosted compiler.
            .Vector => self.fail("TODO: SPIR-V backend: implement arithmeticTypeInfo for Vector", .{}),
            // TODO: For which types is this the case?
            else => self.fail("TODO: SPIR-V backend: implement arithmeticTypeInfo for {}", .{ty}),
        };
    }

    /// Generate a constant representing `val`.
    /// TODO: Deduplication?
    fn genConstant(self: *DeclGen, ty: Type, val: Value) Error!ResultId {
        const target = self.getTarget();
        const code = &self.spv.binary.types_globals_constants;
        const result_id = self.spv.allocResultId();
        const result_type_id = try self.genType(ty);

        if (val.isUndef()) {
            try writeInstruction(code, .OpUndef, &[_]Word{ result_type_id, result_id });
            return result_id;
        }

        switch (ty.zigTypeTag()) {
            .Int => {
                const int_info = ty.intInfo(target);
                const backing_bits = self.backingIntBits(int_info.bits) orelse {
                    // Integers too big for any native type are represented as "composite integers": An array of largestSupportedIntBits.
                    return self.fail("TODO: SPIR-V backend: implement composite int constants for {}", .{ty});
                };

                // We can just use toSignedInt/toUnsignedInt here as it returns u64 - a type large enough to hold any
                // SPIR-V native type (up to i/u64 with Int64). If SPIR-V ever supports native ints of a larger size, this
                // might need to be updated.
                assert(self.largestSupportedIntBits() <= std.meta.bitCount(u64));
                var int_bits = if (ty.isSignedInt()) @bitCast(u64, val.toSignedInt()) else val.toUnsignedInt();

                // Mask the low bits which make up the actual integer. This is to make sure that negative values
                // only use the actual bits of the type.
                // TODO: Should this be the backing type bits or the actual type bits?
                int_bits &= (@as(u64, 1) << @intCast(u6, backing_bits)) - 1;

                switch (backing_bits) {
                    0 => unreachable,
                    1...32 => try writeInstruction(code, .OpConstant, &[_]Word{
                        result_type_id,
                        result_id,
                        @truncate(u32, int_bits),
                    }),
                    33...64 => try writeInstruction(code, .OpConstant, &[_]Word{
                        result_type_id,
                        result_id,
                        @truncate(u32, int_bits),
                        @truncate(u32, int_bits >> @bitSizeOf(u32)),
                    }),
                    else => unreachable, // backing_bits is bounded by largestSupportedIntBits.
                }
            },
            .Bool => {
                const opcode: Opcode = if (val.toBool()) .OpConstantTrue else .OpConstantFalse;
                try writeInstruction(code, opcode, &[_]Word{ result_type_id, result_id });
            },
            .Float => {
                // At this point we are guaranteed that the target floating point type is supported, otherwise the function
                // would have exited at genType(ty).

                // f16 and f32 require one word of storage. f64 requires 2, low-order first.

                switch (ty.floatBits(target)) {
                    16 => try writeInstruction(code, .OpConstant, &[_]Word{ result_type_id, result_id, @bitCast(u16, val.toFloat(f16)) }),
                    32 => try writeInstruction(code, .OpConstant, &[_]Word{ result_type_id, result_id, @bitCast(u32, val.toFloat(f32)) }),
                    64 => {
                        const float_bits = @bitCast(u64, val.toFloat(f64));
                        try writeInstruction(code, .OpConstant, &[_]Word{
                            result_type_id,
                            result_id,
                            @truncate(u32, float_bits),
                            @truncate(u32, float_bits >> @bitSizeOf(u32)),
                        });
                    },
                    128 => unreachable, // Filtered out in the call to genType.
                    // TODO: Insert case for long double when the layout for that is determined.
                    else => unreachable,
                }
            },
            .Void => unreachable,
            else => return self.fail("TODO: SPIR-V backend: constant generation of type {}", .{ty}),
        }

        return result_id;
    }

    fn genType(self: *DeclGen, ty: Type) Error!ResultId {
        // We can't use getOrPut here so we can recursively generate types.
        if (self.spv.types.get(ty)) |already_generated| {
            return already_generated;
        }

        const target = self.getTarget();
        const code = &self.spv.binary.types_globals_constants;
        const result_id = self.spv.allocResultId();

        switch (ty.zigTypeTag()) {
            .Void => try writeInstruction(code, .OpTypeVoid, &[_]Word{result_id}),
            .Bool => try writeInstruction(code, .OpTypeBool, &[_]Word{result_id}),
            .Int => {
                const int_info = ty.intInfo(target);
                const backing_bits = self.backingIntBits(int_info.bits) orelse {
                    // Integers too big for any native type are represented as "composite integers": An array of largestSupportedIntBits.
                    return self.fail("TODO: SPIR-V backend: implement composite int {}", .{ty});
                };

                // TODO: If backing_bits != int_info.bits, a duplicate type might be generated here.
                try writeInstruction(code, .OpTypeInt, &[_]Word{
                    result_id,
                    backing_bits,
                    switch (int_info.signedness) {
                        .unsigned => 0,
                        .signed => 1,
                    },
                });
            },
            .Float => {
                // We can (and want) not really emulate floating points with other floating point types like with the integer types,
                // so if the float is not supported, just return an error.
                const bits = ty.floatBits(target);
                const supported = switch (bits) {
                    16 => Target.spirv.featureSetHas(target.cpu.features, .Float16),
                    // 32-bit floats are always supported (see spec, 2.16.1, Data rules).
                    32 => true,
                    64 => Target.spirv.featureSetHas(target.cpu.features, .Float64),
                    else => false,
                };

                if (!supported) {
                    return self.fail("Floating point width of {} bits is not supported for the current SPIR-V feature set", .{bits});
                }

                try writeInstruction(code, .OpTypeFloat, &[_]Word{ result_id, bits });
            },
            .Fn => {
                // We only support zig-calling-convention functions, no varargs.
                if (ty.fnCallingConvention() != .Unspecified)
                    return self.fail("Unsupported calling convention for SPIR-V", .{});
                if (ty.fnIsVarArgs())
                    return self.fail("VarArgs unsupported for SPIR-V", .{});

                // In order to avoid a temporary here, first generate all the required types and then simply look them up
                // when generating the function type.
                const params = ty.fnParamLen();
                var i: usize = 0;
                while (i < params) : (i += 1) {
                    _ = try self.genType(ty.fnParamType(i));
                }

                const return_type_id = try self.genType(ty.fnReturnType());

                // result id + result type id + parameter type ids.
                try writeOpcode(code, .OpTypeFunction, 2 + @intCast(u16, ty.fnParamLen()));
                try code.appendSlice(&.{ result_id, return_type_id });

                i = 0;
                while (i < params) : (i += 1) {
                    const param_type_id = self.spv.types.get(ty.fnParamType(i)).?;
                    try code.append(param_type_id);
                }
            },
            // When recursively generating a type, we cannot infer the pointer's storage class. See genPointerType.
            .Pointer => return self.fail("Cannot create pointer with unkown storage class", .{}),
            .Vector => {
                // Although not 100% the same, Zig vectors map quite neatly to SPIR-V vectors (including many integer and float operations
                // which work on them), so simply use those.
                // Note: SPIR-V vectors only support bools, ints and floats, so pointer vectors need to be supported another way.
                // "composite integers" (larger than the largest supported native type) can probably be represented by an array of vectors.
                // TODO: The SPIR-V spec mentions that vector sizes may be quite restricted! look into which we can use, and whether OpTypeVector
                // is adequate at all for this.

                // TODO: Vectors are not yet supported by the self-hosted compiler itself it seems.
                return self.fail("TODO: SPIR-V backend: implement type Vector", .{});
            },
            .Null,
            .Undefined,
            .EnumLiteral,
            .ComptimeFloat,
            .ComptimeInt,
            .Type,
            => unreachable, // Must be const or comptime.

            .BoundFn => unreachable, // this type will be deleted from the language.

            else => |tag| return self.fail("TODO: SPIR-V backend: implement type {}s", .{tag}),
        }

        try self.spv.types.putNoClobber(ty, result_id);
        return result_id;
    }

    /// SPIR-V requires pointers to have a storage class (address space), and so we have a special function for that.
    /// TODO: The result of this needs to be cached.
    fn genPointerType(self: *DeclGen, ty: Type, storage_class: spec.StorageClass) !ResultId {
        assert(ty.zigTypeTag() == .Pointer);

        const code = &self.spv.binary.types_globals_constants;
        const result_id = self.spv.allocResultId();

        // TODO: There are many constraints which are ignored for now: We may only create pointers to certain types, and to other types
        // if more capabilities are enabled. For example, we may only create pointers to f16 if Float16Buffer is enabled.
        // These also relates to the pointer's address space.
        const child_id = try self.genType(ty.elemType());

        try writeInstruction(code, .OpTypePointer, &[_]Word{ result_id, @enumToInt(storage_class), child_id });

        return result_id;
    }

    fn genDecl(self: *DeclGen) !void {
        const decl = self.decl;
        const result_id = decl.fn_link.spirv.id;

        if (decl.val.castTag(.function)) |_| {
            assert(decl.ty.zigTypeTag() == .Fn);
            const prototype_id = try self.genType(decl.ty);
            try writeInstruction(&self.spv.binary.fn_decls, .OpFunction, &[_]Word{
                self.spv.types.get(decl.ty.fnReturnType()).?, // This type should be generated along with the prototype.
                result_id,
                @bitCast(Word, spec.FunctionControl{}), // TODO: We can set inline here if the type requires it.
                prototype_id,
            });

            const params = decl.ty.fnParamLen();
            var i: usize = 0;

            try self.args.ensureCapacity(params);
            while (i < params) : (i += 1) {
                const param_type_id = self.spv.types.get(decl.ty.fnParamType(i)).?;
                const arg_result_id = self.spv.allocResultId();
                try writeInstruction(&self.spv.binary.fn_decls, .OpFunctionParameter, &[_]Word{ param_type_id, arg_result_id });
                self.args.appendAssumeCapacity(arg_result_id);
            }

            // TODO: This could probably be done in a better way...
            const root_block_id = self.spv.allocResultId();

            // We need to generate the label directly in the fn_decls here because we're going to write the local variables after
            // here. Since we're not generating in self.code, we're just going to bypass self.beginSPIRVBlock here.
            try writeInstruction(&self.spv.binary.fn_decls, .OpLabel, &[_]Word{root_block_id});
            self.current_block_label_id = root_block_id;

            const main_body = self.air.getMainBody();
            try self.genBody(main_body);

            // Append the actual code into the fn_decls section.
            try self.spv.binary.fn_decls.appendSlice(self.code.items);
            try writeInstruction(&self.spv.binary.fn_decls, .OpFunctionEnd, &[_]Word{});
        } else {
            return self.fail("TODO: SPIR-V backend: generate decl type {}", .{decl.ty.zigTypeTag()});
        }
    }

    fn genBody(self: *DeclGen, body: []const Air.Inst.Index) Error!void {
        for (body) |inst| {
            try self.genInst(inst);
        }
    }

    fn genInst(self: *DeclGen, inst: Air.Inst.Index) !void {
        const air_tags = self.air.instructions.items(.tag);
        const result_id = switch (air_tags[inst]) {
            // zig fmt: off
            .add, .addwrap => try self.genArithOp(inst, .{.OpFAdd, .OpIAdd, .OpIAdd}),
            .sub, .subwrap => try self.genArithOp(inst, .{.OpFSub, .OpISub, .OpISub}),
            .mul, .mulwrap => try self.genArithOp(inst, .{.OpFMul, .OpIMul, .OpIMul}),
            .div           => try self.genArithOp(inst, .{.OpFDiv, .OpSDiv, .OpUDiv}),

            .bit_and  => try self.genBinOpSimple(inst, .OpBitwiseAnd),
            .bit_or   => try self.genBinOpSimple(inst, .OpBitwiseOr),
            .xor      => try self.genBinOpSimple(inst, .OpBitwiseXor),
            .bool_and => try self.genBinOpSimple(inst, .OpLogicalAnd),
            .bool_or  => try self.genBinOpSimple(inst, .OpLogicalOr),

            .not => try self.genNot(inst),

            .cmp_eq  => try self.genCmp(inst, .{.OpFOrdEqual,            .OpLogicalEqual,      .OpIEqual}),
            .cmp_neq => try self.genCmp(inst, .{.OpFOrdNotEqual,         .OpLogicalNotEqual,   .OpINotEqual}),
            .cmp_gt  => try self.genCmp(inst, .{.OpFOrdGreaterThan,      .OpSGreaterThan,      .OpUGreaterThan}),
            .cmp_gte => try self.genCmp(inst, .{.OpFOrdGreaterThanEqual, .OpSGreaterThanEqual, .OpUGreaterThanEqual}),
            .cmp_lt  => try self.genCmp(inst, .{.OpFOrdLessThan,         .OpSLessThan,         .OpULessThan}),
            .cmp_lte => try self.genCmp(inst, .{.OpFOrdLessThanEqual,    .OpSLessThanEqual,    .OpULessThanEqual}),

            .arg   => self.genArg(),
            .alloc => try self.genAlloc(inst),
            .block => (try self.genBlock(inst)) orelse return,
            .load  => try self.genLoad(inst),

            .br         => return self.genBr(inst),
            .breakpoint => return,
            .cond_br    => return self.genCondBr(inst),
            .constant   => unreachable,
            .dbg_stmt   => return self.genDbgStmt(inst),
            .loop       => return self.genLoop(inst),
            .ret        => return self.genRet(inst),
            .store      => return self.genStore(inst),
            .unreach    => return self.genUnreach(),
            // zig fmt: on

            else => |tag| return self.fail("TODO: SPIR-V backend: implement AIR tag {s}", .{
                @tagName(tag),
            }),
        };

        try self.inst_results.putNoClobber(inst, result_id);
    }

    fn genBinOpSimple(self: *DeclGen, inst: Air.Inst.Index, opcode: Opcode) !ResultId {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs_id = try self.resolve(bin_op.lhs);
        const rhs_id = try self.resolve(bin_op.rhs);
        const result_id = self.spv.allocResultId();
        try writeInstruction(&self.code, opcode, &[_]Word{
            result_type_id, result_id, lhs_id, rhs_id,
        });
        return result_id;
    }

    fn genArithOp(self: *DeclGen, inst: Air.Inst.Index, ops: [3]Opcode) !ResultId {
        // LHS and RHS are guaranteed to have the same type, and AIR guarantees
        // the result to be the same as the LHS and RHS, which matches SPIR-V.
        const ty = self.air.getType(inst);
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs_id = try self.resolve(bin_op.lhs);
        const rhs_id = try self.resolve(bin_op.rhs);

        const result_id = self.spv.allocResultId();
        const result_type_id = try self.genType(ty);

        assert(self.air.getType(bin_op.lhs).eql(ty));
        assert(self.air.getType(bin_op.rhs).eql(ty));

        // Binary operations are generally applicable to both scalar and vector operations
        // in SPIR-V, but int and float versions of operations require different opcodes.
        const info = try self.arithmeticTypeInfo(ty);

        const opcode_index: usize = switch (info.class) {
            .composite_integer => {
                return self.fail("TODO: SPIR-V backend: binary operations for composite integers", .{});
            },
            .strange_integer => {
                return self.fail("TODO: SPIR-V backend: binary operations for strange integers", .{});
            },
            .integer => switch (info.signedness) {
                .signed => 1,
                .unsigned => 2,
            },
            .float => 0,
            else => unreachable,
        };
        const opcode = ops[opcode_index];
        try writeInstruction(&self.code, opcode, &[_]Word{ result_type_id, result_id, lhs_id, rhs_id });

        // TODO: Trap on overflow? Probably going to be annoying.
        // TODO: Look into SPV_KHR_no_integer_wrap_decoration which provides NoSignedWrap/NoUnsignedWrap.

        return result_id;
    }

    fn genCmp(self: *DeclGen, inst: Air.Inst.Index, ops: [3]Opcode) !ResultId {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs_id = try self.resolve(bin_op.lhs);
        const rhs_id = try self.resolve(bin_op.rhs);
        const result_id = self.spv.allocResultId();
        const result_type_id = try self.genType(Type.initTag(.bool));
        const op_ty = self.air.getType(bin_op.lhs);
        assert(op_ty.eql(self.air.getType(bin_op.rhs)));

        // Comparisons are generally applicable to both scalar and vector operations in SPIR-V,
        // but int and float versions of operations require different opcodes.
        const info = try self.arithmeticTypeInfo(op_ty);

        const opcode_index: usize = switch (info.class) {
            .composite_integer => {
                return self.fail("TODO: SPIR-V backend: binary operations for composite integers", .{});
            },
            .strange_integer => {
                return self.fail("TODO: SPIR-V backend: comparison for strange integers", .{});
            },
            .float => 0,
            .bool => 1,
            .integer => switch (info.signedness) {
                .signed => 1,
                .unsigned => 2,
            },
            else => unreachable,
        };
        const opcode = ops[opcode_index];

        try writeInstruction(&self.code, opcode, &[_]Word{ result_type_id, result_id, lhs_id, rhs_id });
        return result_id;
    }

    fn genNot(self: *DeclGen, inst: Air.Inst.Index) !ResultId {
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand_id = try self.resolve(ty_op.operand);
        const result_id = self.spv.allocResultId();
        const result_type_id = try self.genType(Type.initTag(.bool));
        const opcode: Opcode = .OpLogicalNot;
        try writeInstruction(&self.code, opcode, &[_]Word{ result_type_id, result_id, operand_id });
        return result_id;
    }

    fn genAlloc(self: *DeclGen, inst: Air.Inst.Index) !ResultId {
        const ty = self.air.getType(inst);
        const storage_class = spec.StorageClass.Function;
        const result_type_id = try self.genPointerType(ty, storage_class);
        const result_id = self.spv.allocResultId();

        // Rather than generating into code here, we're just going to generate directly into the fn_decls section so that
        // variable declarations appear in the first block of the function.
        try writeInstruction(&self.spv.binary.fn_decls, .OpVariable, &[_]Word{ result_type_id, result_id, @enumToInt(storage_class) });

        return result_id;
    }

    fn genArg(self: *DeclGen) ResultId {
        defer self.next_arg_index += 1;
        return self.args.items[self.next_arg_index];
    }

    fn genBlock(self: *DeclGen, inst: Air.Inst.Index) !?ResultId {
        // In IR, a block doesn't really define an entry point like a block, but more like a scope that breaks can jump out of and
        // "return" a value from. This cannot be directly modelled in SPIR-V, so in a block instruction, we're going to split up
        // the current block by first generating the code of the block, then a label, and then generate the rest of the current
        // ir.Block in a different SPIR-V block.

        const label_id = self.spv.allocResultId();

        // 4 chosen as arbitrary initial capacity.
        var incoming_blocks = try std.ArrayListUnmanaged(IncomingBlock).initCapacity(self.spv.gpa, 4);

        try self.blocks.putNoClobber(inst, .{
            .label_id = label_id,
            .incoming_blocks = &incoming_blocks,
        });
        defer {
            assert(self.blocks.remove(inst));
            incoming_blocks.deinit(self.spv.gpa);
        }

        const ty = self.air.getType(inst);
        const inst_datas = self.air.instructions.items(.data);
        const extra = self.air.extraData(Air.Block, inst_datas[inst].ty_pl.payload);
        const body = self.air.extra[extra.end..][0..extra.data.body_len];

        try self.genBody(body);
        try self.beginSPIRVBlock(label_id);

        // If this block didn't produce a value, simply return here.
        if (!ty.hasCodeGenBits())
            return null;

        // Combine the result from the blocks using the Phi instruction.

        const result_id = self.spv.allocResultId();

        // TODO: OpPhi is limited in the types that it may produce, such as pointers. Figure out which other types
        // are not allowed to be created from a phi node, and throw an error for those. For now, genType already throws
        // an error for pointers.
        const result_type_id = try self.genType(ty);
        _ = result_type_id;

        try writeOpcode(&self.code, .OpPhi, 2 + @intCast(u16, incoming_blocks.items.len * 2)); // result type + result + variable/parent...

        for (incoming_blocks.items) |incoming| {
            try self.code.appendSlice(&[_]Word{ incoming.break_value_id, incoming.src_label_id });
        }

        return result_id;
    }

    fn genBr(self: *DeclGen, inst: Air.Inst.Index) !void {
        const br = self.air.instructions.items(.data)[inst].br;
        const block = self.blocks.get(br.block_inst).?;
        const operand_ty = self.air.getType(br.operand);

        if (operand_ty.hasCodeGenBits()) {
            const operand_id = try self.resolve(br.operand);
            // current_block_label_id should not be undefined here, lest there is a br or br_void in the function's body.
            try block.incoming_blocks.append(self.spv.gpa, .{ .src_label_id = self.current_block_label_id, .break_value_id = operand_id });
        }

        try writeInstruction(&self.code, .OpBranch, &[_]Word{block.label_id});
    }

    fn genCondBr(self: *DeclGen, inst: *Inst.CondBr) !void {
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const cond_br = self.air.extraData(Air.CondBr, pl_op.payload);
        const then_body = self.air.extra[cond_br.end..][0..cond_br.data.then_body_len];
        const else_body = self.air.extra[cond_br.end + then_body.len ..][0..cond_br.data.else_body_len];
        const condition_id = try self.resolve(pl_op.operand);

        // These will always generate a new SPIR-V block, since they are ir.Body and not ir.Block.
        const then_label_id = self.spv.allocResultId();
        const else_label_id = self.spv.allocResultId();

        // TODO: We can generate OpSelectionMerge here if we know the target block that both of these will resolve to,
        // but i don't know if those will always resolve to the same block.

        try writeInstruction(&self.code, .OpBranchConditional, &[_]Word{
            condition_id,
            then_label_id,
            else_label_id,
        });

        try self.beginSPIRVBlock(then_label_id);
        try self.genBody(then_body);
        try self.beginSPIRVBlock(else_label_id);
        try self.genBody(else_body);
    }

    fn genDbgStmt(self: *DeclGen, inst: Air.Inst.Index) !void {
        const dbg_stmt = self.air.instructions.items(.data)[inst].dbg_stmt;
        const src_fname_id = try self.spv.resolveSourceFileName(self.decl);
        try writeInstruction(&self.code, .OpLine, &[_]Word{ src_fname_id, dbg_stmt.line, dbg_stmt.column });
    }

    fn genLoad(self: *DeclGen, inst: Air.Inst.Index) !ResultId {
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand_id = try self.resolve(ty_op.operand);
        const ty = self.air.getType(inst);

        const result_type_id = try self.genType(ty);
        const result_id = self.spv.allocResultId();

        const operands = if (ty.isVolatilePtr())
            &[_]Word{ result_type_id, result_id, operand_id, @bitCast(u32, spec.MemoryAccess{ .Volatile = true }) }
        else
            &[_]Word{ result_type_id, result_id, operand_id };

        try writeInstruction(&self.code, .OpLoad, operands);

        return result_id;
    }

    fn genLoop(self: *DeclGen, inst: Air.Inst.Index) !void {
        const loop = self.air.extraData(Air.Block, inst_datas[inst].ty_pl.payload);
        const body = self.air.extra[loop.end..][0..loop.data.body_len];
        const loop_label_id = self.spv.allocResultId();

        // Jump to the loop entry point
        try writeInstruction(&self.code, .OpBranch, &[_]Word{loop_label_id});

        // TODO: Look into OpLoopMerge.

        try self.beginSPIRVBlock(loop_label_id);
        try self.genBody(body);

        try writeInstruction(&self.code, .OpBranch, &[_]Word{loop_label_id});
    }

    fn genRet(self: *DeclGen, inst: Air.Inst.Index) !void {
        const operand = inst_datas[inst].un_op;
        const operand_ty = self.air.getType(operand);
        if (operand_ty.hasCodeGenBits()) {
            const operand_id = try self.resolve(operand);
            try writeInstruction(&self.code, .OpReturnValue, &[_]Word{operand_id});
        } else {
            try writeInstruction(&self.code, .OpReturn, &[_]Word{});
        }
    }

    fn genStore(self: *DeclGen, inst: Air.Inst.Index) !void {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const dst_ptr_id = try self.resolve(bin_op.lhs);
        const src_val_id = try self.resolve(bin_op.rhs);
        const lhs_ty = self.air.getType(bin_op.lhs);

        const operands = if (lhs_ty.isVolatilePtr())
            &[_]Word{ dst_ptr_id, src_val_id, @bitCast(u32, spec.MemoryAccess{ .Volatile = true }) }
        else
            &[_]Word{ dst_ptr_id, src_val_id };

        try writeInstruction(&self.code, .OpStore, operands);
    }

    fn genUnreach(self: *DeclGen) !void {
        try writeInstruction(&self.code, .OpUnreachable, &[_]Word{});
    }
};
