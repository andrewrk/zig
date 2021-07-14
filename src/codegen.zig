const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const Air = @import("Air.zig");
const Liveness = @import("Liveness.zig");
const Type = @import("type.zig").Type;
const Value = @import("value.zig").Value;
const TypedValue = @import("TypedValue.zig");
const link = @import("link.zig");
const Module = @import("Module.zig");
const Compilation = @import("Compilation.zig");
const ErrorMsg = Module.ErrorMsg;
const Target = std.Target;
const Allocator = mem.Allocator;
const trace = @import("tracy.zig").trace;
const DW = std.dwarf;
const leb128 = std.leb;
const log = std.log.scoped(.codegen);
const build_options = @import("build_options");
const LazySrcLoc = Module.LazySrcLoc;
const RegisterManager = @import("register_manager.zig").RegisterManager;

const X8664Encoder = @import("codegen/x86_64.zig").Encoder;

pub const FnResult = union(enum) {
    /// The `code` parameter passed to `generateSymbol` has the value appended.
    appended: void,
    fail: *ErrorMsg,
};
pub const Result = union(enum) {
    /// The `code` parameter passed to `generateSymbol` has the value appended.
    appended: void,
    /// The value is available externally, `code` is unused.
    externally_managed: []const u8,
    fail: *ErrorMsg,
};

pub const GenerateSymbolError = error{
    OutOfMemory,
    /// A Decl that this symbol depends on had a semantic analysis failure.
    AnalysisFail,
};

pub const DebugInfoOutput = union(enum) {
    dwarf: struct {
        dbg_line: *std.ArrayList(u8),
        dbg_info: *std.ArrayList(u8),
        dbg_info_type_relocs: *link.File.DbgInfoTypeRelocsTable,
    },
    none,
};

pub fn generateFunction(
    bin_file: *link.File,
    src_loc: Module.SrcLoc,
    func: *Module.Fn,
    air: Air,
    liveness: Liveness,
    code: *std.ArrayList(u8),
    debug_output: DebugInfoOutput,
) GenerateSymbolError!FnResult {
    switch (bin_file.options.target.cpu.arch) {
        .wasm32 => unreachable, // has its own code path
        .wasm64 => unreachable, // has its own code path
        .arm => return Function(.arm).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        .armeb => return Function(.armeb).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        .aarch64 => return Function(.aarch64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        .aarch64_be => return Function(.aarch64_be).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        .aarch64_32 => return Function(.aarch64_32).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.arc => return Function(.arc).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.avr => return Function(.avr).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.bpfel => return Function(.bpfel).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.bpfeb => return Function(.bpfeb).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.hexagon => return Function(.hexagon).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.mips => return Function(.mips).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.mipsel => return Function(.mipsel).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.mips64 => return Function(.mips64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.mips64el => return Function(.mips64el).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.msp430 => return Function(.msp430).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.powerpc => return Function(.powerpc).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.powerpc64 => return Function(.powerpc64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.powerpc64le => return Function(.powerpc64le).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.r600 => return Function(.r600).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.amdgcn => return Function(.amdgcn).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.riscv32 => return Function(.riscv32).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        .riscv64 => return Function(.riscv64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.sparc => return Function(.sparc).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.sparcv9 => return Function(.sparcv9).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.sparcel => return Function(.sparcel).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.s390x => return Function(.s390x).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.tce => return Function(.tce).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.tcele => return Function(.tcele).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.thumb => return Function(.thumb).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.thumbeb => return Function(.thumbeb).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.i386 => return Function(.i386).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        .x86_64 => return Function(.x86_64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.xcore => return Function(.xcore).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.nvptx => return Function(.nvptx).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.nvptx64 => return Function(.nvptx64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.le32 => return Function(.le32).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.le64 => return Function(.le64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.amdil => return Function(.amdil).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.amdil64 => return Function(.amdil64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.hsail => return Function(.hsail).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.hsail64 => return Function(.hsail64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.spir => return Function(.spir).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.spir64 => return Function(.spir64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.kalimba => return Function(.kalimba).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.shave => return Function(.shave).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.lanai => return Function(.lanai).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.renderscript32 => return Function(.renderscript32).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.renderscript64 => return Function(.renderscript64).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        //.ve => return Function(.ve).generate(bin_file, src_loc, func, air, liveness, code, debug_output),
        else => @panic("Backend architectures that don't have good support yet are commented out, to improve compilation performance. If you are interested in one of these other backends feel free to uncomment them. Eventually these will be completed, but stage1 is slow and a memory hog."),
    }
}

pub fn generateSymbol(
    bin_file: *link.File,
    src_loc: Module.SrcLoc,
    typed_value: TypedValue,
    code: *std.ArrayList(u8),
    debug_output: DebugInfoOutput,
) GenerateSymbolError!Result {
    const tracy = trace(@src());
    defer tracy.end();

    switch (typed_value.ty.zigTypeTag()) {
        .Fn => {
            return Result{
                .fail = try ErrorMsg.create(
                    bin_file.allocator,
                    src_loc,
                    "TODO implement generateSymbol function pointers",
                    .{},
                ),
            };
        },
        .Array => {
            // TODO populate .debug_info for the array
            if (typed_value.val.castTag(.bytes)) |payload| {
                if (typed_value.ty.sentinel()) |sentinel| {
                    try code.ensureCapacity(code.items.len + payload.data.len + 1);
                    code.appendSliceAssumeCapacity(payload.data);
                    switch (try generateSymbol(bin_file, src_loc, .{
                        .ty = typed_value.ty.elemType(),
                        .val = sentinel,
                    }, code, debug_output)) {
                        .appended => return Result{ .appended = {} },
                        .externally_managed => |slice| {
                            code.appendSliceAssumeCapacity(slice);
                            return Result{ .appended = {} };
                        },
                        .fail => |em| return Result{ .fail = em },
                    }
                } else {
                    return Result{ .externally_managed = payload.data };
                }
            }
            return Result{
                .fail = try ErrorMsg.create(
                    bin_file.allocator,
                    src_loc,
                    "TODO implement generateSymbol for more kinds of arrays",
                    .{},
                ),
            };
        },
        .Pointer => switch (typed_value.ty.ptrSize()) {
            .Slice => {
                return Result{
                    .fail = try ErrorMsg.create(
                        bin_file.allocator,
                        src_loc,
                        "TODO implement generateSymbol for slice {}",
                        .{typed_value.val},
                    ),
                };
            },
            else => {
                // TODO populate .debug_info for the pointer
                if (typed_value.val.castTag(.decl_ref)) |payload| {
                    const decl = payload.data;
                    if (decl.analysis != .complete) return error.AnalysisFail;
                    // TODO handle the dependency of this symbol on the decl's vaddr.
                    // If the decl changes vaddr, then this symbol needs to get regenerated.
                    const vaddr = bin_file.getDeclVAddr(decl);
                    const endian = bin_file.options.target.cpu.arch.endian();
                    switch (bin_file.options.target.cpu.arch.ptrBitWidth()) {
                        16 => {
                            try code.resize(2);
                            mem.writeInt(u16, code.items[0..2], @intCast(u16, vaddr), endian);
                        },
                        32 => {
                            try code.resize(4);
                            mem.writeInt(u32, code.items[0..4], @intCast(u32, vaddr), endian);
                        },
                        64 => {
                            try code.resize(8);
                            mem.writeInt(u64, code.items[0..8], vaddr, endian);
                        },
                        else => unreachable,
                    }
                    return Result{ .appended = {} };
                }
                return Result{
                    .fail = try ErrorMsg.create(
                        bin_file.allocator,
                        src_loc,
                        "TODO implement generateSymbol for pointer {}",
                        .{typed_value.val},
                    ),
                };
            },
        },
        .Int => {
            // TODO populate .debug_info for the integer
            const endian = bin_file.options.target.cpu.arch.endian();
            const info = typed_value.ty.intInfo(bin_file.options.target);
            if (info.bits <= 8) {
                const x = @intCast(u8, typed_value.val.toUnsignedInt());
                try code.append(x);
                return Result{ .appended = {} };
            }
            if (info.bits > 64) {
                return Result{
                    .fail = try ErrorMsg.create(
                        bin_file.allocator,
                        src_loc,
                        "TODO implement generateSymbol for big ints ('{}')",
                        .{typed_value.ty},
                    ),
                };
            }
            switch (info.signedness) {
                .unsigned => {
                    if (info.bits <= 16) {
                        const x = @intCast(u16, typed_value.val.toUnsignedInt());
                        mem.writeInt(u16, try code.addManyAsArray(2), x, endian);
                    } else if (info.bits <= 32) {
                        const x = @intCast(u32, typed_value.val.toUnsignedInt());
                        mem.writeInt(u32, try code.addManyAsArray(4), x, endian);
                    } else {
                        const x = typed_value.val.toUnsignedInt();
                        mem.writeInt(u64, try code.addManyAsArray(8), x, endian);
                    }
                },
                .signed => {
                    if (info.bits <= 16) {
                        const x = @intCast(i16, typed_value.val.toSignedInt());
                        mem.writeInt(i16, try code.addManyAsArray(2), x, endian);
                    } else if (info.bits <= 32) {
                        const x = @intCast(i32, typed_value.val.toSignedInt());
                        mem.writeInt(i32, try code.addManyAsArray(4), x, endian);
                    } else {
                        const x = typed_value.val.toSignedInt();
                        mem.writeInt(i64, try code.addManyAsArray(8), x, endian);
                    }
                },
            }
            return Result{ .appended = {} };
        },
        else => |t| {
            return Result{
                .fail = try ErrorMsg.create(
                    bin_file.allocator,
                    src_loc,
                    "TODO implement generateSymbol for type '{s}'",
                    .{@tagName(t)},
                ),
            };
        },
    }
}

const InnerError = error{
    OutOfMemory,
    CodegenFail,
};

fn Function(comptime arch: std.Target.Cpu.Arch) type {
    const writeInt = switch (arch.endian()) {
        .Little => mem.writeIntLittle,
        .Big => mem.writeIntBig,
    };

    return struct {
        gpa: *Allocator,
        air: Air,
        liveness: Liveness,
        bin_file: *link.File,
        target: *const std.Target,
        mod_fn: *const Module.Fn,
        code: *std.ArrayList(u8),
        debug_output: DebugInfoOutput,
        err_msg: ?*ErrorMsg,
        args: []MCValue,
        ret_mcv: MCValue,
        fn_type: Type,
        arg_index: usize,
        src_loc: Module.SrcLoc,
        stack_align: u32,

        prev_di_line: u32,
        prev_di_column: u32,
        /// Byte offset within the source file of the ending curly.
        end_di_line: u32,
        end_di_column: u32,
        /// Relative to the beginning of `code`.
        prev_di_pc: usize,

        /// The value is an offset into the `Function` `code` from the beginning.
        /// To perform the reloc, write 32-bit signed little-endian integer
        /// which is a relative jump, based on the address following the reloc.
        exitlude_jump_relocs: std.ArrayListUnmanaged(usize) = .{},

        /// Whenever there is a runtime branch, we push a Branch onto this stack,
        /// and pop it off when the runtime branch joins. This provides an "overlay"
        /// of the table of mappings from instructions to `MCValue` from within the branch.
        /// This way we can modify the `MCValue` for an instruction in different ways
        /// within different branches. Special consideration is needed when a branch
        /// joins with its parent, to make sure all instructions have the same MCValue
        /// across each runtime branch upon joining.
        branch_stack: *std.ArrayList(Branch),

        // Key is the block instruction
        blocks: std.AutoHashMapUnmanaged(Air.Inst.Index, BlockData) = .{},

        register_manager: RegisterManager(Self, Register, &callee_preserved_regs) = .{},
        /// Maps offset to what is stored there.
        stack: std.AutoHashMapUnmanaged(u32, StackAllocation) = .{},

        /// Offset from the stack base, representing the end of the stack frame.
        max_end_stack: u32 = 0,
        /// Represents the current end stack offset. If there is no existing slot
        /// to place a new stack allocation, it goes here, and then bumps `max_end_stack`.
        next_stack_offset: u32 = 0,

        const MCValue = union(enum) {
            /// No runtime bits. `void` types, empty structs, u0, enums with 1 tag, etc.
            /// TODO Look into deleting this tag and using `dead` instead, since every use
            /// of MCValue.none should be instead looking at the type and noticing it is 0 bits.
            none,
            /// Control flow will not allow this value to be observed.
            unreach,
            /// No more references to this value remain.
            dead,
            /// The value is undefined.
            undef,
            /// A pointer-sized integer that fits in a register.
            /// If the type is a pointer, this is the pointer address in virtual address space.
            immediate: u64,
            /// The constant was emitted into the code, at this offset.
            /// If the type is a pointer, it means the pointer address is embedded in the code.
            embedded_in_code: usize,
            /// The value is a pointer to a constant which was emitted into the code, at this offset.
            ptr_embedded_in_code: usize,
            /// The value is in a target-specific register.
            register: Register,
            /// The value is in memory at a hard-coded address.
            /// If the type is a pointer, it means the pointer address is at this memory location.
            memory: u64,
            /// The value is one of the stack variables.
            /// If the type is a pointer, it means the pointer address is in the stack at this offset.
            stack_offset: u32,
            /// The value is a pointer to one of the stack variables (payload is stack offset).
            ptr_stack_offset: u32,
            /// The value is in the compare flags assuming an unsigned operation,
            /// with this operator applied on top of it.
            compare_flags_unsigned: math.CompareOperator,
            /// The value is in the compare flags assuming a signed operation,
            /// with this operator applied on top of it.
            compare_flags_signed: math.CompareOperator,

            fn isMemory(mcv: MCValue) bool {
                return switch (mcv) {
                    .embedded_in_code, .memory, .stack_offset => true,
                    else => false,
                };
            }

            fn isImmediate(mcv: MCValue) bool {
                return switch (mcv) {
                    .immediate => true,
                    else => false,
                };
            }

            fn isMutable(mcv: MCValue) bool {
                return switch (mcv) {
                    .none => unreachable,
                    .unreach => unreachable,
                    .dead => unreachable,

                    .immediate,
                    .embedded_in_code,
                    .memory,
                    .compare_flags_unsigned,
                    .compare_flags_signed,
                    .ptr_stack_offset,
                    .ptr_embedded_in_code,
                    .undef,
                    => false,

                    .register,
                    .stack_offset,
                    => true,
                };
            }
        };

        const Branch = struct {
            inst_table: std.AutoArrayHashMapUnmanaged(Air.Inst.Index, MCValue) = .{},

            fn deinit(self: *Branch, gpa: *Allocator) void {
                self.inst_table.deinit(gpa);
                self.* = undefined;
            }
        };

        const StackAllocation = struct {
            inst: Air.Inst.Index,
            /// TODO do we need size? should be determined by inst.ty.abiSize()
            size: u32,
        };

        const BlockData = struct {
            relocs: std.ArrayListUnmanaged(Reloc),
            /// The first break instruction encounters `null` here and chooses a
            /// machine code value for the block result, populating this field.
            /// Following break instructions encounter that value and use it for
            /// the location to store their block results.
            mcv: MCValue,
        };

        const Reloc = union(enum) {
            /// The value is an offset into the `Function` `code` from the beginning.
            /// To perform the reloc, write 32-bit signed little-endian integer
            /// which is a relative jump, based on the address following the reloc.
            rel32: usize,
            /// A branch in the ARM instruction set
            arm_branch: struct {
                pos: usize,
                cond: @import("codegen/arm.zig").Condition,
            },
        };

        const Self = @This();

        fn generate(
            bin_file: *link.File,
            src_loc: Module.SrcLoc,
            module_fn: *Module.Fn,
            air: Air,
            liveness: Liveness,
            code: *std.ArrayList(u8),
            debug_output: DebugInfoOutput,
        ) GenerateSymbolError!FnResult {
            if (build_options.skip_non_native and std.Target.current.cpu.arch != arch) {
                @panic("Attempted to compile for architecture that was disabled by build configuration");
            }

            assert(module_fn.owner_decl.has_tv);
            const fn_type = module_fn.owner_decl.ty;

            var branch_stack = std.ArrayList(Branch).init(bin_file.allocator);
            defer {
                assert(branch_stack.items.len == 1);
                branch_stack.items[0].deinit(bin_file.allocator);
                branch_stack.deinit();
            }
            try branch_stack.append(.{});

            var function = Self{
                .gpa = bin_file.allocator,
                .air = air,
                .liveness = liveness,
                .target = &bin_file.options.target,
                .bin_file = bin_file,
                .mod_fn = module_fn,
                .code = code,
                .debug_output = debug_output,
                .err_msg = null,
                .args = undefined, // populated after `resolveCallingConventionValues`
                .ret_mcv = undefined, // populated after `resolveCallingConventionValues`
                .fn_type = fn_type,
                .arg_index = 0,
                .branch_stack = &branch_stack,
                .src_loc = src_loc,
                .stack_align = undefined,
                .prev_di_pc = 0,
                .prev_di_line = module_fn.lbrace_line,
                .prev_di_column = module_fn.lbrace_column,
                .end_di_line = module_fn.rbrace_line,
                .end_di_column = module_fn.rbrace_column,
            };
            defer function.stack.deinit(bin_file.allocator);
            defer function.blocks.deinit(bin_file.allocator);
            defer function.exitlude_jump_relocs.deinit(bin_file.allocator);

            var call_info = function.resolveCallingConventionValues(fn_type) catch |err| switch (err) {
                error.CodegenFail => return FnResult{ .fail = function.err_msg.? },
                else => |e| return e,
            };
            defer call_info.deinit(&function);

            function.args = call_info.args;
            function.ret_mcv = call_info.return_value;
            function.stack_align = call_info.stack_align;
            function.max_end_stack = call_info.stack_byte_count;

            function.gen() catch |err| switch (err) {
                error.CodegenFail => return FnResult{ .fail = function.err_msg.? },
                else => |e| return e,
            };

            if (function.err_msg) |em| {
                return FnResult{ .fail = em };
            } else {
                return FnResult{ .appended = {} };
            }
        }

        fn gen(self: *Self) !void {
            switch (arch) {
                .x86_64 => {
                    try self.code.ensureCapacity(self.code.items.len + 11);

                    const cc = self.fn_type.fnCallingConvention();
                    if (cc != .Naked) {
                        // We want to subtract the aligned stack frame size from rsp here, but we don't
                        // yet know how big it will be, so we leave room for a 4-byte stack size.
                        // TODO During semantic analysis, check if there are no function calls. If there
                        // are none, here we can omit the part where we subtract and then add rsp.
                        self.code.appendSliceAssumeCapacity(&[_]u8{
                            0x55, // push rbp
                            0x48, 0x89, 0xe5, // mov rbp, rsp
                            0x48, 0x81, 0xec, // sub rsp, imm32 (with reloc)
                        });
                        const reloc_index = self.code.items.len;
                        self.code.items.len += 4;

                        try self.dbgSetPrologueEnd();
                        try self.genBody(self.air.getMainBody());

                        const stack_end = self.max_end_stack;
                        if (stack_end > math.maxInt(i32))
                            return self.failSymbol("too much stack used in call parameters", .{});
                        const aligned_stack_end = mem.alignForward(stack_end, self.stack_align);
                        mem.writeIntLittle(u32, self.code.items[reloc_index..][0..4], @intCast(u32, aligned_stack_end));

                        if (self.code.items.len >= math.maxInt(i32)) {
                            return self.failSymbol("unable to perform relocation: jump too far", .{});
                        }
                        if (self.exitlude_jump_relocs.items.len == 1) {
                            self.code.items.len -= 5;
                        } else for (self.exitlude_jump_relocs.items) |jmp_reloc| {
                            const amt = self.code.items.len - (jmp_reloc + 4);
                            const s32_amt = @intCast(i32, amt);
                            mem.writeIntLittle(i32, self.code.items[jmp_reloc..][0..4], s32_amt);
                        }

                        // Important to be after the possible self.code.items.len -= 5 above.
                        try self.dbgSetEpilogueBegin();

                        try self.code.ensureCapacity(self.code.items.len + 9);
                        // add rsp, x
                        if (aligned_stack_end > math.maxInt(i8)) {
                            // example: 48 81 c4 ff ff ff 7f  add    rsp,0x7fffffff
                            self.code.appendSliceAssumeCapacity(&[_]u8{ 0x48, 0x81, 0xc4 });
                            const x = @intCast(u32, aligned_stack_end);
                            mem.writeIntLittle(u32, self.code.addManyAsArrayAssumeCapacity(4), x);
                        } else if (aligned_stack_end != 0) {
                            // example: 48 83 c4 7f           add    rsp,0x7f
                            const x = @intCast(u8, aligned_stack_end);
                            self.code.appendSliceAssumeCapacity(&[_]u8{ 0x48, 0x83, 0xc4, x });
                        }

                        self.code.appendSliceAssumeCapacity(&[_]u8{
                            0x5d, // pop rbp
                            0xc3, // ret
                        });
                    } else {
                        try self.dbgSetPrologueEnd();
                        try self.genBody(self.air.getMainBody());
                        try self.dbgSetEpilogueBegin();
                    }
                },
                .arm, .armeb => {
                    const cc = self.fn_type.fnCallingConvention();
                    if (cc != .Naked) {
                        // push {fp, lr}
                        // mov fp, sp
                        // sub sp, sp, #reloc
                        const prologue_reloc = self.code.items.len;
                        try self.code.resize(prologue_reloc + 12);
                        writeInt(u32, self.code.items[prologue_reloc + 4 ..][0..4], Instruction.mov(.al, .fp, Instruction.Operand.reg(.sp, Instruction.Operand.Shift.none)).toU32());

                        try self.dbgSetPrologueEnd();

                        try self.genBody(self.mod_fn.body);

                        // Backpatch push callee saved regs
                        var saved_regs = Instruction.RegisterList{
                            .r11 = true, // fp
                            .r14 = true, // lr
                        };
                        inline for (callee_preserved_regs) |reg| {
                            if (self.register_manager.isRegAllocated(reg)) {
                                @field(saved_regs, @tagName(reg)) = true;
                            }
                        }
                        writeInt(u32, self.code.items[prologue_reloc..][0..4], Instruction.stmdb(.al, .sp, true, saved_regs).toU32());

                        // Backpatch stack offset
                        const stack_end = self.max_end_stack;
                        const aligned_stack_end = mem.alignForward(stack_end, self.stack_align);
                        if (Instruction.Operand.fromU32(@intCast(u32, aligned_stack_end))) |op| {
                            writeInt(u32, self.code.items[prologue_reloc + 8 ..][0..4], Instruction.sub(.al, .sp, .sp, op).toU32());
                        } else {
                            return self.failSymbol("TODO ARM: allow larger stacks", .{});
                        }

                        try self.dbgSetEpilogueBegin();

                        // exitlude jumps
                        if (self.exitlude_jump_relocs.items.len == 1) {
                            // There is only one relocation. Hence,
                            // this relocation must be at the end of
                            // the code. Therefore, we can just delete
                            // the space initially reserved for the
                            // jump
                            self.code.items.len -= 4;
                        } else for (self.exitlude_jump_relocs.items) |jmp_reloc| {
                            const amt = @intCast(i32, self.code.items.len) - @intCast(i32, jmp_reloc + 8);
                            if (amt == -4) {
                                // This return is at the end of the
                                // code block. We can't just delete
                                // the space because there may be
                                // other jumps we already relocated to
                                // the address. Instead, insert a nop
                                writeInt(u32, self.code.items[jmp_reloc..][0..4], Instruction.nop().toU32());
                            } else {
                                if (math.cast(i26, amt)) |offset| {
                                    writeInt(u32, self.code.items[jmp_reloc..][0..4], Instruction.b(.al, offset).toU32());
                                } else |_| {
                                    return self.failSymbol("exitlude jump is too large", .{});
                                }
                            }
                        }

                        // Epilogue: pop callee saved registers (swap lr with pc in saved_regs)
                        saved_regs.r14 = false; // lr
                        saved_regs.r15 = true; // pc

                        // mov sp, fp
                        // pop {fp, pc}
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.mov(.al, .sp, Instruction.Operand.reg(.fp, Instruction.Operand.Shift.none)).toU32());
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.ldm(.al, .sp, true, saved_regs).toU32());
                    } else {
                        try self.dbgSetPrologueEnd();
                        try self.genBody(self.mod_fn.body);
                        try self.dbgSetEpilogueBegin();
                    }
                },
                .aarch64, .aarch64_be, .aarch64_32 => {
                    const cc = self.fn_type.fnCallingConvention();
                    if (cc != .Naked) {
                        // TODO Finish function prologue and epilogue for aarch64.

                        // stp fp, lr, [sp, #-16]!
                        // mov fp, sp
                        // sub sp, sp, #reloc
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.stp(
                            .x29,
                            .x30,
                            Register.sp,
                            Instruction.LoadStorePairOffset.pre_index(-16),
                        ).toU32());
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.add(.x29, .xzr, 0, false).toU32());
                        const backpatch_reloc = self.code.items.len;
                        try self.code.resize(backpatch_reloc + 4);

                        try self.dbgSetPrologueEnd();

                        try self.genBody(self.mod_fn.body);

                        // Backpatch stack offset
                        const stack_end = self.max_end_stack;
                        const aligned_stack_end = mem.alignForward(stack_end, self.stack_align);
                        if (math.cast(u12, aligned_stack_end)) |size| {
                            writeInt(u32, self.code.items[backpatch_reloc..][0..4], Instruction.sub(.xzr, .xzr, size, false).toU32());
                        } else |_| {
                            return self.failSymbol("TODO AArch64: allow larger stacks", .{});
                        }

                        try self.dbgSetEpilogueBegin();

                        // exitlude jumps
                        if (self.exitlude_jump_relocs.items.len == 1) {
                            // There is only one relocation. Hence,
                            // this relocation must be at the end of
                            // the code. Therefore, we can just delete
                            // the space initially reserved for the
                            // jump
                            self.code.items.len -= 4;
                        } else for (self.exitlude_jump_relocs.items) |jmp_reloc| {
                            const amt = @intCast(i32, self.code.items.len) - @intCast(i32, jmp_reloc + 8);
                            if (amt == -4) {
                                // This return is at the end of the
                                // code block. We can't just delete
                                // the space because there may be
                                // other jumps we already relocated to
                                // the address. Instead, insert a nop
                                writeInt(u32, self.code.items[jmp_reloc..][0..4], Instruction.nop().toU32());
                            } else {
                                if (math.cast(i28, amt)) |offset| {
                                    writeInt(u32, self.code.items[jmp_reloc..][0..4], Instruction.b(offset).toU32());
                                } else |_| {
                                    return self.failSymbol("exitlude jump is too large", .{});
                                }
                            }
                        }

                        // ldp fp, lr, [sp], #16
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.ldp(
                            .x29,
                            .x30,
                            Register.sp,
                            Instruction.LoadStorePairOffset.post_index(16),
                        ).toU32());
                        // add sp, sp, #stack_size
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.add(.xzr, .xzr, @intCast(u12, aligned_stack_end), false).toU32());
                        // ret lr
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.ret(null).toU32());
                    } else {
                        try self.dbgSetPrologueEnd();
                        try self.genBody(self.mod_fn.body);
                        try self.dbgSetEpilogueBegin();
                    }
                },
                else => {
                    try self.dbgSetPrologueEnd();
                    try self.genBody(self.mod_fn.body);
                    try self.dbgSetEpilogueBegin();
                },
            }
            // Drop them off at the rbrace.
            try self.dbgAdvancePCAndLine(self.end_di_line, self.end_di_column);
        }

        fn genBody(self: *Self, body: []const Air.Inst.Index) InnerError!void {
            for (body) |inst| {
                const tomb_bits = self.liveness.getTombBits(inst);
                try self.ensureProcessDeathCapacity(@popCount(@TypeOf(tomb_bits), tomb_bits));

                const mcv = try self.genFuncInst(inst);
                if (!self.liveness.isUnused(inst)) {
                    log.debug("{} => {}", .{ inst, mcv });
                    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
                    try branch.inst_table.putNoClobber(self.gpa, inst, mcv);
                }

                // TODO inline this logic into every instruction
                @panic("TODO rework AIR memory layout codegen for processing deaths");
                //var i: ir.Inst.DeathsBitIndex = 0;
                //while (inst.getOperand(i)) |operand| : (i += 1) {
                //    if (inst.operandDies(i))
                //        self.processDeath(operand);
                //}
            }
        }

        fn dbgSetPrologueEnd(self: *Self) InnerError!void {
            switch (self.debug_output) {
                .dwarf => |dbg_out| {
                    try dbg_out.dbg_line.append(DW.LNS_set_prologue_end);
                    try self.dbgAdvancePCAndLine(self.prev_di_line, self.prev_di_column);
                },
                .none => {},
            }
        }

        fn dbgSetEpilogueBegin(self: *Self) InnerError!void {
            switch (self.debug_output) {
                .dwarf => |dbg_out| {
                    try dbg_out.dbg_line.append(DW.LNS_set_epilogue_begin);
                    try self.dbgAdvancePCAndLine(self.prev_di_line, self.prev_di_column);
                },
                .none => {},
            }
        }

        fn dbgAdvancePCAndLine(self: *Self, line: u32, column: u32) InnerError!void {
            switch (self.debug_output) {
                .dwarf => |dbg_out| {
                    const delta_line = @intCast(i32, line) - @intCast(i32, self.prev_di_line);
                    const delta_pc = self.code.items.len - self.prev_di_pc;
                    // TODO Look into using the DWARF special opcodes to compress this data.
                    // It lets you emit single-byte opcodes that add different numbers to
                    // both the PC and the line number at the same time.
                    try dbg_out.dbg_line.ensureUnusedCapacity(11);
                    dbg_out.dbg_line.appendAssumeCapacity(DW.LNS_advance_pc);
                    leb128.writeULEB128(dbg_out.dbg_line.writer(), delta_pc) catch unreachable;
                    if (delta_line != 0) {
                        dbg_out.dbg_line.appendAssumeCapacity(DW.LNS_advance_line);
                        leb128.writeILEB128(dbg_out.dbg_line.writer(), delta_line) catch unreachable;
                    }
                    dbg_out.dbg_line.appendAssumeCapacity(DW.LNS_copy);
                },
                .none => {},
            }
            self.prev_di_line = line;
            self.prev_di_column = column;
            self.prev_di_pc = self.code.items.len;
        }

        /// Asserts there is already capacity to insert into top branch inst_table.
        fn processDeath(self: *Self, inst: Air.Inst.Index) void {
            const air_tags = self.air.instructions.items(.tag);
            if (air_tags[inst] == .constant) return; // Constants are immortal.
            // When editing this function, note that the logic must synchronize with `reuseOperand`.
            const prev_value = self.getResolvedInstValue(inst);
            const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
            branch.inst_table.putAssumeCapacity(inst, .dead);
            switch (prev_value) {
                .register => |reg| {
                    const canon_reg = toCanonicalReg(reg);
                    self.register_manager.freeReg(canon_reg);
                },
                else => {}, // TODO process stack allocation death
            }
        }

        fn ensureProcessDeathCapacity(self: *Self, additional_count: usize) !void {
            const table = &self.branch_stack.items[self.branch_stack.items.len - 1].inst_table;
            try table.ensureCapacity(self.gpa, table.count() + additional_count);
        }

        /// Adds a Type to the .debug_info at the current position. The bytes will be populated later,
        /// after codegen for this symbol is done.
        fn addDbgInfoTypeReloc(self: *Self, ty: Type) !void {
            switch (self.debug_output) {
                .dwarf => |dbg_out| {
                    assert(ty.hasCodeGenBits());
                    const index = dbg_out.dbg_info.items.len;
                    try dbg_out.dbg_info.resize(index + 4); // DW.AT_type,  DW.FORM_ref4

                    const gop = try dbg_out.dbg_info_type_relocs.getOrPut(self.gpa, ty);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{
                            .off = undefined,
                            .relocs = .{},
                        };
                    }
                    try gop.value_ptr.relocs.append(self.gpa, @intCast(u32, index));
                },
                .none => {},
            }
        }

        fn genFuncInst(self: *Self, inst: Air.Inst.Index) !MCValue {
            const air_tags = self.air.instructions.items(.tag);
            switch (air_tags[inst]) {
                // zig fmt: off
                //.add     => return self.genAdd(inst.castTag(.add).?),
                //.addwrap => return self.genAddWrap(inst.castTag(.addwrap).?),
                //.sub     => return self.genSub(inst.castTag(.sub).?),
                //.subwrap => return self.genSubWrap(inst.castTag(.subwrap).?),
                //.mul     => return self.genMul(inst.castTag(.mul).?),
                //.mulwrap => return self.genMulWrap(inst.castTag(.mulwrap).?),
                //.div     => return self.genDiv(inst.castTag(.div).?),

                //.cmp_lt  => return self.genCmp(inst.castTag(.cmp_lt).?,  .lt),
                //.cmp_lte => return self.genCmp(inst.castTag(.cmp_lte).?, .lte),
                //.cmp_eq  => return self.genCmp(inst.castTag(.cmp_eq).?,  .eq),
                //.cmp_gte => return self.genCmp(inst.castTag(.cmp_gte).?, .gte),
                //.cmp_gt  => return self.genCmp(inst.castTag(.cmp_gt).?,  .gt),
                //.cmp_neq => return self.genCmp(inst.castTag(.cmp_neq).?, .neq),

                //.bool_and => return self.genBoolOp(inst.castTag(.bool_and).?),
                //.bool_or  => return self.genBoolOp(inst.castTag(.bool_or).?),
                //.bit_and  => return self.genBitAnd(inst.castTag(.bit_and).?),
                //.bit_or   => return self.genBitOr(inst.castTag(.bit_or).?),
                //.xor      => return self.genXor(inst.castTag(.xor).?),

                //.alloc           => return self.genAlloc(inst.castTag(.alloc).?),
                //.arg             => return self.genArg(inst.castTag(.arg).?),
                //.assembly        => return self.genAsm(inst.castTag(.assembly).?),
                //.bitcast         => return self.genBitCast(inst.castTag(.bitcast).?),
                //.block           => return self.genBlock(inst.castTag(.block).?),
                //.br              => return self.genBr(inst.castTag(.br).?),
                //.br_block_flat   => return self.genBrBlockFlat(inst.castTag(.br_block_flat).?),
                //.breakpoint      => return self.genBreakpoint(inst.src),
                //.call            => return self.genCall(inst.castTag(.call).?),
                //.cond_br         => return self.genCondBr(inst.castTag(.condbr).?),
                //.dbg_stmt        => return self.genDbgStmt(inst.castTag(.dbg_stmt).?),
                //.floatcast       => return self.genFloatCast(inst.castTag(.floatcast).?),
                //.intcast         => return self.genIntCast(inst.castTag(.intcast).?),
                //.is_non_null     => return self.genIsNonNull(inst.castTag(.is_non_null).?),
                //.is_non_null_ptr => return self.genIsNonNullPtr(inst.castTag(.is_non_null_ptr).?),
                //.is_null         => return self.genIsNull(inst.castTag(.is_null).?),
                //.is_null_ptr     => return self.genIsNullPtr(inst.castTag(.is_null_ptr).?),
                //.is_non_err      => return self.genIsNonErr(inst.castTag(.is_non_err).?),
                //.is_non_err_ptr  => return self.genIsNonErrPtr(inst.castTag(.is_non_err_ptr).?),
                //.is_err          => return self.genIsErr(inst.castTag(.is_err).?),
                //.is_err_ptr      => return self.genIsErrPtr(inst.castTag(.is_err_ptr).?),
                //.load            => return self.genLoad(inst.castTag(.load).?),
                //.loop            => return self.genLoop(inst.castTag(.loop).?),
                //.not             => return self.genNot(inst.castTag(.not).?),
                //.ptrtoint        => return self.genPtrToInt(inst.castTag(.ptrtoint).?),
                //.ref             => return self.genRef(inst.castTag(.ref).?),
                //.ret             => return self.genRet(inst.castTag(.ret).?),
                //.store           => return self.genStore(inst.castTag(.store).?),
                //.struct_field_ptr=> return self.genStructFieldPtr(inst.castTag(.struct_field_ptr).?),
                //.switch_br       => return self.genSwitch(inst.castTag(.switchbr).?),
                //.varptr          => return self.genVarPtr(inst.castTag(.varptr).?),

                //.constant => unreachable, // excluded from function bodies
                //.unreach  => return MCValue{ .unreach = {} },

                //.optional_payload           => return self.genOptionalPayload(inst.castTag(.optional_payload).?),
                //.optional_payload_ptr       => return self.genOptionalPayloadPtr(inst.castTag(.optional_payload_ptr).?),
                //.unwrap_errunion_err        => return self.genUnwrapErrErr(inst.castTag(.unwrap_errunion_err).?),
                //.unwrap_errunion_payload    => return self.genUnwrapErrPayload(inst.castTag(.unwrap_errunion_payload).?),
                //.unwrap_errunion_err_ptr    => return self.genUnwrapErrErrPtr(inst.castTag(.unwrap_errunion_err_ptr).?),
                //.unwrap_errunion_payload_ptr=> return self.genUnwrapErrPayloadPtr(inst.castTag(.unwrap_errunion_payload_ptr).?),

                //.wrap_optional         => return self.genWrapOptional(inst.castTag(.wrap_optional).?),
                //.wrap_errunion_payload => return self.genWrapErrUnionPayload(inst.castTag(.wrap_errunion_payload).?),
                //.wrap_errunion_err     => return self.genWrapErrUnionErr(inst.castTag(.wrap_errunion_err).?),

                // zig fmt: on

                else => @panic("TODO finish air memory layout branch, more codegen.zig instructions"),
            }
        }

        fn allocMem(self: *Self, inst: Air.Inst.Index, abi_size: u32, abi_align: u32) !u32 {
            if (abi_align > self.stack_align)
                self.stack_align = abi_align;
            // TODO find a free slot instead of always appending
            const offset = mem.alignForwardGeneric(u32, self.next_stack_offset, abi_align);
            self.next_stack_offset = offset + abi_size;
            if (self.next_stack_offset > self.max_end_stack)
                self.max_end_stack = self.next_stack_offset;
            try self.stack.putNoClobber(self.gpa, offset, .{
                .inst = inst,
                .size = abi_size,
            });
            return offset;
        }

        /// Use a pointer instruction as the basis for allocating stack memory.
        fn allocMemPtr(self: *Self, inst: Air.Inst.Index) !u32 {
            const elem_ty = self.air.getType(inst).elemType();
            const abi_size = math.cast(u32, elem_ty.abiSize(self.target.*)) catch {
                return self.fail("type '{}' too big to fit into stack frame", .{elem_ty});
            };
            // TODO swap this for inst.ty.ptrAlign
            const abi_align = elem_ty.abiAlignment(self.target.*);
            return self.allocMem(inst, abi_size, abi_align);
        }

        fn allocRegOrMem(self: *Self, inst: Air.Inst.Index, reg_ok: bool) !MCValue {
            const elem_ty = inst.ty;
            const abi_size = math.cast(u32, elem_ty.abiSize(self.target.*)) catch {
                return self.fail("type '{}' too big to fit into stack frame", .{elem_ty});
            };
            const abi_align = elem_ty.abiAlignment(self.target.*);
            if (abi_align > self.stack_align)
                self.stack_align = abi_align;

            if (reg_ok) {
                // Make sure the type can fit in a register before we try to allocate one.
                const ptr_bits = arch.ptrBitWidth();
                const ptr_bytes: u64 = @divExact(ptr_bits, 8);
                if (abi_size <= ptr_bytes) {
                    if (self.register_manager.tryAllocReg(inst, &.{})) |reg| {
                        return MCValue{ .register = registerAlias(reg, abi_size) };
                    }
                }
            }
            const stack_offset = try self.allocMem(inst, abi_size, abi_align);
            return MCValue{ .stack_offset = stack_offset };
        }

        pub fn spillInstruction(self: *Self, reg: Register, inst: Air.Inst.Index) !void {
            const stack_mcv = try self.allocRegOrMem(inst, false);
            log.debug("spilling {*} to stack mcv {any}", .{ inst, stack_mcv });
            const reg_mcv = self.getResolvedInstValue(inst);
            assert(reg == toCanonicalReg(reg_mcv.register));
            const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
            try branch.inst_table.put(self.gpa, inst, stack_mcv);
            try self.genSetStack(inst.ty, stack_mcv.stack_offset, reg_mcv);
        }

        /// Copies a value to a register without tracking the register. The register is not considered
        /// allocated. A second call to `copyToTmpRegister` may return the same register.
        /// This can have a side effect of spilling instructions to the stack to free up a register.
        fn copyToTmpRegister(self: *Self, ty: Type, mcv: MCValue) !Register {
            const reg = try self.register_manager.allocReg(null, &.{});
            try self.genSetReg(ty, reg, mcv);
            return reg;
        }

        /// Allocates a new register and copies `mcv` into it.
        /// `reg_owner` is the instruction that gets associated with the register in the register table.
        /// This can have a side effect of spilling instructions to the stack to free up a register.
        fn copyToNewRegister(self: *Self, reg_owner: Air.Inst.Index, mcv: MCValue) !MCValue {
            const reg = try self.register_manager.allocReg(reg_owner, &.{});
            try self.genSetReg(reg_owner.ty, reg, mcv);
            return MCValue{ .register = reg };
        }

        fn genAlloc(self: *Self, inst: Air.Inst.Index) !MCValue {
            const stack_offset = try self.allocMemPtr(inst);
            return MCValue{ .ptr_stack_offset = stack_offset };
        }

        fn genFloatCast(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            switch (arch) {
                else => return self.fail("TODO implement floatCast for {}", .{self.target.cpu.arch}),
            }
        }

        fn genIntCast(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;

            const ty_op = self.air.instructions.items(.data)[inst].ty_op;
            const operand_ty = self.air.getType(ty_op.operand);
            const operand = try self.resolveInst(ty_op.operand);
            const info_a = operand_ty.intInfo(self.target.*);
            const info_b = self.air.getType(inst).intInfo(self.target.*);
            if (info_a.signedness != info_b.signedness)
                return self.fail("TODO gen intcast sign safety in semantic analysis", .{});

            if (info_a.bits == info_b.bits)
                return operand;

            switch (arch) {
                else => return self.fail("TODO implement intCast for {}", .{self.target.cpu.arch}),
            }
        }

        fn genNot(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const ty_op = self.air.instructions.items(.data)[inst].ty_op;
            const operand = try self.resolveInst(ty_op.operand);
            switch (operand) {
                .dead => unreachable,
                .unreach => unreachable,
                .compare_flags_unsigned => |op| return MCValue{
                    .compare_flags_unsigned = switch (op) {
                        .gte => .lt,
                        .gt => .lte,
                        .neq => .eq,
                        .lt => .gte,
                        .lte => .gt,
                        .eq => .neq,
                    },
                },
                .compare_flags_signed => |op| return MCValue{
                    .compare_flags_signed = switch (op) {
                        .gte => .lt,
                        .gt => .lte,
                        .neq => .eq,
                        .lt => .gte,
                        .lte => .gt,
                        .eq => .neq,
                    },
                },
                else => {},
            }

            switch (arch) {
                .x86_64 => {
                    return try self.genX8664BinMath(inst, ty_op.operand, .bool_true);
                },
                .arm, .armeb => {
                    return try self.genArmBinOp(inst, ty_op.operand, .bool_true, .not);
                },
                else => return self.fail("TODO implement NOT for {}", .{self.target.cpu.arch}),
            }
        }

        fn genAdd(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            switch (arch) {
                .x86_64 => {
                    return try self.genX8664BinMath(inst, bin_op.lhs, bin_op.rhs);
                },
                .arm, .armeb => return try self.genArmBinOp(inst, bin_op.lhs, bin_op.rhs, .add),
                else => return self.fail("TODO implement add for {}", .{self.target.cpu.arch}),
            }
        }

        fn genAddWrap(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            _ = bin_op;
            switch (arch) {
                else => return self.fail("TODO implement addwrap for {}", .{self.target.cpu.arch}),
            }
        }

        fn genMul(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            switch (arch) {
                .x86_64 => return try self.genX8664BinMath(inst, bin_op.lhs, bin_op.rhs),
                .arm, .armeb => return try self.genArmMul(inst, bin_op.lhs, bin_op.rhs),
                else => return self.fail("TODO implement mul for {}", .{self.target.cpu.arch}),
            }
        }

        fn genMulWrap(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            _ = bin_op;
            switch (arch) {
                else => return self.fail("TODO implement mulwrap for {}", .{self.target.cpu.arch}),
            }
        }

        fn genDiv(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            _ = bin_op;
            switch (arch) {
                else => return self.fail("TODO implement div for {}", .{self.target.cpu.arch}),
            }
        }

        fn genBitAnd(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            switch (arch) {
                .arm, .armeb => return try self.genArmBinOp(inst, bin_op.lhs, bin_op.rhs, .bit_and),
                else => return self.fail("TODO implement bitwise and for {}", .{self.target.cpu.arch}),
            }
        }

        fn genBitOr(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            switch (arch) {
                .arm, .armeb => return try self.genArmBinOp(inst, bin_op.lhs, bin_op.rhs, .bit_or),
                else => return self.fail("TODO implement bitwise or for {}", .{self.target.cpu.arch}),
            }
        }

        fn genXor(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            switch (arch) {
                .arm, .armeb => return try self.genArmBinOp(inst, bin_op.lhs, bin_op.rhs, .xor),
                else => return self.fail("TODO implement xor for {}", .{self.target.cpu.arch}),
            }
        }

        fn genOptionalPayload(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            switch (arch) {
                else => return self.fail("TODO implement .optional_payload for {}", .{self.target.cpu.arch}),
            }
        }

        fn genOptionalPayloadPtr(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            switch (arch) {
                else => return self.fail("TODO implement .optional_payload_ptr for {}", .{self.target.cpu.arch}),
            }
        }

        fn genUnwrapErrErr(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            switch (arch) {
                else => return self.fail("TODO implement unwrap error union error for {}", .{self.target.cpu.arch}),
            }
        }

        fn genUnwrapErrPayload(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            switch (arch) {
                else => return self.fail("TODO implement unwrap error union payload for {}", .{self.target.cpu.arch}),
            }
        }
        // *(E!T) -> E
        fn genUnwrapErrErrPtr(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            switch (arch) {
                else => return self.fail("TODO implement unwrap error union error ptr for {}", .{self.target.cpu.arch}),
            }
        }
        // *(E!T) -> *T
        fn genUnwrapErrPayloadPtr(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            switch (arch) {
                else => return self.fail("TODO implement unwrap error union payload ptr for {}", .{self.target.cpu.arch}),
            }
        }
        fn genWrapOptional(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;

            const optional_ty = self.air.getType(inst);

            // Optional type is just a boolean true
            if (optional_ty.abiSize(self.target.*) == 1)
                return MCValue{ .immediate = 1 };

            switch (arch) {
                else => return self.fail("TODO implement wrap optional for {}", .{self.target.cpu.arch}),
            }
        }

        /// T to E!T
        fn genWrapErrUnionPayload(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;

            switch (arch) {
                else => return self.fail("TODO implement wrap errunion payload for {}", .{self.target.cpu.arch}),
            }
        }

        /// E to E!T
        fn genWrapErrUnionErr(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;

            switch (arch) {
                else => return self.fail("TODO implement wrap errunion error for {}", .{self.target.cpu.arch}),
            }
        }
        fn genVarPtr(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;

            switch (arch) {
                else => return self.fail("TODO implement varptr for {}", .{self.target.cpu.arch}),
            }
        }

        fn reuseOperand(self: *Self, inst: Air.Inst.Index, op_index: u2, mcv: MCValue) bool {
            if (!self.liveness.operandDies(inst, op_index))
                return false;

            switch (mcv) {
                .register => |reg| {
                    // If it's in the registers table, need to associate the register with the
                    // new instruction.
                    if (reg.allocIndex()) |index| {
                        if (!self.register_manager.isRegFree(reg)) {
                            self.register_manager.registers[index] = inst;
                        }
                    }
                    log.debug("reusing {} => {}", .{ reg, inst });
                },
                .stack_offset => |off| {
                    log.debug("reusing stack offset {} => {}", .{ off, inst });
                },
                else => return false,
            }

            // Prevent the operand deaths processing code from deallocating it.
            self.liveness.clearOperandDeath(inst, op_index);

            // That makes us responsible for doing the rest of the stuff that processDeath would have done.
            const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
            branch.inst_table.putAssumeCapacity(inst.getOperand(op_index).?, .dead);

            return true;
        }

        fn load(self: *Self, dst_mcv: MCValue, ptr: MCValue) !void {
            switch (ptr) {
                .none => unreachable,
                .undef => unreachable,
                .unreach => unreachable,
                .dead => unreachable,
                .compare_flags_unsigned => unreachable,
                .compare_flags_signed => unreachable,
                .immediate => |imm| try self.setRegOrMem(elem_ty, dst_mcv, .{ .memory = imm }),
                .ptr_stack_offset => |off| try self.setRegOrMem(elem_ty, dst_mcv, .{ .stack_offset = off }),
                .ptr_embedded_in_code => |off| {
                    try self.setRegOrMem(elem_ty, dst_mcv, .{ .embedded_in_code = off });
                },
                .embedded_in_code => {
                    return self.fail("TODO implement loading from MCValue.embedded_in_code", .{});
                },
                .register => {
                    return self.fail("TODO implement loading from MCValue.register", .{});
                },
                .memory => {
                    return self.fail("TODO implement loading from MCValue.memory", .{});
                },
                .stack_offset => {
                    return self.fail("TODO implement loading from MCValue.stack_offset", .{});
                },
            }
        }

        fn genLoad(self: *Self, inst: Air.Inst.Index) !MCValue {
            const elem_ty = self.air.getType(inst);
            if (!elem_ty.hasCodeGenBits())
                return MCValue.none;
            const ptr = try self.resolveInst(inst.operand);
            const is_volatile = inst.operand.ty.isVolatilePtr();
            if (self.liveness.isUnused(inst) and !is_volatile)
                return MCValue.dead;
            const dst_mcv: MCValue = blk: {
                if (self.reuseOperand(inst, 0, ptr)) {
                    // The MCValue that holds the pointer can be re-used as the value.
                    break :blk ptr;
                } else {
                    break :blk try self.allocRegOrMem(inst, true);
                }
            };
            self.load(dst_mcv, ptr);
            return dst_mcv;
        }

        fn genStore(self: *Self, inst: Air.Inst.Index) !MCValue {
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            const ptr = try self.resolveInst(bin_op.lhs);
            const value = try self.resolveInst(bin_op.rhs);
            const elem_ty = self.getType(bin_op.rhs);
            switch (ptr) {
                .none => unreachable,
                .undef => unreachable,
                .unreach => unreachable,
                .dead => unreachable,
                .compare_flags_unsigned => unreachable,
                .compare_flags_signed => unreachable,
                .immediate => |imm| {
                    try self.setRegOrMem(elem_ty, .{ .memory = imm }, value);
                },
                .ptr_stack_offset => |off| {
                    try self.genSetStack(elem_ty, off, value);
                },
                .ptr_embedded_in_code => |off| {
                    try self.setRegOrMem(elem_ty, .{ .embedded_in_code = off }, value);
                },
                .embedded_in_code => {
                    return self.fail("TODO implement storing to MCValue.embedded_in_code", .{});
                },
                .register => {
                    return self.fail("TODO implement storing to MCValue.register", .{});
                },
                .memory => {
                    return self.fail("TODO implement storing to MCValue.memory", .{});
                },
                .stack_offset => {
                    return self.fail("TODO implement storing to MCValue.stack_offset", .{});
                },
            }
            return .none;
        }

        fn genStructFieldPtr(self: *Self, inst: Air.Inst.Index) !MCValue {
            const struct_field_ptr = self.air.instructions.items(.data)[inst].struct_field_ptr;
            _ = struct_field_ptr;
            return self.fail("TODO implement codegen struct_field_ptr", .{});
        }

        fn genSub(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            switch (arch) {
                .x86_64 => return self.genX8664BinMath(inst, bin_op.lhs, bin_op.rhs),
                .arm, .armeb => return self.genArmBinOp(inst, bin_op.lhs, bin_op.rhs, .sub),
                else => return self.fail("TODO implement sub for {}", .{self.target.cpu.arch}),
            }
        }

        fn genSubWrap(self: *Self, inst: Air.Inst.Index) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            _ = bin_op;
            switch (arch) {
                else => return self.fail("TODO implement subwrap for {}", .{self.target.cpu.arch}),
            }
        }

        fn armOperandShouldBeRegister(self: *Self, mcv: MCValue) !bool {
            return switch (mcv) {
                .none => unreachable,
                .undef => unreachable,
                .dead, .unreach => unreachable,
                .compare_flags_unsigned => unreachable,
                .compare_flags_signed => unreachable,
                .ptr_stack_offset => unreachable,
                .ptr_embedded_in_code => unreachable,
                .immediate => |imm| blk: {
                    if (imm > std.math.maxInt(u32)) return self.fail("TODO ARM binary arithmetic immediate larger than u32", .{});

                    // Load immediate into register if it doesn't fit
                    // in an operand
                    break :blk Instruction.Operand.fromU32(@intCast(u32, imm)) == null;
                },
                .register => true,
                .stack_offset,
                .embedded_in_code,
                .memory,
                => true,
            };
        }

        fn genArmBinOp(self: *Self, inst: Air.Inst.Index, op_lhs: Air.Inst.Ref, op_rhs: Air.Inst.Ref, op: ir.Inst.Tag) !MCValue {
            const lhs = try self.resolveInst(op_lhs);
            const rhs = try self.resolveInst(op_rhs);

            const lhs_is_register = lhs == .register;
            const rhs_is_register = rhs == .register;
            const lhs_should_be_register = try self.armOperandShouldBeRegister(lhs);
            const rhs_should_be_register = try self.armOperandShouldBeRegister(rhs);
            const reuse_lhs = lhs_is_register and self.reuseOperand(inst, 0, lhs);
            const reuse_rhs = !reuse_lhs and rhs_is_register and self.reuseOperand(inst, 1, rhs);

            // Destination must be a register
            var dst_mcv: MCValue = undefined;
            var lhs_mcv = lhs;
            var rhs_mcv = rhs;
            var swap_lhs_and_rhs = false;

            // Allocate registers for operands and/or destination
            const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
            if (reuse_lhs) {
                // Allocate 0 or 1 registers
                if (!rhs_is_register and rhs_should_be_register) {
                    rhs_mcv = MCValue{ .register = try self.register_manager.allocReg(op_rhs, &.{lhs.register}) };
                    branch.inst_table.putAssumeCapacity(op_rhs, rhs_mcv);
                }
                dst_mcv = lhs;
            } else if (reuse_rhs) {
                // Allocate 0 or 1 registers
                if (!lhs_is_register and lhs_should_be_register) {
                    lhs_mcv = MCValue{ .register = try self.register_manager.allocReg(op_lhs, &.{rhs.register}) };
                    branch.inst_table.putAssumeCapacity(op_lhs, lhs_mcv);
                }
                dst_mcv = rhs;

                swap_lhs_and_rhs = true;
            } else {
                // Allocate 1 or 2 registers
                if (lhs_should_be_register and rhs_should_be_register) {
                    if (lhs_is_register and rhs_is_register) {
                        dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{ lhs.register, rhs.register }) };
                    } else if (lhs_is_register) {
                        // Move RHS to register
                        dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{lhs.register}) };
                        rhs_mcv = dst_mcv;
                    } else if (rhs_is_register) {
                        // Move LHS to register
                        dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{rhs.register}) };
                        lhs_mcv = dst_mcv;
                    } else {
                        // Move LHS and RHS to register
                        const regs = try self.register_manager.allocRegs(2, .{ inst, op_rhs }, &.{});
                        lhs_mcv = MCValue{ .register = regs[0] };
                        rhs_mcv = MCValue{ .register = regs[1] };
                        dst_mcv = lhs_mcv;

                        branch.inst_table.putAssumeCapacity(op_rhs, rhs_mcv);
                    }
                } else if (lhs_should_be_register) {
                    // RHS is immediate
                    if (lhs_is_register) {
                        dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{lhs.register}) };
                    } else {
                        dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{}) };
                        lhs_mcv = dst_mcv;
                    }
                } else if (rhs_should_be_register) {
                    // LHS is immediate
                    if (rhs_is_register) {
                        dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{rhs.register}) };
                    } else {
                        dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{}) };
                        rhs_mcv = dst_mcv;
                    }

                    swap_lhs_and_rhs = true;
                } else unreachable; // binary operation on two immediates
            }

            // Move the operands to the newly allocated registers
            if (lhs_mcv == .register and !lhs_is_register) {
                try self.genSetReg(op_lhs.ty, lhs_mcv.register, lhs);
            }
            if (rhs_mcv == .register and !rhs_is_register) {
                try self.genSetReg(op_rhs.ty, rhs_mcv.register, rhs);
            }

            try self.genArmBinOpCode(
                dst_mcv.register,
                lhs_mcv,
                rhs_mcv,
                swap_lhs_and_rhs,
                op,
            );
            return dst_mcv;
        }

        fn genArmBinOpCode(
            self: *Self,
            dst_reg: Register,
            lhs_mcv: MCValue,
            rhs_mcv: MCValue,
            swap_lhs_and_rhs: bool,
            op: ir.Inst.Tag,
        ) !void {
            assert(lhs_mcv == .register or rhs_mcv == .register);

            const op1 = if (swap_lhs_and_rhs) rhs_mcv.register else lhs_mcv.register;
            const op2 = if (swap_lhs_and_rhs) lhs_mcv else rhs_mcv;

            const operand = switch (op2) {
                .none => unreachable,
                .undef => unreachable,
                .dead, .unreach => unreachable,
                .compare_flags_unsigned => unreachable,
                .compare_flags_signed => unreachable,
                .ptr_stack_offset => unreachable,
                .ptr_embedded_in_code => unreachable,
                .immediate => |imm| Instruction.Operand.fromU32(@intCast(u32, imm)).?,
                .register => |reg| Instruction.Operand.reg(reg, Instruction.Operand.Shift.none),
                .stack_offset,
                .embedded_in_code,
                .memory,
                => unreachable,
            };

            switch (op) {
                .add => {
                    writeInt(u32, try self.code.addManyAsArray(4), Instruction.add(.al, dst_reg, op1, operand).toU32());
                },
                .sub => {
                    if (swap_lhs_and_rhs) {
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.rsb(.al, dst_reg, op1, operand).toU32());
                    } else {
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.sub(.al, dst_reg, op1, operand).toU32());
                    }
                },
                .bool_and, .bit_and => {
                    writeInt(u32, try self.code.addManyAsArray(4), Instruction.@"and"(.al, dst_reg, op1, operand).toU32());
                },
                .bool_or, .bit_or => {
                    writeInt(u32, try self.code.addManyAsArray(4), Instruction.orr(.al, dst_reg, op1, operand).toU32());
                },
                .not, .xor => {
                    writeInt(u32, try self.code.addManyAsArray(4), Instruction.eor(.al, dst_reg, op1, operand).toU32());
                },
                .cmp_eq => {
                    writeInt(u32, try self.code.addManyAsArray(4), Instruction.cmp(.al, op1, operand).toU32());
                },
                else => unreachable, // not a binary instruction
            }
        }

        fn genArmMul(self: *Self, inst: Air.Inst.Index, op_lhs: Air.Inst.Index, op_rhs: Air.Inst.Index) !MCValue {
            const lhs = try self.resolveInst(op_lhs);
            const rhs = try self.resolveInst(op_rhs);

            const lhs_is_register = lhs == .register;
            const rhs_is_register = rhs == .register;
            const reuse_lhs = lhs_is_register and self.reuseOperand(inst, 0, lhs);
            const reuse_rhs = !reuse_lhs and rhs_is_register and self.reuseOperand(inst, 1, rhs);

            // Destination must be a register
            // LHS must be a register
            // RHS must be a register
            var dst_mcv: MCValue = undefined;
            var lhs_mcv: MCValue = lhs;
            var rhs_mcv: MCValue = rhs;

            // Allocate registers for operands and/or destination
            const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
            if (reuse_lhs) {
                // Allocate 0 or 1 registers
                if (!rhs_is_register) {
                    rhs_mcv = MCValue{ .register = try self.register_manager.allocReg(op_rhs, &.{lhs.register}) };
                    branch.inst_table.putAssumeCapacity(op_rhs, rhs_mcv);
                }
                dst_mcv = lhs;
            } else if (reuse_rhs) {
                // Allocate 0 or 1 registers
                if (!lhs_is_register) {
                    lhs_mcv = MCValue{ .register = try self.register_manager.allocReg(op_lhs, &.{rhs.register}) };
                    branch.inst_table.putAssumeCapacity(op_lhs, lhs_mcv);
                }
                dst_mcv = rhs;
            } else {
                // Allocate 1 or 2 registers
                if (lhs_is_register and rhs_is_register) {
                    dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{ lhs.register, rhs.register }) };
                } else if (lhs_is_register) {
                    // Move RHS to register
                    dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{lhs.register}) };
                    rhs_mcv = dst_mcv;
                } else if (rhs_is_register) {
                    // Move LHS to register
                    dst_mcv = MCValue{ .register = try self.register_manager.allocReg(inst, &.{rhs.register}) };
                    lhs_mcv = dst_mcv;
                } else {
                    // Move LHS and RHS to register
                    const regs = try self.register_manager.allocRegs(2, .{ inst, op_rhs }, &.{});
                    lhs_mcv = MCValue{ .register = regs[0] };
                    rhs_mcv = MCValue{ .register = regs[1] };
                    dst_mcv = lhs_mcv;

                    branch.inst_table.putAssumeCapacity(op_rhs, rhs_mcv);
                }
            }

            // Move the operands to the newly allocated registers
            if (!lhs_is_register) {
                try self.genSetReg(op_lhs.ty, lhs_mcv.register, lhs);
            }
            if (!rhs_is_register) {
                try self.genSetReg(op_rhs.ty, rhs_mcv.register, rhs);
            }

            writeInt(u32, try self.code.addManyAsArray(4), Instruction.mul(.al, dst_mcv.register, lhs_mcv.register, rhs_mcv.register).toU32());
            return dst_mcv;
        }

        /// Perform "binary" operators, excluding comparisons.
        /// Currently, the following ops are supported:
        /// ADD, SUB, XOR, OR, AND
        fn genX8664BinMath(self: *Self, inst: Air.Inst.Index, op_lhs: Air.Inst.Ref, op_rhs: Air.Inst.Ref) !MCValue {
            // We'll handle these ops in two steps.
            // 1) Prepare an output location (register or memory)
            //    This location will be the location of the operand that dies (if one exists)
            //    or just a temporary register (if one doesn't exist)
            // 2) Perform the op with the other argument
            // 3) Sometimes, the output location is memory but the op doesn't support it.
            //    In this case, copy that location to a register, then perform the op to that register instead.
            //
            // TODO: make this algorithm less bad

            try self.code.ensureCapacity(self.code.items.len + 8);

            const lhs = try self.resolveInst(op_lhs);
            const rhs = try self.resolveInst(op_rhs);

            // There are 2 operands, destination and source.
            // Either one, but not both, can be a memory operand.
            // Source operand can be an immediate, 8 bits or 32 bits.
            // So, if either one of the operands dies with this instruction, we can use it
            // as the result MCValue.
            var dst_mcv: MCValue = undefined;
            var src_mcv: MCValue = undefined;
            var src_inst: Air.Inst.Index = undefined;
            if (self.reuseOperand(inst, 0, lhs)) {
                // LHS dies; use it as the destination.
                // Both operands cannot be memory.
                src_inst = op_rhs;
                if (lhs.isMemory() and rhs.isMemory()) {
                    dst_mcv = try self.copyToNewRegister(inst, lhs);
                    src_mcv = rhs;
                } else {
                    dst_mcv = lhs;
                    src_mcv = rhs;
                }
            } else if (self.reuseOperand(inst, 1, rhs)) {
                // RHS dies; use it as the destination.
                // Both operands cannot be memory.
                src_inst = op_lhs;
                if (lhs.isMemory() and rhs.isMemory()) {
                    dst_mcv = try self.copyToNewRegister(inst, rhs);
                    src_mcv = lhs;
                } else {
                    dst_mcv = rhs;
                    src_mcv = lhs;
                }
            } else {
                if (lhs.isMemory()) {
                    dst_mcv = try self.copyToNewRegister(inst, lhs);
                    src_mcv = rhs;
                    src_inst = op_rhs;
                } else {
                    dst_mcv = try self.copyToNewRegister(inst, rhs);
                    src_mcv = lhs;
                    src_inst = op_lhs;
                }
            }
            // This instruction supports only signed 32-bit immediates at most. If the immediate
            // value is larger than this, we put it in a register.
            // A potential opportunity for future optimization here would be keeping track
            // of the fact that the instruction is available both as an immediate
            // and as a register.
            switch (src_mcv) {
                .immediate => |imm| {
                    if (imm > math.maxInt(u31)) {
                        src_mcv = MCValue{ .register = try self.copyToTmpRegister(Type.initTag(.u64), src_mcv) };
                    }
                },
                else => {},
            }

            // Now for step 2, we perform the actual op
            const air_tags = self.air.instructions.items(.tag);
            switch (air_tags[inst]) {
                // TODO: Generate wrapping and non-wrapping versions separately
                .add, .addwrap => try self.genX8664BinMathCode(inst.ty, dst_mcv, src_mcv, 0, 0x00),
                .bool_or, .bit_or => try self.genX8664BinMathCode(inst.ty, dst_mcv, src_mcv, 1, 0x08),
                .bool_and, .bit_and => try self.genX8664BinMathCode(inst.ty, dst_mcv, src_mcv, 4, 0x20),
                .sub, .subwrap => try self.genX8664BinMathCode(inst.ty, dst_mcv, src_mcv, 5, 0x28),
                .xor, .not => try self.genX8664BinMathCode(inst.ty, dst_mcv, src_mcv, 6, 0x30),

                .mul, .mulwrap => try self.genX8664Imul(inst.src, inst.ty, dst_mcv, src_mcv),
                else => unreachable,
            }

            return dst_mcv;
        }

        /// Wrap over Instruction.encodeInto to translate errors
        fn encodeX8664Instruction(self: *Self, inst: Instruction) !void {
            inst.encodeInto(self.code) catch |err| {
                if (err == error.OutOfMemory)
                    return error.OutOfMemory
                else
                    return self.fail("Instruction.encodeInto failed because {s}", .{@errorName(err)});
            };
        }

        /// This function encodes a binary operation for x86_64
        /// intended for use with the following opcode ranges
        /// because they share the same structure.
        ///
        /// Thus not all binary operations can be used here
        /// -- multiplication needs to be done with imul,
        /// which doesn't have as convenient an interface.
        ///
        /// "opx"-style instructions use the opcode extension field to indicate which instruction to execute:
        ///
        /// opx = /0: add
        /// opx = /1: or
        /// opx = /2: adc
        /// opx = /3: sbb
        /// opx = /4: and
        /// opx = /5: sub
        /// opx = /6: xor
        /// opx = /7: cmp
        ///
        /// opcode  | operand shape
        /// --------+----------------------
        /// 80 /opx | *r/m8*,        imm8
        /// 81 /opx | *r/m16/32/64*, imm16/32
        /// 83 /opx | *r/m16/32/64*, imm8
        ///
        /// "mr"-style instructions use the low bits of opcode to indicate shape of instruction:
        ///
        /// mr = 00: add
        /// mr = 08: or
        /// mr = 10: adc
        /// mr = 18: sbb
        /// mr = 20: and
        /// mr = 28: sub
        /// mr = 30: xor
        /// mr = 38: cmp
        ///
        /// opcode | operand shape
        /// -------+-------------------------
        /// mr + 0 | *r/m8*,        r8
        /// mr + 1 | *r/m16/32/64*, r16/32/64
        /// mr + 2 | *r8*,          r/m8
        /// mr + 3 | *r16/32/64*,   r/m16/32/64
        /// mr + 4 | *AL*,          imm8
        /// mr + 5 | *rAX*,         imm16/32
        ///
        /// TODO: rotates and shifts share the same structure, so we can potentially implement them
        ///       at a later date with very similar code.
        ///       They have "opx"-style instructions, but no "mr"-style instructions.
        ///
        /// opx = /0: rol,
        /// opx = /1: ror,
        /// opx = /2: rcl,
        /// opx = /3: rcr,
        /// opx = /4: shl sal,
        /// opx = /5: shr,
        /// opx = /6: sal shl,
        /// opx = /7: sar,
        ///
        /// opcode  | operand shape
        /// --------+------------------
        /// c0 /opx | *r/m8*,        imm8
        /// c1 /opx | *r/m16/32/64*, imm8
        /// d0 /opx | *r/m8*,        1
        /// d1 /opx | *r/m16/32/64*, 1
        /// d2 /opx | *r/m8*,        CL    (for context, CL is register 1)
        /// d3 /opx | *r/m16/32/64*, CL    (for context, CL is register 1)
        fn genX8664BinMathCode(
            self: *Self,
            dst_ty: Type,
            dst_mcv: MCValue,
            src_mcv: MCValue,
            opx: u3,
            mr: u8,
        ) !void {
            switch (dst_mcv) {
                .none => unreachable,
                .undef => unreachable,
                .dead, .unreach, .immediate => unreachable,
                .compare_flags_unsigned => unreachable,
                .compare_flags_signed => unreachable,
                .ptr_stack_offset => unreachable,
                .ptr_embedded_in_code => unreachable,
                .register => |dst_reg| {
                    switch (src_mcv) {
                        .none => unreachable,
                        .undef => try self.genSetReg(dst_ty, dst_reg, .undef),
                        .dead, .unreach => unreachable,
                        .ptr_stack_offset => unreachable,
                        .ptr_embedded_in_code => unreachable,
                        .register => |src_reg| {
                            // for register, register use mr + 1
                            // addressing mode: *r/m16/32/64*, r16/32/64
                            const abi_size = dst_ty.abiSize(self.target.*);
                            const encoder = try X8664Encoder.init(self.code, 3);
                            encoder.rex(.{
                                .w = abi_size == 8,
                                .r = src_reg.isExtended(),
                                .b = dst_reg.isExtended(),
                            });
                            encoder.opcode_1byte(mr + 1);
                            encoder.modRm_direct(
                                src_reg.low_id(),
                                dst_reg.low_id(),
                            );
                        },
                        .immediate => |imm| {
                            // register, immediate use opx = 81 or 83 addressing modes:
                            // opx = 81: r/m16/32/64, imm16/32
                            // opx = 83: r/m16/32/64, imm8
                            const imm32 = @intCast(i32, imm); // This case must be handled before calling genX8664BinMathCode.
                            if (imm32 <= math.maxInt(i8)) {
                                const abi_size = dst_ty.abiSize(self.target.*);
                                const encoder = try X8664Encoder.init(self.code, 4);
                                encoder.rex(.{
                                    .w = abi_size == 8,
                                    .b = dst_reg.isExtended(),
                                });
                                encoder.opcode_1byte(0x83);
                                encoder.modRm_direct(
                                    opx,
                                    dst_reg.low_id(),
                                );
                                encoder.imm8(@intCast(i8, imm32));
                            } else {
                                const abi_size = dst_ty.abiSize(self.target.*);
                                const encoder = try X8664Encoder.init(self.code, 7);
                                encoder.rex(.{
                                    .w = abi_size == 8,
                                    .b = dst_reg.isExtended(),
                                });
                                encoder.opcode_1byte(0x81);
                                encoder.modRm_direct(
                                    opx,
                                    dst_reg.low_id(),
                                );
                                encoder.imm32(@intCast(i32, imm32));
                            }
                        },
                        .embedded_in_code, .memory => {
                            return self.fail("TODO implement x86 ADD/SUB/CMP source memory", .{});
                        },
                        .stack_offset => |off| {
                            // register, indirect use mr + 3
                            // addressing mode: *r16/32/64*, r/m16/32/64
                            const abi_size = dst_ty.abiSize(self.target.*);
                            const adj_off = off + abi_size;
                            if (off > math.maxInt(i32)) {
                                return self.fail("stack offset too large", .{});
                            }
                            const encoder = try X8664Encoder.init(self.code, 7);
                            encoder.rex(.{
                                .w = abi_size == 8,
                                .r = dst_reg.isExtended(),
                            });
                            encoder.opcode_1byte(mr + 3);
                            if (adj_off <= std.math.maxInt(i8)) {
                                encoder.modRm_indirectDisp8(
                                    dst_reg.low_id(),
                                    Register.ebp.low_id(),
                                );
                                encoder.disp8(-@intCast(i8, adj_off));
                            } else {
                                encoder.modRm_indirectDisp32(
                                    dst_reg.low_id(),
                                    Register.ebp.low_id(),
                                );
                                encoder.disp32(-@intCast(i32, adj_off));
                            }
                        },
                        .compare_flags_unsigned => {
                            return self.fail("TODO implement x86 ADD/SUB/CMP source compare flag (unsigned)", .{});
                        },
                        .compare_flags_signed => {
                            return self.fail("TODO implement x86 ADD/SUB/CMP source compare flag (signed)", .{});
                        },
                    }
                },
                .stack_offset => |off| {
                    switch (src_mcv) {
                        .none => unreachable,
                        .undef => return self.genSetStack(dst_ty, off, .undef),
                        .dead, .unreach => unreachable,
                        .ptr_stack_offset => unreachable,
                        .ptr_embedded_in_code => unreachable,
                        .register => |src_reg| {
                            try self.genX8664ModRMRegToStack(src, dst_ty, off, src_reg, mr + 0x1);
                        },
                        .immediate => |imm| {
                            _ = imm;
                            return self.fail("TODO implement x86 ADD/SUB/CMP source immediate", .{});
                        },
                        .embedded_in_code, .memory, .stack_offset => {
                            return self.fail("TODO implement x86 ADD/SUB/CMP source memory", .{});
                        },
                        .compare_flags_unsigned => {
                            return self.fail("TODO implement x86 ADD/SUB/CMP source compare flag (unsigned)", .{});
                        },
                        .compare_flags_signed => {
                            return self.fail("TODO implement x86 ADD/SUB/CMP source compare flag (signed)", .{});
                        },
                    }
                },
                .embedded_in_code, .memory => {
                    return self.fail("TODO implement x86 ADD/SUB/CMP destination memory", .{});
                },
            }
        }

        /// Performs integer multiplication between dst_mcv and src_mcv, storing the result in dst_mcv.
        fn genX8664Imul(
            self: *Self,
            src: LazySrcLoc,
            dst_ty: Type,
            dst_mcv: MCValue,
            src_mcv: MCValue,
        ) !void {
            switch (dst_mcv) {
                .none => unreachable,
                .undef => unreachable,
                .dead, .unreach, .immediate => unreachable,
                .compare_flags_unsigned => unreachable,
                .compare_flags_signed => unreachable,
                .ptr_stack_offset => unreachable,
                .ptr_embedded_in_code => unreachable,
                .register => |dst_reg| {
                    switch (src_mcv) {
                        .none => unreachable,
                        .undef => try self.genSetReg(dst_ty, dst_reg, .undef),
                        .dead, .unreach => unreachable,
                        .ptr_stack_offset => unreachable,
                        .ptr_embedded_in_code => unreachable,
                        .register => |src_reg| {
                            // register, register
                            //
                            // Use the following imul opcode
                            // 0F AF /r: IMUL r32/64, r/m32/64
                            const abi_size = dst_ty.abiSize(self.target.*);
                            const encoder = try X8664Encoder.init(self.code, 4);
                            encoder.rex(.{
                                .w = abi_size == 8,
                                .r = dst_reg.isExtended(),
                                .b = src_reg.isExtended(),
                            });
                            encoder.opcode_2byte(0x0f, 0xaf);
                            encoder.modRm_direct(
                                dst_reg.low_id(),
                                src_reg.low_id(),
                            );
                        },
                        .immediate => |imm| {
                            // register, immediate:
                            // depends on size of immediate.
                            //
                            // immediate fits in i8:
                            // 6B /r ib: IMUL r32/64, r/m32/64, imm8
                            //
                            // immediate fits in i32:
                            // 69 /r id: IMUL r32/64, r/m32/64, imm32
                            //
                            // immediate is huge:
                            // split into 2 instructions
                            // 1) copy the 64 bit immediate into a tmp register
                            // 2) perform register,register mul
                            // 0F AF /r: IMUL r32/64, r/m32/64
                            if (math.minInt(i8) <= imm and imm <= math.maxInt(i8)) {
                                const abi_size = dst_ty.abiSize(self.target.*);
                                const encoder = try X8664Encoder.init(self.code, 4);
                                encoder.rex(.{
                                    .w = abi_size == 8,
                                    .r = dst_reg.isExtended(),
                                    .b = dst_reg.isExtended(),
                                });
                                encoder.opcode_1byte(0x6B);
                                encoder.modRm_direct(
                                    dst_reg.low_id(),
                                    dst_reg.low_id(),
                                );
                                encoder.imm8(@intCast(i8, imm));
                            } else if (math.minInt(i32) <= imm and imm <= math.maxInt(i32)) {
                                const abi_size = dst_ty.abiSize(self.target.*);
                                const encoder = try X8664Encoder.init(self.code, 7);
                                encoder.rex(.{
                                    .w = abi_size == 8,
                                    .r = dst_reg.isExtended(),
                                    .b = dst_reg.isExtended(),
                                });
                                encoder.opcode_1byte(0x69);
                                encoder.modRm_direct(
                                    dst_reg.low_id(),
                                    dst_reg.low_id(),
                                );
                                encoder.imm32(@intCast(i32, imm));
                            } else {
                                const src_reg = try self.copyToTmpRegister(dst_ty, src_mcv);
                                return self.genX8664Imul(src, dst_ty, dst_mcv, MCValue{ .register = src_reg });
                            }
                        },
                        .embedded_in_code, .memory, .stack_offset => {
                            return self.fail("TODO implement x86 multiply source memory", .{});
                        },
                        .compare_flags_unsigned => {
                            return self.fail("TODO implement x86 multiply source compare flag (unsigned)", .{});
                        },
                        .compare_flags_signed => {
                            return self.fail("TODO implement x86 multiply source compare flag (signed)", .{});
                        },
                    }
                },
                .stack_offset => |off| {
                    switch (src_mcv) {
                        .none => unreachable,
                        .undef => return self.genSetStack(dst_ty, off, .undef),
                        .dead, .unreach => unreachable,
                        .ptr_stack_offset => unreachable,
                        .ptr_embedded_in_code => unreachable,
                        .register => |src_reg| {
                            // copy dst to a register
                            const dst_reg = try self.copyToTmpRegister(dst_ty, dst_mcv);
                            // multiply into dst_reg
                            // register, register
                            // Use the following imul opcode
                            // 0F AF /r: IMUL r32/64, r/m32/64
                            const abi_size = dst_ty.abiSize(self.target.*);
                            const encoder = try X8664Encoder.init(self.code, 4);
                            encoder.rex(.{
                                .w = abi_size == 8,
                                .r = dst_reg.isExtended(),
                                .b = src_reg.isExtended(),
                            });
                            encoder.opcode_2byte(0x0f, 0xaf);
                            encoder.modRm_direct(
                                dst_reg.low_id(),
                                src_reg.low_id(),
                            );
                            // copy dst_reg back out
                            return self.genSetStack(dst_ty, off, MCValue{ .register = dst_reg });
                        },
                        .immediate => |imm| {
                            _ = imm;
                            return self.fail("TODO implement x86 multiply source immediate", .{});
                        },
                        .embedded_in_code, .memory, .stack_offset => {
                            return self.fail("TODO implement x86 multiply source memory", .{});
                        },
                        .compare_flags_unsigned => {
                            return self.fail("TODO implement x86 multiply source compare flag (unsigned)", .{});
                        },
                        .compare_flags_signed => {
                            return self.fail("TODO implement x86 multiply source compare flag (signed)", .{});
                        },
                    }
                },
                .embedded_in_code, .memory => {
                    return self.fail("TODO implement x86 multiply destination memory", .{});
                },
            }
        }

        fn genX8664ModRMRegToStack(self: *Self, ty: Type, off: u32, reg: Register, opcode: u8) !void {
            const abi_size = ty.abiSize(self.target.*);
            const adj_off = off + abi_size;
            if (off > math.maxInt(i32)) {
                return self.fail("stack offset too large", .{});
            }

            const i_adj_off = -@intCast(i32, adj_off);
            const encoder = try X8664Encoder.init(self.code, 7);
            encoder.rex(.{
                .w = abi_size == 8,
                .r = reg.isExtended(),
            });
            encoder.opcode_1byte(opcode);
            if (i_adj_off < std.math.maxInt(i8)) {
                // example: 48 89 55 7f           mov    QWORD PTR [rbp+0x7f],rdx
                encoder.modRm_indirectDisp8(
                    reg.low_id(),
                    Register.ebp.low_id(),
                );
                encoder.disp8(@intCast(i8, i_adj_off));
            } else {
                // example: 48 89 95 80 00 00 00  mov    QWORD PTR [rbp+0x80],rdx
                encoder.modRm_indirectDisp32(
                    reg.low_id(),
                    Register.ebp.low_id(),
                );
                encoder.disp32(i_adj_off);
            }
        }

        fn genArgDbgInfo(self: *Self, inst: Air.Inst.Index, mcv: MCValue) !void {
            const ty_str = self.air.instruction.items(.data)[inst].ty_str;
            const zir = &self.mod_fn.owner_decl.namespace.file_scope.zir;
            const name = zir.nullTerminatedString(ty_str.str);
            const name_with_null = name.ptr[0 .. name.len + 1];
            const ty = self.air.getRefType(ty_str.ty);

            switch (mcv) {
                .register => |reg| {
                    switch (self.debug_output) {
                        .dwarf => |dbg_out| {
                            try dbg_out.dbg_info.ensureCapacity(dbg_out.dbg_info.items.len + 3);
                            dbg_out.dbg_info.appendAssumeCapacity(link.File.Elf.abbrev_parameter);
                            dbg_out.dbg_info.appendSliceAssumeCapacity(&[2]u8{ // DW.AT_location, DW.FORM_exprloc
                                1, // ULEB128 dwarf expression length
                                reg.dwarfLocOp(),
                            });
                            try dbg_out.dbg_info.ensureCapacity(dbg_out.dbg_info.items.len + 5 + name_with_null.len);
                            try self.addDbgInfoTypeReloc(ty); // DW.AT_type,  DW.FORM_ref4
                            dbg_out.dbg_info.appendSliceAssumeCapacity(name_with_null); // DW.AT_name, DW.FORM_string
                        },
                        .none => {},
                    }
                },
                .stack_offset => |offset| {
                    switch (self.debug_output) {
                        .dwarf => |dbg_out| {
                            switch (arch) {
                                .arm, .armeb => {
                                    const abi_size = math.cast(u32, ty.abiSize(self.target.*)) catch {
                                        return self.fail("type '{}' too big to fit into stack frame", .{ty});
                                    };
                                    const adjusted_stack_offset = math.negateCast(offset + abi_size) catch {
                                        return self.fail("Stack offset too large for arguments", .{});
                                    };

                                    try dbg_out.dbg_info.append(link.File.Elf.abbrev_parameter);

                                    // Get length of the LEB128 stack offset
                                    var counting_writer = std.io.countingWriter(std.io.null_writer);
                                    leb128.writeILEB128(counting_writer.writer(), adjusted_stack_offset) catch unreachable;

                                    // DW.AT_location, DW.FORM_exprloc
                                    // ULEB128 dwarf expression length
                                    try leb128.writeULEB128(dbg_out.dbg_info.writer(), counting_writer.bytes_written + 1);
                                    try dbg_out.dbg_info.append(DW.OP_breg11);
                                    try leb128.writeILEB128(dbg_out.dbg_info.writer(), adjusted_stack_offset);

                                    try dbg_out.dbg_info.ensureCapacity(dbg_out.dbg_info.items.len + 5 + name_with_null.len);
                                    try self.addDbgInfoTypeReloc(ty); // DW.AT_type,  DW.FORM_ref4
                                    dbg_out.dbg_info.appendSliceAssumeCapacity(name_with_null); // DW.AT_name, DW.FORM_string
                                },
                                else => {},
                            }
                        },
                        .none => {},
                    }
                },
                else => {},
            }
        }

        fn genArg(self: *Self, inst: Air.Inst.Index) !MCValue {
            const arg_index = self.arg_index;
            self.arg_index += 1;

            const ty = self.air.getType(inst);

            const result = self.args[arg_index];
            const mcv = switch (arch) {
                // TODO support stack-only arguments on all target architectures
                .arm, .armeb, .aarch64, .aarch64_32, .aarch64_be => switch (result) {
                    // Copy registers to the stack
                    .register => |reg| blk: {
                        const abi_size = math.cast(u32, ty.abiSize(self.target.*)) catch {
                            return self.fail("type '{}' too big to fit into stack frame", .{ty});
                        };
                        const abi_align = ty.abiAlignment(self.target.*);
                        const stack_offset = try self.allocMem(inst, abi_size, abi_align);
                        try self.genSetStack(ty, stack_offset, MCValue{ .register = reg });

                        break :blk MCValue{ .stack_offset = stack_offset };
                    },
                    else => result,
                },
                else => result,
            };
            try self.genArgDbgInfo(inst, mcv);

            if (self.liveness.isUnused(inst))
                return MCValue.dead;

            switch (mcv) {
                .register => |reg| {
                    self.register_manager.getRegAssumeFree(toCanonicalReg(reg), inst);
                },
                else => {},
            }

            return mcv;
        }

        fn genBreakpoint(self: *Self) !MCValue {
            switch (arch) {
                .i386, .x86_64 => {
                    try self.code.append(0xcc); // int3
                },
                .riscv64 => {
                    mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.ebreak.toU32());
                },
                .arm, .armeb => {
                    writeInt(u32, try self.code.addManyAsArray(4), Instruction.bkpt(0).toU32());
                },
                .aarch64 => {
                    mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.brk(1).toU32());
                },
                else => return self.fail("TODO implement @breakpoint() for {}", .{self.target.cpu.arch}),
            }
            return .none;
        }

        fn genCall(self: *Self, inst: Air.Inst.Index) !MCValue {
            const pl_op = self.air.instruction.items(.data)[inst].pl_op;
            const fn_ty = self.air.getType(pl_op.operand);
            const callee = pl_op.operand;
            const extra = self.air.extraData(Air.Call, inst_data.payload);
            const args = self.air.extra[extra.end..][0..extra.data.args_len];

            var info = try self.resolveCallingConventionValues(fn_ty);
            defer info.deinit(self);

            // Due to incremental compilation, how function calls are generated depends
            // on linking.
            if (self.bin_file.tag == link.File.Elf.base_tag or self.bin_file.tag == link.File.Coff.base_tag) {
                switch (arch) {
                    .x86_64 => {
                        for (info.args) |mc_arg, arg_i| {
                            const arg = args[arg_i];
                            const arg_mcv = try self.resolveInst(args[arg_i]);
                            // Here we do not use setRegOrMem even though the logic is similar, because
                            // the function call will move the stack pointer, so the offsets are different.
                            switch (mc_arg) {
                                .none => continue,
                                .register => |reg| {
                                    try self.register_manager.getReg(reg, null);
                                    try self.genSetReg(arg.ty, reg, arg_mcv);
                                },
                                .stack_offset => |off| {
                                    // Here we need to emit instructions like this:
                                    // mov     qword ptr [rsp + stack_offset], x
                                    try self.genSetStack(arg.ty, off, arg_mcv);
                                },
                                .ptr_stack_offset => {
                                    return self.fail("TODO implement calling with MCValue.ptr_stack_offset arg", .{});
                                },
                                .ptr_embedded_in_code => {
                                    return self.fail("TODO implement calling with MCValue.ptr_embedded_in_code arg", .{});
                                },
                                .undef => unreachable,
                                .immediate => unreachable,
                                .unreach => unreachable,
                                .dead => unreachable,
                                .embedded_in_code => unreachable,
                                .memory => unreachable,
                                .compare_flags_signed => unreachable,
                                .compare_flags_unsigned => unreachable,
                            }
                        }

                        if (self.air.value(callee)) |func_value| {
                            if (func_value.castTag(.function)) |func_payload| {
                                const func = func_payload.data;

                                const ptr_bits = self.target.cpu.arch.ptrBitWidth();
                                const ptr_bytes: u64 = @divExact(ptr_bits, 8);
                                const got_addr = if (self.bin_file.cast(link.File.Elf)) |elf_file| blk: {
                                    const got = &elf_file.program_headers.items[elf_file.phdr_got_index.?];
                                    break :blk @intCast(u32, got.p_vaddr + func.owner_decl.link.elf.offset_table_index * ptr_bytes);
                                } else if (self.bin_file.cast(link.File.Coff)) |coff_file|
                                    @intCast(u32, coff_file.offset_table_virtual_address + func.owner_decl.link.coff.offset_table_index * ptr_bytes)
                                else
                                    unreachable;

                                // ff 14 25 xx xx xx xx    call [addr]
                                try self.code.ensureCapacity(self.code.items.len + 7);
                                self.code.appendSliceAssumeCapacity(&[3]u8{ 0xff, 0x14, 0x25 });
                                mem.writeIntLittle(u32, self.code.addManyAsArrayAssumeCapacity(4), got_addr);
                            } else if (func_value.castTag(.extern_fn)) |_| {
                                return self.fail("TODO implement calling extern functions", .{});
                            } else {
                                return self.fail("TODO implement calling bitcasted functions", .{});
                            }
                        } else {
                            return self.fail("TODO implement calling runtime known function pointer", .{});
                        }
                    },
                    .riscv64 => {
                        if (info.args.len > 0) return self.fail("TODO implement fn args for {}", .{self.target.cpu.arch});

                        if (self.air.value(callee)) |func_value| {
                            if (func_value.castTag(.function)) |func_payload| {
                                const func = func_payload.data;

                                const ptr_bits = self.target.cpu.arch.ptrBitWidth();
                                const ptr_bytes: u64 = @divExact(ptr_bits, 8);
                                const got_addr = if (self.bin_file.cast(link.File.Elf)) |elf_file| blk: {
                                    const got = &elf_file.program_headers.items[elf_file.phdr_got_index.?];
                                    break :blk @intCast(u32, got.p_vaddr + func.owner_decl.link.elf.offset_table_index * ptr_bytes);
                                } else if (self.bin_file.cast(link.File.Coff)) |coff_file|
                                    coff_file.offset_table_virtual_address + func.owner_decl.link.coff.offset_table_index * ptr_bytes
                                else
                                    unreachable;

                                try self.genSetReg(Type.initTag(.usize), .ra, .{ .memory = got_addr });
                                mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.jalr(.ra, 0, .ra).toU32());
                            } else if (func_value.castTag(.extern_fn)) |_| {
                                return self.fail("TODO implement calling extern functions", .{});
                            } else {
                                return self.fail("TODO implement calling bitcasted functions", .{});
                            }
                        } else {
                            return self.fail("TODO implement calling runtime known function pointer", .{});
                        }
                    },
                    .arm, .armeb => {
                        for (info.args) |mc_arg, arg_i| {
                            const arg = args[arg_i];
                            const arg_mcv = try self.resolveInst(args[arg_i]);

                            switch (mc_arg) {
                                .none => continue,
                                .undef => unreachable,
                                .immediate => unreachable,
                                .unreach => unreachable,
                                .dead => unreachable,
                                .embedded_in_code => unreachable,
                                .memory => unreachable,
                                .compare_flags_signed => unreachable,
                                .compare_flags_unsigned => unreachable,
                                .register => |reg| {
                                    try self.register_manager.getReg(reg, null);
                                    try self.genSetReg(arg.ty, reg, arg_mcv);
                                },
                                .stack_offset => {
                                    return self.fail("TODO implement calling with parameters in memory", .{});
                                },
                                .ptr_stack_offset => {
                                    return self.fail("TODO implement calling with MCValue.ptr_stack_offset arg", .{});
                                },
                                .ptr_embedded_in_code => {
                                    return self.fail("TODO implement calling with MCValue.ptr_embedded_in_code arg", .{});
                                },
                            }
                        }

                        if (self.air.value(callee)) |func_value| {
                            if (func_value.castTag(.function)) |func_payload| {
                                const func = func_payload.data;
                                const ptr_bits = self.target.cpu.arch.ptrBitWidth();
                                const ptr_bytes: u64 = @divExact(ptr_bits, 8);
                                const got_addr = if (self.bin_file.cast(link.File.Elf)) |elf_file| blk: {
                                    const got = &elf_file.program_headers.items[elf_file.phdr_got_index.?];
                                    break :blk @intCast(u32, got.p_vaddr + func.owner_decl.link.elf.offset_table_index * ptr_bytes);
                                } else if (self.bin_file.cast(link.File.Coff)) |coff_file|
                                    coff_file.offset_table_virtual_address + func.owner_decl.link.coff.offset_table_index * ptr_bytes
                                else
                                    unreachable;

                                try self.genSetReg(Type.initTag(.usize), .lr, .{ .memory = got_addr });

                                // TODO: add Instruction.supportedOn
                                // function for ARM
                                if (Target.arm.featureSetHas(self.target.cpu.features, .has_v5t)) {
                                    writeInt(u32, try self.code.addManyAsArray(4), Instruction.blx(.al, .lr).toU32());
                                } else {
                                    writeInt(u32, try self.code.addManyAsArray(4), Instruction.mov(.al, .lr, Instruction.Operand.reg(.pc, Instruction.Operand.Shift.none)).toU32());
                                    writeInt(u32, try self.code.addManyAsArray(4), Instruction.bx(.al, .lr).toU32());
                                }
                            } else if (func_value.castTag(.extern_fn)) |_| {
                                return self.fail("TODO implement calling extern functions", .{});
                            } else {
                                return self.fail("TODO implement calling bitcasted functions", .{});
                            }
                        } else {
                            return self.fail("TODO implement calling runtime known function pointer", .{});
                        }
                    },
                    .aarch64 => {
                        for (info.args) |mc_arg, arg_i| {
                            const arg = args[arg_i];
                            const arg_mcv = try self.resolveInst(args[arg_i]);

                            switch (mc_arg) {
                                .none => continue,
                                .undef => unreachable,
                                .immediate => unreachable,
                                .unreach => unreachable,
                                .dead => unreachable,
                                .embedded_in_code => unreachable,
                                .memory => unreachable,
                                .compare_flags_signed => unreachable,
                                .compare_flags_unsigned => unreachable,
                                .register => |reg| {
                                    try self.register_manager.getReg(reg, null);
                                    try self.genSetReg(arg.ty, reg, arg_mcv);
                                },
                                .stack_offset => {
                                    return self.fail("TODO implement calling with parameters in memory", .{});
                                },
                                .ptr_stack_offset => {
                                    return self.fail("TODO implement calling with MCValue.ptr_stack_offset arg", .{});
                                },
                                .ptr_embedded_in_code => {
                                    return self.fail("TODO implement calling with MCValue.ptr_embedded_in_code arg", .{});
                                },
                            }
                        }

                        if (self.air.value(callee)) |func_value| {
                            if (func_value.castTag(.function)) |func_payload| {
                                const func = func_payload.data;
                                const ptr_bits = self.target.cpu.arch.ptrBitWidth();
                                const ptr_bytes: u64 = @divExact(ptr_bits, 8);
                                const got_addr = if (self.bin_file.cast(link.File.Elf)) |elf_file| blk: {
                                    const got = &elf_file.program_headers.items[elf_file.phdr_got_index.?];
                                    break :blk @intCast(u32, got.p_vaddr + func.owner_decl.link.elf.offset_table_index * ptr_bytes);
                                } else if (self.bin_file.cast(link.File.Coff)) |coff_file|
                                    coff_file.offset_table_virtual_address + func.owner_decl.link.coff.offset_table_index * ptr_bytes
                                else
                                    unreachable;

                                try self.genSetReg(Type.initTag(.usize), .x30, .{ .memory = got_addr });

                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.blr(.x30).toU32());
                            } else if (func_value.castTag(.extern_fn)) |_| {
                                return self.fail("TODO implement calling extern functions", .{});
                            } else {
                                return self.fail("TODO implement calling bitcasted functions", .{});
                            }
                        } else {
                            return self.fail("TODO implement calling runtime known function pointer", .{});
                        }
                    },
                    else => return self.fail("TODO implement call for {}", .{self.target.cpu.arch}),
                }
            } else if (self.bin_file.cast(link.File.MachO)) |macho_file| {
                for (info.args) |mc_arg, arg_i| {
                    const arg = args[arg_i];
                    const arg_mcv = try self.resolveInst(args[arg_i]);
                    // Here we do not use setRegOrMem even though the logic is similar, because
                    // the function call will move the stack pointer, so the offsets are different.
                    switch (mc_arg) {
                        .none => continue,
                        .register => |reg| {
                            // TODO prevent this macho if block to be generated for all archs
                            switch (arch) {
                                .x86_64, .aarch64 => try self.register_manager.getReg(reg, null),
                                else => unreachable,
                            }
                            try self.genSetReg(arg.ty, reg, arg_mcv);
                        },
                        .stack_offset => {
                            // Here we need to emit instructions like this:
                            // mov     qword ptr [rsp + stack_offset], x
                            return self.fail("TODO implement calling with parameters in memory", .{});
                        },
                        .ptr_stack_offset => {
                            return self.fail("TODO implement calling with MCValue.ptr_stack_offset arg", .{});
                        },
                        .ptr_embedded_in_code => {
                            return self.fail("TODO implement calling with MCValue.ptr_embedded_in_code arg", .{});
                        },
                        .undef => unreachable,
                        .immediate => unreachable,
                        .unreach => unreachable,
                        .dead => unreachable,
                        .embedded_in_code => unreachable,
                        .memory => unreachable,
                        .compare_flags_signed => unreachable,
                        .compare_flags_unsigned => unreachable,
                    }
                }

                if (self.air.value(callee)) |func_value| {
                    if (func_value.castTag(.function)) |func_payload| {
                        const func = func_payload.data;
                        const got_addr = blk: {
                            const seg = macho_file.load_commands.items[macho_file.data_const_segment_cmd_index.?].Segment;
                            const got = seg.sections.items[macho_file.got_section_index.?];
                            break :blk got.addr + func.owner_decl.link.macho.offset_table_index * @sizeOf(u64);
                        };
                        log.debug("got_addr = 0x{x}", .{got_addr});
                        switch (arch) {
                            .x86_64 => {
                                try self.genSetReg(Type.initTag(.u64), .rax, .{ .memory = got_addr });
                                // callq *%rax
                                try self.code.ensureCapacity(self.code.items.len + 2);
                                self.code.appendSliceAssumeCapacity(&[2]u8{ 0xff, 0xd0 });
                            },
                            .aarch64 => {
                                try self.genSetReg(Type.initTag(.u64), .x30, .{ .memory = got_addr });
                                // blr x30
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.blr(.x30).toU32());
                            },
                            else => unreachable, // unsupported architecture on MachO
                        }
                    } else if (func_value.castTag(.extern_fn)) |func_payload| {
                        const decl = func_payload.data;
                        const decl_name = try std.fmt.allocPrint(self.bin_file.allocator, "_{s}", .{decl.name});
                        defer self.bin_file.allocator.free(decl_name);
                        const already_defined = macho_file.lazy_imports.contains(decl_name);
                        const symbol: u32 = if (macho_file.lazy_imports.getIndex(decl_name)) |index|
                            @intCast(u32, index)
                        else
                            try macho_file.addExternSymbol(decl_name);
                        const start = self.code.items.len;
                        const len: usize = blk: {
                            switch (arch) {
                                .x86_64 => {
                                    // callq
                                    try self.code.ensureCapacity(self.code.items.len + 5);
                                    self.code.appendSliceAssumeCapacity(&[5]u8{ 0xe8, 0x0, 0x0, 0x0, 0x0 });
                                    break :blk 5;
                                },
                                .aarch64 => {
                                    // bl
                                    writeInt(u32, try self.code.addManyAsArray(4), 0);
                                    break :blk 4;
                                },
                                else => unreachable, // unsupported architecture on MachO
                            }
                        };
                        try macho_file.stub_fixups.append(self.bin_file.allocator, .{
                            .symbol = symbol,
                            .already_defined = already_defined,
                            .start = start,
                            .len = len,
                        });
                        // We mark the space and fix it up later.
                    } else {
                        return self.fail("TODO implement calling bitcasted functions", .{});
                    }
                } else {
                    return self.fail("TODO implement calling runtime known function pointer", .{});
                }
            } else if (self.bin_file.cast(link.File.Plan9)) |p9| {
                switch (arch) {
                    .x86_64 => {
                        for (info.args) |mc_arg, arg_i| {
                            const arg = args[arg_i];
                            const arg_mcv = try self.resolveInst(args[arg_i]);
                            // Here we do not use setRegOrMem even though the logic is similar, because
                            // the function call will move the stack pointer, so the offsets are different.
                            switch (mc_arg) {
                                .none => continue,
                                .register => |reg| {
                                    try self.register_manager.getReg(reg, null);
                                    try self.genSetReg(arg.ty, reg, arg_mcv);
                                },
                                .stack_offset => {
                                    // Here we need to emit instructions like this:
                                    // mov     qword ptr [rsp + stack_offset], x
                                    return self.fail("TODO implement calling with parameters in memory", .{});
                                },
                                .ptr_stack_offset => {
                                    return self.fail("TODO implement calling with MCValue.ptr_stack_offset arg", .{});
                                },
                                .ptr_embedded_in_code => {
                                    return self.fail("TODO implement calling with MCValue.ptr_embedded_in_code arg", .{});
                                },
                                .undef => unreachable,
                                .immediate => unreachable,
                                .unreach => unreachable,
                                .dead => unreachable,
                                .embedded_in_code => unreachable,
                                .memory => unreachable,
                                .compare_flags_signed => unreachable,
                                .compare_flags_unsigned => unreachable,
                            }
                        }
                        if (self.air.value(callee)) |func_value| {
                            if (func_value.castTag(.function)) |func_payload| {
                                const ptr_bits = self.target.cpu.arch.ptrBitWidth();
                                const ptr_bytes: u64 = @divExact(ptr_bits, 8);
                                const got_addr = p9.bases.data;
                                const got_index = func_payload.data.owner_decl.link.plan9.got_index.?;
                                // ff 14 25 xx xx xx xx    call [addr]
                                try self.code.ensureCapacity(self.code.items.len + 7);
                                self.code.appendSliceAssumeCapacity(&[3]u8{ 0xff, 0x14, 0x25 });
                                const fn_got_addr = got_addr + got_index * ptr_bytes;
                                mem.writeIntLittle(u32, self.code.addManyAsArrayAssumeCapacity(4), @intCast(u32, fn_got_addr));
                            } else return self.fail("TODO implement calling extern fn on plan9", .{});
                        } else {
                            return self.fail("TODO implement calling runtime known function pointer", .{});
                        }
                    },
                    .aarch64 => {
                        for (info.args) |mc_arg, arg_i| {
                            const arg = inst.args[arg_i];
                            const arg_mcv = try self.resolveInst(inst.args[arg_i]);

                            switch (mc_arg) {
                                .none => continue,
                                .undef => unreachable,
                                .immediate => unreachable,
                                .unreach => unreachable,
                                .dead => unreachable,
                                .embedded_in_code => unreachable,
                                .memory => unreachable,
                                .compare_flags_signed => unreachable,
                                .compare_flags_unsigned => unreachable,
                                .register => |reg| {
                                    try self.register_manager.getReg(reg, null);
                                    try self.genSetReg(arg.src, arg.ty, reg, arg_mcv);
                                },
                                .stack_offset => {
                                    return self.fail("TODO implement calling with parameters in memory", .{});
                                },
                                .ptr_stack_offset => {
                                    return self.fail("TODO implement calling with MCValue.ptr_stack_offset arg", .{});
                                },
                                .ptr_embedded_in_code => {
                                    return self.fail("TODO implement calling with MCValue.ptr_embedded_in_code arg", .{});
                                },
                            }
                        }
                        if (inst.func.value()) |func_value| {
                            if (func_value.castTag(.function)) |func_payload| {
                                const ptr_bits = self.target.cpu.arch.ptrBitWidth();
                                const ptr_bytes: u64 = @divExact(ptr_bits, 8);
                                const got_addr = p9.bases.data;
                                const got_index = func_payload.data.owner_decl.link.plan9.got_index.?;
                                const fn_got_addr = got_addr + got_index * ptr_bytes;

                                try self.genSetReg(inst.base.src, Type.initTag(.usize), .x30, .{ .memory = fn_got_addr });

                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.blr(.x30).toU32());
                            } else if (func_value.castTag(.extern_fn)) |_| {
                                return self.fail("TODO implement calling extern functions", .{});
                            } else {
                                return self.fail("TODO implement calling bitcasted functions", .{});
                            }
                        } else {
                            return self.fail("TODO implement calling runtime known function pointer", .{});
                        }
                    },
                    else => return self.fail("TODO implement call on plan9 for {}", .{self.target.cpu.arch}),
                }
            } else unreachable;

            switch (info.return_value) {
                .register => |reg| {
                    if (Register.allocIndex(reg) == null) {
                        // Save function return value in a callee saved register
                        return try self.copyToNewRegister(inst, info.return_value);
                    }
                },
                else => {},
            }

            return info.return_value;
        }

        fn genRef(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const ty_op = self.air.instructions.items(.data)[inst].ty_op;
            const operand_ty = self.air.getType(ty_op.operand);
            const operand = try self.resolveInst(ty_op.operand);
            switch (operand) {
                .unreach => unreachable,
                .dead => unreachable,
                .none => return .none,

                .immediate,
                .register,
                .ptr_stack_offset,
                .ptr_embedded_in_code,
                .compare_flags_unsigned,
                .compare_flags_signed,
                => {
                    const stack_offset = try self.allocMemPtr(inst);
                    try self.genSetStack(operand_ty, stack_offset, operand);
                    return MCValue{ .ptr_stack_offset = stack_offset };
                },

                .stack_offset => |offset| return MCValue{ .ptr_stack_offset = offset },
                .embedded_in_code => |offset| return MCValue{ .ptr_embedded_in_code = offset },
                .memory => |vaddr| return MCValue{ .immediate = vaddr },

                .undef => return self.fail("TODO implement ref on an undefined value", .{}),
            }
        }

        fn ret(self: *Self, mcv: MCValue) !MCValue {
            const ret_ty = self.fn_type.fnReturnType();
            try self.setRegOrMem(ret_ty, self.ret_mcv, mcv);
            switch (arch) {
                .i386 => {
                    try self.code.append(0xc3); // ret
                },
                .x86_64 => {
                    // TODO when implementing defer, this will need to jump to the appropriate defer expression.
                    // TODO optimization opportunity: figure out when we can emit this as a 2 byte instruction
                    // which is available if the jump is 127 bytes or less forward.
                    try self.code.resize(self.code.items.len + 5);
                    self.code.items[self.code.items.len - 5] = 0xe9; // jmp rel32
                    try self.exitlude_jump_relocs.append(self.gpa, self.code.items.len - 4);
                },
                .riscv64 => {
                    mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.jalr(.zero, 0, .ra).toU32());
                },
                .arm, .armeb => {
                    // Just add space for an instruction, patch this later
                    try self.code.resize(self.code.items.len + 4);
                    try self.exitlude_jump_relocs.append(self.gpa, self.code.items.len - 4);
                },
                .aarch64 => {
                    // Just add space for an instruction, patch this later
                    try self.code.resize(self.code.items.len + 4);
                    try self.exitlude_jump_relocs.append(self.gpa, self.code.items.len - 4);
                },
                else => return self.fail("TODO implement return for {}", .{self.target.cpu.arch}),
            }
            return .unreach;
        }

        fn genRet(self: *Self, inst: Air.Inst.Index) !MCValue {
            const operand = try self.resolveInst(self.air.instructions.items(.data)[inst].un_op);
            return self.ret(inst.base.src, operand);
        }

        fn genCmp(self: *Self, inst: Air.Inst.Index, op: math.CompareOperator) !MCValue {
            // No side effects, so if it's unreferenced, do nothing.
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            const ty = self.air.getType(bin_op.lhs);
            assert(ty.eql(self.air.getType(bin_op.rhs)));
            if (ty.zigTypeTag() == .ErrorSet)
                return self.fail("TODO implement cmp for errors", .{});

            const lhs = try self.resolveInst(bin_op.lhs);
            const rhs = try self.resolveInst(bin_op.rhs);
            switch (arch) {
                .x86_64 => {
                    try self.code.ensureCapacity(self.code.items.len + 8);

                    // There are 2 operands, destination and source.
                    // Either one, but not both, can be a memory operand.
                    // Source operand can be an immediate, 8 bits or 32 bits.
                    const dst_mcv = if (lhs.isImmediate() or (lhs.isMemory() and rhs.isMemory()))
                        try self.copyToNewRegister(inst, lhs)
                    else
                        lhs;
                    // This instruction supports only signed 32-bit immediates at most.
                    const src_mcv = try self.limitImmediateType(bin_op.rhs, i32);

                    try self.genX8664BinMathCode(Type.initTag(.bool), dst_mcv, src_mcv, 7, 0x38);
                    const info = ty.intInfo(self.target.*);
                    return switch (info.signedness) {
                        .signed => MCValue{ .compare_flags_signed = op },
                        .unsigned => MCValue{ .compare_flags_unsigned = op },
                    };
                },
                .arm, .armeb => {
                    const lhs_is_register = lhs == .register;
                    const rhs_is_register = rhs == .register;
                    // lhs should always be a register
                    const rhs_should_be_register = try self.armOperandShouldBeRegister(rhs);

                    var lhs_mcv = lhs;
                    var rhs_mcv = rhs;

                    // Allocate registers
                    if (rhs_should_be_register) {
                        if (!lhs_is_register and !rhs_is_register) {
                            const regs = try self.register_manager.allocRegs(2, .{ bin_op.rhs, bin_op.lhs }, &.{});
                            lhs_mcv = MCValue{ .register = regs[0] };
                            rhs_mcv = MCValue{ .register = regs[1] };
                        } else if (!rhs_is_register) {
                            rhs_mcv = MCValue{ .register = try self.register_manager.allocReg(bin_op.rhs, &.{}) };
                        }
                    }
                    if (!lhs_is_register) {
                        lhs_mcv = MCValue{ .register = try self.register_manager.allocReg(bin_op.lhs, &.{}) };
                    }

                    // Move the operands to the newly allocated registers
                    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
                    if (lhs_mcv == .register and !lhs_is_register) {
                        try self.genSetReg(ty, lhs_mcv.register, lhs);
                        branch.inst_table.putAssumeCapacity(bin_op.lhs, lhs);
                    }
                    if (rhs_mcv == .register and !rhs_is_register) {
                        try self.genSetReg(ty, rhs_mcv.register, rhs);
                        branch.inst_table.putAssumeCapacity(bin_op.rhs, rhs);
                    }

                    // The destination register is not present in the cmp instruction
                    try self.genArmBinOpCode(undefined, lhs_mcv, rhs_mcv, false, .cmp_eq);

                    const info = ty.intInfo(self.target.*);
                    return switch (info.signedness) {
                        .signed => MCValue{ .compare_flags_signed = op },
                        .unsigned => MCValue{ .compare_flags_unsigned = op },
                    };
                },
                else => return self.fail("TODO implement cmp for {}", .{self.target.cpu.arch}),
            }
        }

        fn genDbgStmt(self: *Self, inst: Air.Inst.Index) !MCValue {
            const dbg_stmt = self.air.instructions.items(.data)[inst].dbg_stmt;
            try self.dbgAdvancePCAndLine(dbg_stmt.line, dbg_stmt.column);
            assert(self.liveness.isUnused(inst));
            return MCValue.dead;
        }

        fn genCondBr(self: *Self, inst: Air.Inst.Index) !MCValue {
            const pl_op = self.air.instructions.items(.data)[inst].pl_op;
            const cond = try self.resolveInst(pl_op.operand);
            const extra = self.air.extraData(Air.CondBr, inst_data.payload);
            const then_body = self.air.extra[extra.end..][0..extra.data.then_body_len];
            const else_body = self.air.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];

            const reloc: Reloc = switch (arch) {
                .i386, .x86_64 => reloc: {
                    try self.code.ensureCapacity(self.code.items.len + 6);

                    const opcode: u8 = switch (cond) {
                        .compare_flags_signed => |cmp_op| blk: {
                            // Here we map to the opposite opcode because the jump is to the false branch.
                            const opcode: u8 = switch (cmp_op) {
                                .gte => 0x8c,
                                .gt => 0x8e,
                                .neq => 0x84,
                                .lt => 0x8d,
                                .lte => 0x8f,
                                .eq => 0x85,
                            };
                            break :blk opcode;
                        },
                        .compare_flags_unsigned => |cmp_op| blk: {
                            // Here we map to the opposite opcode because the jump is to the false branch.
                            const opcode: u8 = switch (cmp_op) {
                                .gte => 0x82,
                                .gt => 0x86,
                                .neq => 0x84,
                                .lt => 0x83,
                                .lte => 0x87,
                                .eq => 0x85,
                            };
                            break :blk opcode;
                        },
                        .register => |reg| blk: {
                            // test reg, 1
                            // TODO detect al, ax, eax
                            const encoder = try X8664Encoder.init(self.code, 4);
                            encoder.rex(.{
                                // TODO audit this codegen: we force w = true here to make
                                // the value affect the big register
                                .w = true,
                                .b = reg.isExtended(),
                            });
                            encoder.opcode_1byte(0xf6);
                            encoder.modRm_direct(
                                0,
                                reg.low_id(),
                            );
                            encoder.disp8(1);
                            break :blk 0x84;
                        },
                        else => return self.fail("TODO implement condbr {s} when condition is {s}", .{ self.target.cpu.arch, @tagName(cond) }),
                    };
                    self.code.appendSliceAssumeCapacity(&[_]u8{ 0x0f, opcode });
                    const reloc = Reloc{ .rel32 = self.code.items.len };
                    self.code.items.len += 4;
                    break :reloc reloc;
                },
                .arm, .armeb => reloc: {
                    const condition: Condition = switch (cond) {
                        .compare_flags_signed => |cmp_op| blk: {
                            // Here we map to the opposite condition because the jump is to the false branch.
                            const condition = Condition.fromCompareOperatorSigned(cmp_op);
                            break :blk condition.negate();
                        },
                        .compare_flags_unsigned => |cmp_op| blk: {
                            // Here we map to the opposite condition because the jump is to the false branch.
                            const condition = Condition.fromCompareOperatorUnsigned(cmp_op);
                            break :blk condition.negate();
                        },
                        .register => |reg| blk: {
                            // cmp reg, 1
                            // bne ...
                            const op = Instruction.Operand.imm(1, 0);
                            writeInt(u32, try self.code.addManyAsArray(4), Instruction.cmp(.al, reg, op).toU32());
                            break :blk .ne;
                        },
                        else => return self.fail("TODO implement condbr {} when condition is {s}", .{ self.target.cpu.arch, @tagName(cond) }),
                    };

                    const reloc = Reloc{
                        .arm_branch = .{
                            .pos = self.code.items.len,
                            .cond = condition,
                        },
                    };
                    try self.code.resize(self.code.items.len + 4);
                    break :reloc reloc;
                },
                else => return self.fail("TODO implement condbr {}", .{self.target.cpu.arch}),
            };

            // Capture the state of register and stack allocation state so that we can revert to it.
            const parent_next_stack_offset = self.next_stack_offset;
            const parent_free_registers = self.register_manager.free_registers;
            var parent_stack = try self.stack.clone(self.gpa);
            defer parent_stack.deinit(self.gpa);
            const parent_registers = self.register_manager.registers;

            try self.branch_stack.append(.{});

            const then_deaths = self.liveness.thenDeaths(inst);
            try self.ensureProcessDeathCapacity(then_deaths.len);
            for (then_deaths) |operand| {
                self.processDeath(operand);
            }
            try self.genBody(then_body);

            // Revert to the previous register and stack allocation state.

            var saved_then_branch = self.branch_stack.pop();
            defer saved_then_branch.deinit(self.gpa);

            self.register_manager.registers = parent_registers;

            self.stack.deinit(self.gpa);
            self.stack = parent_stack;
            parent_stack = .{};

            self.next_stack_offset = parent_next_stack_offset;
            self.register_manager.free_registers = parent_free_registers;

            try self.performReloc(reloc);
            const else_branch = self.branch_stack.addOneAssumeCapacity();
            else_branch.* = .{};

            const else_deaths = self.liveness.elseDeaths(inst);
            try self.ensureProcessDeathCapacity(else_deaths.len);
            for (else_deaths) |operand| {
                self.processDeath(operand);
            }
            try self.genBody(else_body);

            // At this point, each branch will possibly have conflicting values for where
            // each instruction is stored. They agree, however, on which instructions are alive/dead.
            // We use the first ("then") branch as canonical, and here emit
            // instructions into the second ("else") branch to make it conform.
            // We continue respect the data structure semantic guarantees of the else_branch so
            // that we can use all the code emitting abstractions. This is why at the bottom we
            // assert that parent_branch.free_registers equals the saved_then_branch.free_registers
            // rather than assigning it.
            const parent_branch = &self.branch_stack.items[self.branch_stack.items.len - 2];
            try parent_branch.inst_table.ensureCapacity(self.gpa, parent_branch.inst_table.count() +
                else_branch.inst_table.count());

            const else_slice = else_branch.inst_table.entries.slice();
            const else_keys = else_slice.items(.key);
            const else_values = else_slice.items(.value);
            for (else_keys) |else_key, else_idx| {
                const else_value = else_values[else_idx];
                const canon_mcv = if (saved_then_branch.inst_table.fetchSwapRemove(else_key)) |then_entry| blk: {
                    // The instruction's MCValue is overridden in both branches.
                    parent_branch.inst_table.putAssumeCapacity(else_key, then_entry.value);
                    if (else_value == .dead) {
                        assert(then_entry.value == .dead);
                        continue;
                    }
                    break :blk then_entry.value;
                } else blk: {
                    if (else_value == .dead)
                        continue;
                    // The instruction is only overridden in the else branch.
                    var i: usize = self.branch_stack.items.len - 2;
                    while (true) {
                        i -= 1; // If this overflows, the question is: why wasn't the instruction marked dead?
                        if (self.branch_stack.items[i].inst_table.get(else_key)) |mcv| {
                            assert(mcv != .dead);
                            break :blk mcv;
                        }
                    }
                };
                log.debug("consolidating else_entry {*} {}=>{}", .{ else_key, else_value, canon_mcv });
                // TODO make sure the destination stack offset / register does not already have something
                // going on there.
                try self.setRegOrMem(else_key.ty, canon_mcv, else_value);
                // TODO track the new register / stack allocation
            }
            try parent_branch.inst_table.ensureCapacity(self.gpa, parent_branch.inst_table.count() +
                saved_then_branch.inst_table.count());
            const then_slice = saved_then_branch.inst_table.entries.slice();
            const then_keys = then_slice.items(.key);
            const then_values = then_slice.items(.value);
            for (then_keys) |then_key, then_idx| {
                const then_value = then_values[then_idx];
                // We already deleted the items from this table that matched the else_branch.
                // So these are all instructions that are only overridden in the then branch.
                parent_branch.inst_table.putAssumeCapacity(then_key, then_value);
                if (then_value == .dead)
                    continue;
                const parent_mcv = blk: {
                    var i: usize = self.branch_stack.items.len - 2;
                    while (true) {
                        i -= 1;
                        if (self.branch_stack.items[i].inst_table.get(then_key)) |mcv| {
                            assert(mcv != .dead);
                            break :blk mcv;
                        }
                    }
                };
                log.debug("consolidating then_entry {*} {}=>{}", .{ then_key, parent_mcv, then_value });
                // TODO make sure the destination stack offset / register does not already have something
                // going on there.
                try self.setRegOrMem(then_key.ty, parent_mcv, then_value);
                // TODO track the new register / stack allocation
            }

            self.branch_stack.pop().deinit(self.gpa);

            return MCValue.unreach;
        }

        fn isNull(self: *Self, operand: MCValue) !MCValue {
            _ = operand;
            // Here you can specialize this instruction if it makes sense to, otherwise the default
            // will call isNonNull and invert the result.
            switch (arch) {
                else => return self.fail("TODO call isNonNull and invert the result", .{}),
            }
        }

        fn isNonNull(self: *Self, operand: MCValue) !MCValue {
            _ = operand;
            // Here you can specialize this instruction if it makes sense to, otherwise the default
            // will call isNull and invert the result.
            switch (arch) {
                else => return self.fail("TODO call isNull and invert the result", .{}),
            }
        }

        fn isErr(self: *Self, operand: MCValue) !MCValue {
            _ = operand;
            // Here you can specialize this instruction if it makes sense to, otherwise the default
            // will call isNonNull and invert the result.
            switch (arch) {
                else => return self.fail("TODO call isNonErr and invert the result", .{}),
            }
        }

        fn isNonErr(self: *Self, operand: MCValue) !MCValue {
            _ = operand;
            // Here you can specialize this instruction if it makes sense to, otherwise the default
            // will call isNull and invert the result.
            switch (arch) {
                else => return self.fail("TODO call isErr and invert the result", .{}),
            }
        }

        fn genIsNull(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const un_op = self.air.instructions.items(.data)[inst].un_op;
            const operand = try self.resolveInst(un_op);
            return self.isNull(operand);
        }

        fn genIsNullPtr(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const un_op = self.air.instructions.items(.data)[inst].un_op;
            const operand_ptr = try self.resolveInst(un_op);
            const operand: MCValue = blk: {
                if (self.reuseOperand(inst, 0, operand_ptr)) {
                    // The MCValue that holds the pointer can be re-used as the value.
                    break :blk operand_ptr;
                } else {
                    break :blk try self.allocRegOrMem(inst, true);
                }
            };
            try self.load(operand, ptr);
            return self.isNull(operand);
        }

        fn genIsNonNull(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const un_op = self.air.instructions.items(.data)[inst].un_op;
            const operand = try self.resolveInst(un_op);
            return self.isNonNull(operand);
        }

        fn genIsNonNullPtr(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const un_op = self.air.instructions.items(.data)[inst].un_op;
            const operand_ptr = try self.resolveInst(un_op);
            const operand: MCValue = blk: {
                if (self.reuseOperand(inst, 0, operand_ptr)) {
                    // The MCValue that holds the pointer can be re-used as the value.
                    break :blk operand_ptr;
                } else {
                    break :blk try self.allocRegOrMem(inst, true);
                }
            };
            try self.load(operand, ptr);
            return self.isNonNull(operand);
        }

        fn genIsErr(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const un_op = self.air.instructions.items(.data)[inst].un_op;
            const operand = try self.resolveInst(un_op);
            return self.isErr(operand);
        }

        fn genIsErrPtr(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const un_op = self.air.instructions.items(.data)[inst].un_op;
            const operand_ptr = try self.resolveInst(un_op);
            const operand: MCValue = blk: {
                if (self.reuseOperand(inst, 0, operand_ptr)) {
                    // The MCValue that holds the pointer can be re-used as the value.
                    break :blk operand_ptr;
                } else {
                    break :blk try self.allocRegOrMem(inst, true);
                }
            };
            try self.load(operand, ptr);
            return self.isErr(operand);
        }

        fn genIsNonErr(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const un_op = self.air.instructions.items(.data)[inst].un_op;
            const operand = try self.resolveInst(un_op);
            return self.isNonErr(operand);
        }

        fn genIsNonErrPtr(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const un_op = self.air.instructions.items(.data)[inst].un_op;
            const operand_ptr = try self.resolveInst(un_op);
            const operand: MCValue = blk: {
                if (self.reuseOperand(inst, 0, operand_ptr)) {
                    // The MCValue that holds the pointer can be re-used as the value.
                    break :blk operand_ptr;
                } else {
                    break :blk try self.allocRegOrMem(inst, true);
                }
            };
            try self.load(operand, ptr);
            return self.isNonErr(operand);
        }

        fn genLoop(self: *Self, inst: Air.Inst.Index) !MCValue {
            // A loop is a setup to be able to jump back to the beginning.
            const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
            const loop = self.air.extraData(Air.Block, ty_pl.payload);
            const body = self.air.extra[loop.end..][0..loop.data.body_len];
            const start_index = self.code.items.len;
            try self.genBody(body);
            try self.jump(start_index);
            return MCValue.unreach;
        }

        /// Send control flow to the `index` of `self.code`.
        fn jump(self: *Self, index: usize) !void {
            switch (arch) {
                .i386, .x86_64 => {
                    try self.code.ensureCapacity(self.code.items.len + 5);
                    if (math.cast(i8, @intCast(i32, index) - (@intCast(i32, self.code.items.len + 2)))) |delta| {
                        self.code.appendAssumeCapacity(0xeb); // jmp rel8
                        self.code.appendAssumeCapacity(@bitCast(u8, delta));
                    } else |_| {
                        const delta = @intCast(i32, index) - (@intCast(i32, self.code.items.len + 5));
                        self.code.appendAssumeCapacity(0xe9); // jmp rel32
                        mem.writeIntLittle(i32, self.code.addManyAsArrayAssumeCapacity(4), delta);
                    }
                },
                .arm, .armeb => {
                    if (math.cast(i26, @intCast(i32, index) - @intCast(i32, self.code.items.len + 8))) |delta| {
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.b(.al, delta).toU32());
                    } else |_| {
                        return self.fail("TODO: enable larger branch offset", .{});
                    }
                },
                .aarch64, .aarch64_be, .aarch64_32 => {
                    if (math.cast(i28, @intCast(i32, index) - @intCast(i32, self.code.items.len + 8))) |delta| {
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.b(delta).toU32());
                    } else |_| {
                        return self.fail("TODO: enable larger branch offset", .{});
                    }
                },
                else => return self.fail("TODO implement jump for {}", .{self.target.cpu.arch}),
            }
        }

        fn genBlock(self: *Self, inst: Air.Inst.Index) !MCValue {
            try self.blocks.putNoClobber(self.gpa, inst, .{
                // A block is a setup to be able to jump to the end.
                .relocs = .{},
                // It also acts as a receptical for break operands.
                // Here we use `MCValue.none` to represent a null value so that the first
                // break instruction will choose a MCValue for the block result and overwrite
                // this field. Following break instructions will use that MCValue to put their
                // block results.
                .mcv = MCValue{ .none = {} },
            });
            const block_data = self.blocks.getPtr(inst).?;
            defer block_data.relocs.deinit(self.gpa);

            const ty_pl = self.air.instructions.items(.data).ty_pl;
            const extra = self.air.extraData(Air.Block, ty_pl.payload);
            const body = self.air.extra[extra.end..][0..extra.data.body_len];
            try self.genBody(body);

            for (block_data.relocs.items) |reloc| try self.performReloc(reloc);

            return @bitCast(MCValue, block_data.mcv);
        }

        fn genSwitch(self: *Self, inst: Air.Inst.Index) !MCValue {
            _ = inst;
            switch (arch) {
                else => return self.fail("TODO genSwitch for {}", .{self.target.cpu.arch}),
            }
        }

        fn performReloc(self: *Self, reloc: Reloc) !void {
            switch (reloc) {
                .rel32 => |pos| {
                    const amt = self.code.items.len - (pos + 4);
                    // Here it would be tempting to implement testing for amt == 0 and then elide the
                    // jump. However, that will cause a problem because other jumps may assume that they
                    // can jump to this code. Or maybe I didn't understand something when I was debugging.
                    // It could be worth another look. Anyway, that's why that isn't done here. Probably the
                    // best place to elide jumps will be in semantic analysis, by inlining blocks that only
                    // only have 1 break instruction.
                    const s32_amt = math.cast(i32, amt) catch
                        return self.fail("unable to perform relocation: jump too far", .{});
                    mem.writeIntLittle(i32, self.code.items[pos..][0..4], s32_amt);
                },
                .arm_branch => |info| {
                    switch (arch) {
                        .arm, .armeb => {
                            const amt = @intCast(i32, self.code.items.len) - @intCast(i32, info.pos + 8);
                            if (math.cast(i26, amt)) |delta| {
                                writeInt(u32, self.code.items[info.pos..][0..4], Instruction.b(info.cond, delta).toU32());
                            } else |_| {
                                return self.fail("TODO: enable larger branch offset", .{});
                            }
                        },
                        else => unreachable, // attempting to perfrom an ARM relocation on a non-ARM target arch
                    }
                },
            }
        }

        fn genBrBlockFlat(self: *Self, inst: Air.Inst.Index) !MCValue {
            try self.genBody(inst.body);
            const last = inst.body.instructions[inst.body.instructions.len - 1];
            return self.br(inst.block, last);
        }

        fn genBr(self: *Self, inst: Air.Inst.Index) !MCValue {
            return self.br(inst.block, inst.operand);
        }

        fn genBoolOp(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (self.liveness.isUnused(inst))
                return MCValue.dead;
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            const air_tags = self.air.instructions.items(.tag);
            switch (arch) {
                .x86_64 => switch (air_tags[inst]) {
                    // lhs AND rhs
                    .bool_and => return try self.genX8664BinMath(inst, bin_op.lhs, bin_op.rhs),
                    // lhs OR rhs
                    .bool_or => return try self.genX8664BinMath(inst, bin_op.lhs, bin_op.rhs),
                    else => unreachable, // Not a boolean operation
                },
                .arm, .armeb => switch (air_tags[inst]) {
                    .bool_and => return try self.genArmBinOp(inst, bin_op.lhs, bin_op.rhs, .bool_and),
                    .bool_or => return try self.genArmBinOp(inst, bin_op.lhs, bin_op.rhs, .bool_or),
                    else => unreachable, // Not a boolean operation
                },
                else => return self.fail("TODO implement boolean operations for {}", .{self.target.cpu.arch}),
            }
        }

        fn br(self: *Self, block: Air.Inst.Index, operand: Air.Inst.Index) !MCValue {
            const block_data = self.blocks.getPtr(block).?;

            if (operand.ty.hasCodeGenBits()) {
                const operand_mcv = try self.resolveInst(operand);
                const block_mcv = block_data.mcv;
                if (block_mcv == .none) {
                    block_data.mcv = operand_mcv;
                } else {
                    try self.setRegOrMem(block.base.ty, block_mcv, operand_mcv);
                }
            }
            return self.brVoid(block);
        }

        fn brVoid(self: *Self, block: Air.Inst.Index) !MCValue {
            const block_data = self.blocks.getPtr(block).?;

            // Emit a jump with a relocation. It will be patched up after the block ends.
            try block_data.relocs.ensureCapacity(self.gpa, block_data.relocs.items.len + 1);

            switch (arch) {
                .i386, .x86_64 => {
                    // TODO optimization opportunity: figure out when we can emit this as a 2 byte instruction
                    // which is available if the jump is 127 bytes or less forward.
                    try self.code.resize(self.code.items.len + 5);
                    self.code.items[self.code.items.len - 5] = 0xe9; // jmp rel32
                    // Leave the jump offset undefined
                    block_data.relocs.appendAssumeCapacity(.{ .rel32 = self.code.items.len - 4 });
                },
                .arm, .armeb => {
                    try self.code.resize(self.code.items.len + 4);
                    block_data.relocs.appendAssumeCapacity(.{
                        .arm_branch = .{
                            .pos = self.code.items.len - 4,
                            .cond = .al,
                        },
                    });
                },
                else => return self.fail("TODO implement brvoid for {}", .{self.target.cpu.arch}),
            }
            return .none;
        }

        fn genAsm(self: *Self, inst: Air.Inst.Index) !MCValue {
            if (!inst.is_volatile and self.liveness.isUnused(inst))
                return MCValue.dead;
            switch (arch) {
                .arm, .armeb => {
                    for (inst.inputs) |input, i| {
                        if (input.len < 3 or input[0] != '{' or input[input.len - 1] != '}') {
                            return self.fail("unrecognized asm input constraint: '{s}'", .{input});
                        }
                        const reg_name = input[1 .. input.len - 1];
                        const reg = parseRegName(reg_name) orelse
                            return self.fail("unrecognized register: '{s}'", .{reg_name});

                        const arg = inst.args[i];
                        const arg_mcv = try self.resolveInst(arg);
                        try self.register_manager.getReg(reg, null);
                        try self.genSetReg(arg.ty, reg, arg_mcv);
                    }

                    if (mem.eql(u8, inst.asm_source, "svc #0")) {
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.svc(.al, 0).toU32());
                    } else {
                        return self.fail("TODO implement support for more arm assembly instructions", .{});
                    }

                    if (inst.output_constraint) |output| {
                        if (output.len < 4 or output[0] != '=' or output[1] != '{' or output[output.len - 1] != '}') {
                            return self.fail("unrecognized asm output constraint: '{s}'", .{output});
                        }
                        const reg_name = output[2 .. output.len - 1];
                        const reg = parseRegName(reg_name) orelse
                            return self.fail("unrecognized register: '{s}'", .{reg_name});
                        return MCValue{ .register = reg };
                    } else {
                        return MCValue.none;
                    }
                },
                .aarch64 => {
                    for (inst.inputs) |input, i| {
                        if (input.len < 3 or input[0] != '{' or input[input.len - 1] != '}') {
                            return self.fail("unrecognized asm input constraint: '{s}'", .{input});
                        }
                        const reg_name = input[1 .. input.len - 1];
                        const reg = parseRegName(reg_name) orelse
                            return self.fail("unrecognized register: '{s}'", .{reg_name});

                        const arg = inst.args[i];
                        const arg_mcv = try self.resolveInst(arg);
                        try self.register_manager.getReg(reg, null);
                        try self.genSetReg(arg.ty, reg, arg_mcv);
                    }

                    if (mem.eql(u8, inst.asm_source, "svc #0")) {
                        mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.svc(0x0).toU32());
                    } else if (mem.eql(u8, inst.asm_source, "svc #0x80")) {
                        mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.svc(0x80).toU32());
                    } else {
                        return self.fail("TODO implement support for more aarch64 assembly instructions", .{});
                    }

                    if (inst.output_constraint) |output| {
                        if (output.len < 4 or output[0] != '=' or output[1] != '{' or output[output.len - 1] != '}') {
                            return self.fail("unrecognized asm output constraint: '{s}'", .{output});
                        }
                        const reg_name = output[2 .. output.len - 1];
                        const reg = parseRegName(reg_name) orelse
                            return self.fail("unrecognized register: '{s}'", .{reg_name});
                        return MCValue{ .register = reg };
                    } else {
                        return MCValue.none;
                    }
                },
                .riscv64 => {
                    for (inst.inputs) |input, i| {
                        if (input.len < 3 or input[0] != '{' or input[input.len - 1] != '}') {
                            return self.fail("unrecognized asm input constraint: '{s}'", .{input});
                        }
                        const reg_name = input[1 .. input.len - 1];
                        const reg = parseRegName(reg_name) orelse
                            return self.fail("unrecognized register: '{s}'", .{reg_name});

                        const arg = inst.args[i];
                        const arg_mcv = try self.resolveInst(arg);
                        try self.register_manager.getReg(reg, null);
                        try self.genSetReg(arg.ty, reg, arg_mcv);
                    }

                    if (mem.eql(u8, inst.asm_source, "ecall")) {
                        mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.ecall.toU32());
                    } else {
                        return self.fail("TODO implement support for more riscv64 assembly instructions", .{});
                    }

                    if (inst.output_constraint) |output| {
                        if (output.len < 4 or output[0] != '=' or output[1] != '{' or output[output.len - 1] != '}') {
                            return self.fail("unrecognized asm output constraint: '{s}'", .{output});
                        }
                        const reg_name = output[2 .. output.len - 1];
                        const reg = parseRegName(reg_name) orelse
                            return self.fail("unrecognized register: '{s}'", .{reg_name});
                        return MCValue{ .register = reg };
                    } else {
                        return MCValue.none;
                    }
                },
                .x86_64, .i386 => {
                    for (inst.inputs) |input, i| {
                        if (input.len < 3 or input[0] != '{' or input[input.len - 1] != '}') {
                            return self.fail("unrecognized asm input constraint: '{s}'", .{input});
                        }
                        const reg_name = input[1 .. input.len - 1];
                        const reg = parseRegName(reg_name) orelse
                            return self.fail("unrecognized register: '{s}'", .{reg_name});

                        const arg = inst.args[i];
                        const arg_mcv = try self.resolveInst(arg);
                        try self.register_manager.getReg(reg, null);
                        try self.genSetReg(arg.ty, reg, arg_mcv);
                    }

                    {
                        var iter = std.mem.tokenize(inst.asm_source, "\n\r");
                        while (iter.next()) |ins| {
                            if (mem.eql(u8, ins, "syscall")) {
                                try self.code.appendSlice(&[_]u8{ 0x0f, 0x05 });
                            } else if (mem.indexOf(u8, ins, "push")) |_| {
                                const arg = ins[4..];
                                if (mem.indexOf(u8, arg, "$")) |l| {
                                    const n = std.fmt.parseInt(u8, ins[4 + l + 1 ..], 10) catch return self.fail("TODO implement more inline asm int parsing", .{});
                                    try self.code.appendSlice(&.{ 0x6a, n });
                                } else if (mem.indexOf(u8, arg, "%%")) |l| {
                                    const reg_name = ins[4 + l + 2 ..];
                                    const reg = parseRegName(reg_name) orelse
                                        return self.fail("unrecognized register: '{s}'", .{reg_name});
                                    const low_id: u8 = reg.low_id();
                                    if (reg.isExtended()) {
                                        try self.code.appendSlice(&.{ 0x41, 0b1010000 | low_id });
                                    } else {
                                        try self.code.append(0b1010000 | low_id);
                                    }
                                } else return self.fail("TODO more push operands", .{});
                            } else if (mem.indexOf(u8, ins, "pop")) |_| {
                                const arg = ins[3..];
                                if (mem.indexOf(u8, arg, "%%")) |l| {
                                    const reg_name = ins[3 + l + 2 ..];
                                    const reg = parseRegName(reg_name) orelse
                                        return self.fail("unrecognized register: '{s}'", .{reg_name});
                                    const low_id: u8 = reg.low_id();
                                    if (reg.isExtended()) {
                                        try self.code.appendSlice(&.{ 0x41, 0b1011000 | low_id });
                                    } else {
                                        try self.code.append(0b1011000 | low_id);
                                    }
                                } else return self.fail("TODO more pop operands", .{});
                            } else {
                                return self.fail("TODO implement support for more x86 assembly instructions", .{});
                            }
                        }
                    }

                    if (inst.output_constraint) |output| {
                        if (output.len < 4 or output[0] != '=' or output[1] != '{' or output[output.len - 1] != '}') {
                            return self.fail("unrecognized asm output constraint: '{s}'", .{output});
                        }
                        const reg_name = output[2 .. output.len - 1];
                        const reg = parseRegName(reg_name) orelse
                            return self.fail("unrecognized register: '{s}'", .{reg_name});
                        return MCValue{ .register = reg };
                    } else {
                        return MCValue.none;
                    }
                },
                else => return self.fail("TODO implement inline asm support for more architectures", .{}),
            }
        }

        /// Sets the value without any modifications to register allocation metadata or stack allocation metadata.
        fn setRegOrMem(self: *Self, ty: Type, loc: MCValue, val: MCValue) !void {
            switch (loc) {
                .none => return,
                .register => |reg| return self.genSetReg(ty, reg, val),
                .stack_offset => |off| return self.genSetStack(ty, off, val),
                .memory => {
                    return self.fail("TODO implement setRegOrMem for memory", .{});
                },
                else => unreachable,
            }
        }

        fn genSetStack(self: *Self, ty: Type, stack_offset: u32, mcv: MCValue) InnerError!void {
            switch (arch) {
                .arm, .armeb => switch (mcv) {
                    .dead => unreachable,
                    .ptr_stack_offset => unreachable,
                    .ptr_embedded_in_code => unreachable,
                    .unreach, .none => return, // Nothing to do.
                    .undef => {
                        if (!self.wantSafety())
                            return; // The already existing value will do just fine.
                        // TODO Upgrade this to a memset call when we have that available.
                        switch (ty.abiSize(self.target.*)) {
                            1 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaa }),
                            2 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaa }),
                            4 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaaaaaa }),
                            8 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaaaaaaaaaaaaaa }),
                            else => return self.fail("TODO implement memset", .{}),
                        }
                    },
                    .compare_flags_unsigned => |op| {
                        _ = op;
                        return self.fail("TODO implement set stack variable with compare flags value (unsigned)", .{});
                    },
                    .compare_flags_signed => |op| {
                        _ = op;
                        return self.fail("TODO implement set stack variable with compare flags value (signed)", .{});
                    },
                    .immediate => {
                        const reg = try self.copyToTmpRegister(ty, mcv);
                        return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
                    },
                    .embedded_in_code => |code_offset| {
                        _ = code_offset;
                        return self.fail("TODO implement set stack variable from embedded_in_code", .{});
                    },
                    .register => |reg| {
                        const abi_size = ty.abiSize(self.target.*);
                        const adj_off = stack_offset + abi_size;

                        switch (abi_size) {
                            1, 4 => {
                                const offset = if (math.cast(u12, adj_off)) |imm| blk: {
                                    break :blk Instruction.Offset.imm(imm);
                                } else |_| Instruction.Offset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }), 0);
                                const str = switch (abi_size) {
                                    1 => Instruction.strb,
                                    4 => Instruction.str,
                                    else => unreachable,
                                };

                                writeInt(u32, try self.code.addManyAsArray(4), str(.al, reg, .fp, .{
                                    .offset = offset,
                                    .positive = false,
                                }).toU32());
                            },
                            2 => {
                                const offset = if (adj_off <= math.maxInt(u8)) blk: {
                                    break :blk Instruction.ExtraLoadStoreOffset.imm(@intCast(u8, adj_off));
                                } else Instruction.ExtraLoadStoreOffset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }));

                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.strh(.al, reg, .fp, .{
                                    .offset = offset,
                                    .positive = false,
                                }).toU32());
                            },
                            else => return self.fail("TODO implement storing other types abi_size={}", .{abi_size}),
                        }
                    },
                    .memory => |vaddr| {
                        _ = vaddr;
                        return self.fail("TODO implement set stack variable from memory vaddr", .{});
                    },
                    .stack_offset => |off| {
                        if (stack_offset == off)
                            return; // Copy stack variable to itself; nothing to do.

                        const reg = try self.copyToTmpRegister(ty, mcv);
                        return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
                    },
                },
                .x86_64 => switch (mcv) {
                    .dead => unreachable,
                    .ptr_stack_offset => unreachable,
                    .ptr_embedded_in_code => unreachable,
                    .unreach, .none => return, // Nothing to do.
                    .undef => {
                        if (!self.wantSafety())
                            return; // The already existing value will do just fine.
                        // TODO Upgrade this to a memset call when we have that available.
                        switch (ty.abiSize(self.target.*)) {
                            1 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaa }),
                            2 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaa }),
                            4 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaaaaaa }),
                            8 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaaaaaaaaaaaaaa }),
                            else => return self.fail("TODO implement memset", .{}),
                        }
                    },
                    .compare_flags_unsigned => |op| {
                        _ = op;
                        return self.fail("TODO implement set stack variable with compare flags value (unsigned)", .{});
                    },
                    .compare_flags_signed => |op| {
                        _ = op;
                        return self.fail("TODO implement set stack variable with compare flags value (signed)", .{});
                    },
                    .immediate => |x_big| {
                        const abi_size = ty.abiSize(self.target.*);
                        const adj_off = stack_offset + abi_size;
                        if (adj_off > 128) {
                            return self.fail("TODO implement set stack variable with large stack offset", .{});
                        }
                        try self.code.ensureCapacity(self.code.items.len + 8);
                        switch (abi_size) {
                            1 => {
                                return self.fail("TODO implement set abi_size=1 stack variable with immediate", .{});
                            },
                            2 => {
                                return self.fail("TODO implement set abi_size=2 stack variable with immediate", .{});
                            },
                            4 => {
                                const x = @intCast(u32, x_big);
                                // We have a positive stack offset value but we want a twos complement negative
                                // offset from rbp, which is at the top of the stack frame.
                                const negative_offset = @intCast(i8, -@intCast(i32, adj_off));
                                const twos_comp = @bitCast(u8, negative_offset);
                                // mov    DWORD PTR [rbp+offset], immediate
                                self.code.appendSliceAssumeCapacity(&[_]u8{ 0xc7, 0x45, twos_comp });
                                mem.writeIntLittle(u32, self.code.addManyAsArrayAssumeCapacity(4), x);
                            },
                            8 => {
                                // We have a positive stack offset value but we want a twos complement negative
                                // offset from rbp, which is at the top of the stack frame.
                                const negative_offset = @intCast(i8, -@intCast(i32, adj_off));
                                const twos_comp = @bitCast(u8, negative_offset);

                                // 64 bit write to memory would take two mov's anyways so we
                                // insted just use two 32 bit writes to avoid register allocation
                                try self.code.ensureCapacity(self.code.items.len + 14);
                                var buf: [8]u8 = undefined;
                                mem.writeIntLittle(u64, &buf, x_big);

                                // mov    DWORD PTR [rbp+offset+4], immediate
                                self.code.appendSliceAssumeCapacity(&[_]u8{ 0xc7, 0x45, twos_comp + 4 });
                                self.code.appendSliceAssumeCapacity(buf[4..8]);

                                // mov    DWORD PTR [rbp+offset], immediate
                                self.code.appendSliceAssumeCapacity(&[_]u8{ 0xc7, 0x45, twos_comp });
                                self.code.appendSliceAssumeCapacity(buf[0..4]);
                            },
                            else => {
                                return self.fail("TODO implement set abi_size=large stack variable with immediate", .{});
                            },
                        }
                    },
                    .embedded_in_code => {
                        // TODO this and `.stack_offset` below need to get improved to support types greater than
                        // register size, and do general memcpy
                        const reg = try self.copyToTmpRegister(ty, mcv);
                        return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
                    },
                    .register => |reg| {
                        try self.genX8664ModRMRegToStack(src, ty, stack_offset, reg, 0x89);
                    },
                    .memory => |vaddr| {
                        _ = vaddr;
                        return self.fail("TODO implement set stack variable from memory vaddr", .{});
                    },
                    .stack_offset => |off| {
                        // TODO this and `.embedded_in_code` above need to get improved to support types greater than
                        // register size, and do general memcpy

                        if (stack_offset == off)
                            return; // Copy stack variable to itself; nothing to do.

                        const reg = try self.copyToTmpRegister(ty, mcv);
                        return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
                    },
                },
                .aarch64, .aarch64_be, .aarch64_32 => switch (mcv) {
                    .dead => unreachable,
                    .ptr_stack_offset => unreachable,
                    .ptr_embedded_in_code => unreachable,
                    .unreach, .none => return, // Nothing to do.
                    .undef => {
                        if (!self.wantSafety())
                            return; // The already existing value will do just fine.
                        // TODO Upgrade this to a memset call when we have that available.
                        switch (ty.abiSize(self.target.*)) {
                            1 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaa }),
                            2 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaa }),
                            4 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaaaaaa }),
                            8 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaaaaaaaaaaaaaa }),
                            else => return self.fail("TODO implement memset", .{}),
                        }
                    },
                    .compare_flags_unsigned => |op| {
                        _ = op;
                        return self.fail("TODO implement set stack variable with compare flags value (unsigned)", .{});
                    },
                    .compare_flags_signed => |op| {
                        _ = op;
                        return self.fail("TODO implement set stack variable with compare flags value (signed)", .{});
                    },
                    .immediate => {
                        const reg = try self.copyToTmpRegister(ty, mcv);
                        return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
                    },
                    .embedded_in_code => |code_offset| {
                        _ = code_offset;
                        return self.fail("TODO implement set stack variable from embedded_in_code", .{});
                    },
                    .register => |reg| {
                        const abi_size = ty.abiSize(self.target.*);
                        const adj_off = stack_offset + abi_size;

                        switch (abi_size) {
                            1, 2, 4, 8 => {
                                const offset = if (math.cast(i9, adj_off)) |imm|
                                    Instruction.LoadStoreOffset.imm_post_index(-imm)
                                else |_|
                                    Instruction.LoadStoreOffset.reg(try self.copyToTmpRegister(Type.initTag(.u64), MCValue{ .immediate = adj_off }));
                                const rn: Register = switch (arch) {
                                    .aarch64, .aarch64_be => .x29,
                                    .aarch64_32 => .w29,
                                    else => unreachable,
                                };
                                const str = switch (abi_size) {
                                    1 => Instruction.strb,
                                    2 => Instruction.strh,
                                    4, 8 => Instruction.str,
                                    else => unreachable, // unexpected abi size
                                };

                                writeInt(u32, try self.code.addManyAsArray(4), str(reg, rn, .{
                                    .offset = offset,
                                }).toU32());
                            },
                            else => return self.fail("TODO implement storing other types abi_size={}", .{abi_size}),
                        }
                    },
                    .memory => |vaddr| {
                        _ = vaddr;
                        return self.fail("TODO implement set stack variable from memory vaddr", .{});
                    },
                    .stack_offset => |off| {
                        if (stack_offset == off)
                            return; // Copy stack variable to itself; nothing to do.

                        const reg = try self.copyToTmpRegister(ty, mcv);
                        return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
                    },
                },
                else => return self.fail("TODO implement getSetStack for {}", .{self.target.cpu.arch}),
            }
        }

        fn genSetReg(self: *Self, ty: Type, reg: Register, mcv: MCValue) InnerError!void {
            switch (arch) {
                .arm, .armeb => switch (mcv) {
                    .dead => unreachable,
                    .ptr_stack_offset => unreachable,
                    .ptr_embedded_in_code => unreachable,
                    .unreach, .none => return, // Nothing to do.
                    .undef => {
                        if (!self.wantSafety())
                            return; // The already existing value will do just fine.
                        // Write the debug undefined value.
                        return self.genSetReg(ty, reg, .{ .immediate = 0xaaaaaaaa });
                    },
                    .compare_flags_unsigned,
                    .compare_flags_signed,
                    => |op| {
                        const condition = switch (mcv) {
                            .compare_flags_unsigned => Condition.fromCompareOperatorUnsigned(op),
                            .compare_flags_signed => Condition.fromCompareOperatorSigned(op),
                            else => unreachable,
                        };

                        // mov reg, 0
                        // moveq reg, 1
                        const zero = Instruction.Operand.imm(0, 0);
                        const one = Instruction.Operand.imm(1, 0);
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.mov(.al, reg, zero).toU32());
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.mov(condition, reg, one).toU32());
                    },
                    .immediate => |x| {
                        if (x > math.maxInt(u32)) return self.fail("ARM registers are 32-bit wide", .{});

                        if (Instruction.Operand.fromU32(@intCast(u32, x))) |op| {
                            writeInt(u32, try self.code.addManyAsArray(4), Instruction.mov(.al, reg, op).toU32());
                        } else if (Instruction.Operand.fromU32(~@intCast(u32, x))) |op| {
                            writeInt(u32, try self.code.addManyAsArray(4), Instruction.mvn(.al, reg, op).toU32());
                        } else if (x <= math.maxInt(u16)) {
                            if (Target.arm.featureSetHas(self.target.cpu.features, .has_v7)) {
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.movw(.al, reg, @intCast(u16, x)).toU32());
                            } else {
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.mov(.al, reg, Instruction.Operand.imm(@truncate(u8, x), 0)).toU32());
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.orr(.al, reg, reg, Instruction.Operand.imm(@truncate(u8, x >> 8), 12)).toU32());
                            }
                        } else {
                            // TODO write constant to code and load
                            // relative to pc
                            if (Target.arm.featureSetHas(self.target.cpu.features, .has_v7)) {
                                // immediate: 0xaaaabbbb
                                // movw reg, #0xbbbb
                                // movt reg, #0xaaaa
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.movw(.al, reg, @truncate(u16, x)).toU32());
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.movt(.al, reg, @truncate(u16, x >> 16)).toU32());
                            } else {
                                // immediate: 0xaabbccdd
                                // mov reg, #0xaa
                                // orr reg, reg, #0xbb, 24
                                // orr reg, reg, #0xcc, 16
                                // orr reg, reg, #0xdd, 8
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.mov(.al, reg, Instruction.Operand.imm(@truncate(u8, x), 0)).toU32());
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.orr(.al, reg, reg, Instruction.Operand.imm(@truncate(u8, x >> 8), 12)).toU32());
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.orr(.al, reg, reg, Instruction.Operand.imm(@truncate(u8, x >> 16), 8)).toU32());
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.orr(.al, reg, reg, Instruction.Operand.imm(@truncate(u8, x >> 24), 4)).toU32());
                            }
                        }
                    },
                    .register => |src_reg| {
                        // If the registers are the same, nothing to do.
                        if (src_reg.id() == reg.id())
                            return;

                        // mov reg, src_reg
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.mov(.al, reg, Instruction.Operand.reg(src_reg, Instruction.Operand.Shift.none)).toU32());
                    },
                    .memory => |addr| {
                        // The value is in memory at a hard-coded address.
                        // If the type is a pointer, it means the pointer address is at this memory location.
                        try self.genSetReg(ty, reg, .{ .immediate = addr });
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.ldr(.al, reg, reg, .{ .offset = Instruction.Offset.none }).toU32());
                    },
                    .stack_offset => |unadjusted_off| {
                        // TODO: maybe addressing from sp instead of fp
                        const abi_size = ty.abiSize(self.target.*);
                        const adj_off = unadjusted_off + abi_size;

                        switch (abi_size) {
                            1, 4 => {
                                const offset = if (adj_off <= math.maxInt(u12)) blk: {
                                    break :blk Instruction.Offset.imm(@intCast(u12, adj_off));
                                } else Instruction.Offset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }), 0);
                                const ldr = switch (abi_size) {
                                    1 => Instruction.ldrb,
                                    4 => Instruction.ldr,
                                    else => unreachable,
                                };

                                writeInt(u32, try self.code.addManyAsArray(4), ldr(.al, reg, .fp, .{
                                    .offset = offset,
                                    .positive = false,
                                }).toU32());
                            },
                            2 => {
                                const offset = if (adj_off <= math.maxInt(u8)) blk: {
                                    break :blk Instruction.ExtraLoadStoreOffset.imm(@intCast(u8, adj_off));
                                } else Instruction.ExtraLoadStoreOffset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }));

                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.ldrh(.al, reg, .fp, .{
                                    .offset = offset,
                                    .positive = false,
                                }).toU32());
                            },
                            else => return self.fail("TODO a type of size {} is not allowed in a register", .{abi_size}),
                        }
                    },
                    else => return self.fail("TODO implement getSetReg for arm {}", .{mcv}),
                },
                .aarch64 => switch (mcv) {
                    .dead => unreachable,
                    .ptr_stack_offset => unreachable,
                    .ptr_embedded_in_code => unreachable,
                    .unreach, .none => return, // Nothing to do.
                    .undef => {
                        if (!self.wantSafety())
                            return; // The already existing value will do just fine.
                        // Write the debug undefined value.
                        switch (reg.size()) {
                            32 => return self.genSetReg(ty, reg, .{ .immediate = 0xaaaaaaaa }),
                            64 => return self.genSetReg(ty, reg, .{ .immediate = 0xaaaaaaaaaaaaaaaa }),
                            else => unreachable, // unexpected register size
                        }
                    },
                    .immediate => |x| {
                        if (x <= math.maxInt(u16)) {
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movz(reg, @intCast(u16, x), 0).toU32());
                        } else if (x <= math.maxInt(u32)) {
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movz(reg, @truncate(u16, x), 0).toU32());
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movk(reg, @intCast(u16, x >> 16), 16).toU32());
                        } else if (x <= math.maxInt(u32)) {
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movz(reg, @truncate(u16, x), 0).toU32());
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movk(reg, @truncate(u16, x >> 16), 16).toU32());
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movk(reg, @intCast(u16, x >> 32), 32).toU32());
                        } else {
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movz(reg, @truncate(u16, x), 0).toU32());
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movk(reg, @truncate(u16, x >> 16), 16).toU32());
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movk(reg, @truncate(u16, x >> 32), 32).toU32());
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.movk(reg, @intCast(u16, x >> 48), 48).toU32());
                        }
                    },
                    .register => |src_reg| {
                        // If the registers are the same, nothing to do.
                        if (src_reg.id() == reg.id())
                            return;

                        // mov reg, src_reg
                        writeInt(u32, try self.code.addManyAsArray(4), Instruction.orr(
                            reg,
                            .xzr,
                            src_reg,
                            Instruction.Shift.none,
                        ).toU32());
                    },
                    .memory => |addr| {
                        if (self.bin_file.options.pie) {
                            // PC-relative displacement to the entry in the GOT table.
                            // TODO we should come up with our own, backend independent relocation types
                            // which each backend (Elf, MachO, etc.) would then translate into an actual
                            // fixup when linking.
                            // adrp reg, pages
                            if (self.bin_file.cast(link.File.MachO)) |macho_file| {
                                try macho_file.pie_fixups.append(self.bin_file.allocator, .{
                                    .target_addr = addr,
                                    .offset = self.code.items.len,
                                    .size = 4,
                                });
                            } else {
                                return self.fail("TODO implement genSetReg for PIE GOT indirection on this platform", .{});
                            }
                            mem.writeIntLittle(
                                u32,
                                try self.code.addManyAsArray(4),
                                Instruction.adrp(reg, 0).toU32(),
                            );
                            // ldr reg, reg, offset
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.ldr(reg, .{
                                .register = .{
                                    .rn = reg,
                                    .offset = Instruction.LoadStoreOffset.imm(0),
                                },
                            }).toU32());
                        } else {
                            // The value is in memory at a hard-coded address.
                            // If the type is a pointer, it means the pointer address is at this memory location.
                            try self.genSetReg(Type.initTag(.usize), reg, .{ .immediate = addr });
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.ldr(reg, .{ .register = .{ .rn = reg } }).toU32());
                        }
                    },
                    .stack_offset => |unadjusted_off| {
                        // TODO: maybe addressing from sp instead of fp
                        const abi_size = ty.abiSize(self.target.*);
                        const adj_off = unadjusted_off + abi_size;

                        const rn: Register = switch (arch) {
                            .aarch64, .aarch64_be => .x29,
                            .aarch64_32 => .w29,
                            else => unreachable,
                        };

                        const offset = if (math.cast(i9, adj_off)) |imm|
                            Instruction.LoadStoreOffset.imm_post_index(-imm)
                        else |_|
                            Instruction.LoadStoreOffset.reg(try self.copyToTmpRegister(Type.initTag(.u64), MCValue{ .immediate = adj_off }));

                        switch (abi_size) {
                            1, 2 => {
                                const ldr = switch (abi_size) {
                                    1 => Instruction.ldrb,
                                    2 => Instruction.ldrh,
                                    else => unreachable, // unexpected abi size
                                };

                                writeInt(u32, try self.code.addManyAsArray(4), ldr(reg, rn, .{
                                    .offset = offset,
                                }).toU32());
                            },
                            4, 8 => {
                                writeInt(u32, try self.code.addManyAsArray(4), Instruction.ldr(reg, .{ .register = .{
                                    .rn = rn,
                                    .offset = offset,
                                } }).toU32());
                            },
                            else => return self.fail("TODO implement genSetReg other types abi_size={}", .{abi_size}),
                        }
                    },
                    else => return self.fail("TODO implement genSetReg for aarch64 {}", .{mcv}),
                },
                .riscv64 => switch (mcv) {
                    .dead => unreachable,
                    .ptr_stack_offset => unreachable,
                    .ptr_embedded_in_code => unreachable,
                    .unreach, .none => return, // Nothing to do.
                    .undef => {
                        if (!self.wantSafety())
                            return; // The already existing value will do just fine.
                        // Write the debug undefined value.
                        return self.genSetReg(ty, reg, .{ .immediate = 0xaaaaaaaaaaaaaaaa });
                    },
                    .immediate => |unsigned_x| {
                        const x = @bitCast(i64, unsigned_x);
                        if (math.minInt(i12) <= x and x <= math.maxInt(i12)) {
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.addi(reg, .zero, @truncate(i12, x)).toU32());
                            return;
                        }
                        if (math.minInt(i32) <= x and x <= math.maxInt(i32)) {
                            const lo12 = @truncate(i12, x);
                            const carry: i32 = if (lo12 < 0) 1 else 0;
                            const hi20 = @truncate(i20, (x >> 12) +% carry);

                            // TODO: add test case for 32-bit immediate
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.lui(reg, hi20).toU32());
                            mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.addi(reg, reg, lo12).toU32());
                            return;
                        }
                        // li rd, immediate
                        // "Myriad sequences"
                        return self.fail("TODO genSetReg 33-64 bit immediates for riscv64", .{}); // glhf
                    },
                    .memory => |addr| {
                        // The value is in memory at a hard-coded address.
                        // If the type is a pointer, it means the pointer address is at this memory location.
                        try self.genSetReg(ty, reg, .{ .immediate = addr });

                        mem.writeIntLittle(u32, try self.code.addManyAsArray(4), Instruction.ld(reg, 0, reg).toU32());
                        // LOAD imm=[i12 offset = 0], rs1 =

                        // return self.fail("TODO implement genSetReg memory for riscv64");
                    },
                    else => return self.fail("TODO implement getSetReg for riscv64 {}", .{mcv}),
                },
                .x86_64 => switch (mcv) {
                    .dead => unreachable,
                    .ptr_stack_offset => unreachable,
                    .ptr_embedded_in_code => unreachable,
                    .unreach, .none => return, // Nothing to do.
                    .undef => {
                        if (!self.wantSafety())
                            return; // The already existing value will do just fine.
                        // Write the debug undefined value.
                        switch (reg.size()) {
                            8 => return self.genSetReg(ty, reg, .{ .immediate = 0xaa }),
                            16 => return self.genSetReg(ty, reg, .{ .immediate = 0xaaaa }),
                            32 => return self.genSetReg(ty, reg, .{ .immediate = 0xaaaaaaaa }),
                            64 => return self.genSetReg(ty, reg, .{ .immediate = 0xaaaaaaaaaaaaaaaa }),
                            else => unreachable,
                        }
                    },
                    .compare_flags_unsigned => |op| {
                        const encoder = try X8664Encoder.init(self.code, 7);
                        // TODO audit this codegen: we force w = true here to make
                        // the value affect the big register
                        encoder.rex(.{
                            .w = true,
                            .b = reg.isExtended(),
                        });
                        encoder.opcode_2byte(0x0f, switch (op) {
                            .gte => 0x93,
                            .gt => 0x97,
                            .neq => 0x95,
                            .lt => 0x92,
                            .lte => 0x96,
                            .eq => 0x94,
                        });
                        encoder.modRm_direct(
                            0,
                            reg.low_id(),
                        );
                    },
                    .compare_flags_signed => |op| {
                        _ = op;
                        return self.fail("TODO set register with compare flags value (signed)", .{});
                    },
                    .immediate => |x| {
                        // 32-bit moves zero-extend to 64-bit, so xoring the 32-bit
                        // register is the fastest way to zero a register.
                        if (x == 0) {
                            // The encoding for `xor r32, r32` is `0x31 /r`.
                            const encoder = try X8664Encoder.init(self.code, 3);

                            // If we're accessing e.g. r8d, we need to use a REX prefix before the actual operation. Since
                            // this is a 32-bit operation, the W flag is set to zero. X is also zero, as we're not using a SIB.
                            // Both R and B are set, as we're extending, in effect, the register bits *and* the operand.
                            encoder.rex(.{
                                .r = reg.isExtended(),
                                .b = reg.isExtended(),
                            });
                            encoder.opcode_1byte(0x31);
                            // Section 3.1.1.1 of the Intel x64 Manual states that "/r indicates that the
                            // ModR/M byte of the instruction contains a register operand and an r/m operand."
                            encoder.modRm_direct(
                                reg.low_id(),
                                reg.low_id(),
                            );

                            return;
                        }
                        if (x <= math.maxInt(i32)) {
                            // Next best case: if we set the lower four bytes, the upper four will be zeroed.
                            //
                            // The encoding for `mov IMM32 -> REG` is (0xB8 + R) IMM.

                            const encoder = try X8664Encoder.init(self.code, 6);
                            // Just as with XORing, we need a REX prefix. This time though, we only
                            // need the B bit set, as we're extending the opcode's register field,
                            // and there is no Mod R/M byte.
                            encoder.rex(.{
                                .b = reg.isExtended(),
                            });
                            encoder.opcode_withReg(0xB8, reg.low_id());

                            // no ModR/M byte

                            // IMM
                            encoder.imm32(@intCast(i32, x));
                            return;
                        }
                        // Worst case: we need to load the 64-bit register with the IMM. GNU's assemblers calls
                        // this `movabs`, though this is officially just a different variant of the plain `mov`
                        // instruction.
                        //
                        // This encoding is, in fact, the *same* as the one used for 32-bit loads. The only
                        // difference is that we set REX.W before the instruction, which extends the load to
                        // 64-bit and uses the full bit-width of the register.
                        {
                            const encoder = try X8664Encoder.init(self.code, 10);
                            encoder.rex(.{
                                .w = true,
                                .b = reg.isExtended(),
                            });
                            encoder.opcode_withReg(0xB8, reg.low_id());
                            encoder.imm64(x);
                        }
                    },
                    .embedded_in_code => |code_offset| {
                        // We need the offset from RIP in a signed i32 twos complement.
                        // The instruction is 7 bytes long and RIP points to the next instruction.

                        // 64-bit LEA is encoded as REX.W 8D /r.
                        const rip = self.code.items.len + 7;
                        const big_offset = @intCast(i64, code_offset) - @intCast(i64, rip);
                        const offset = @intCast(i32, big_offset);
                        const encoder = try X8664Encoder.init(self.code, 7);

                        // byte 1, always exists because w = true
                        encoder.rex(.{
                            .w = true,
                            .r = reg.isExtended(),
                        });
                        // byte 2
                        encoder.opcode_1byte(0x8D);
                        // byte 3
                        encoder.modRm_RIPDisp32(reg.low_id());
                        // byte 4-7
                        encoder.disp32(offset);

                        // Double check that we haven't done any math errors
                        assert(rip == self.code.items.len);
                    },
                    .register => |src_reg| {
                        // If the registers are the same, nothing to do.
                        if (src_reg.id() == reg.id())
                            return;

                        // This is a variant of 8B /r.
                        const abi_size = ty.abiSize(self.target.*);
                        const encoder = try X8664Encoder.init(self.code, 3);
                        encoder.rex(.{
                            .w = abi_size == 8,
                            .r = reg.isExtended(),
                            .b = src_reg.isExtended(),
                        });
                        encoder.opcode_1byte(0x8B);
                        encoder.modRm_direct(reg.low_id(), src_reg.low_id());
                    },
                    .memory => |x| {
                        if (self.bin_file.options.pie) {
                            // RIP-relative displacement to the entry in the GOT table.
                            const abi_size = ty.abiSize(self.target.*);
                            const encoder = try X8664Encoder.init(self.code, 10);

                            // LEA reg, [<offset>]

                            // We encode the instruction FIRST because prefixes may or may not appear.
                            // After we encode the instruction, we will know that the displacement bytes
                            // for [<offset>] will be at self.code.items.len - 4.
                            encoder.rex(.{
                                .w = true, // force 64 bit because loading an address (to the GOT)
                                .r = reg.isExtended(),
                            });
                            encoder.opcode_1byte(0x8D);
                            encoder.modRm_RIPDisp32(reg.low_id());
                            encoder.disp32(0);

                            // TODO we should come up with our own, backend independent relocation types
                            // which each backend (Elf, MachO, etc.) would then translate into an actual
                            // fixup when linking.
                            if (self.bin_file.cast(link.File.MachO)) |macho_file| {
                                try macho_file.pie_fixups.append(self.bin_file.allocator, .{
                                    .target_addr = x,
                                    .offset = self.code.items.len - 4,
                                    .size = 4,
                                });
                            } else {
                                return self.fail("TODO implement genSetReg for PIE GOT indirection on this platform", .{});
                            }

                            // MOV reg, [reg]
                            encoder.rex(.{
                                .w = abi_size == 8,
                                .r = reg.isExtended(),
                                .b = reg.isExtended(),
                            });
                            encoder.opcode_1byte(0x8B);
                            encoder.modRm_indirectDisp0(reg.low_id(), reg.low_id());
                        } else if (x <= math.maxInt(i32)) {
                            // Moving from memory to a register is a variant of `8B /r`.
                            // Since we're using 64-bit moves, we require a REX.
                            // This variant also requires a SIB, as it would otherwise be RIP-relative.
                            // We want mode zero with the lower three bits set to four to indicate an SIB with no other displacement.
                            // The SIB must be 0x25, to indicate a disp32 with no scaled index.
                            // 0b00RRR100, where RRR is the lower three bits of the register ID.
                            // The instruction is thus eight bytes; REX 0x8B 0b00RRR100 0x25 followed by a four-byte disp32.
                            const abi_size = ty.abiSize(self.target.*);
                            const encoder = try X8664Encoder.init(self.code, 8);
                            encoder.rex(.{
                                .w = abi_size == 8,
                                .r = reg.isExtended(),
                            });
                            encoder.opcode_1byte(0x8B);
                            // effective address = [SIB]
                            encoder.modRm_SIBDisp0(reg.low_id());
                            // SIB = disp32
                            encoder.sib_disp32();
                            encoder.disp32(@intCast(i32, x));
                        } else {
                            // If this is RAX, we can use a direct load; otherwise, we need to load the address, then indirectly load
                            // the value.
                            if (reg.id() == 0) {
                                // REX.W 0xA1 moffs64*
                                // moffs64* is a 64-bit offset "relative to segment base", which really just means the
                                // absolute address for all practical purposes.

                                const encoder = try X8664Encoder.init(self.code, 10);
                                encoder.rex(.{
                                    .w = true,
                                });
                                encoder.opcode_1byte(0xA1);
                                encoder.writeIntLittle(u64, x);
                            } else {
                                // This requires two instructions; a move imm as used above, followed by an indirect load using the register
                                // as the address and the register as the destination.
                                //
                                // This cannot be used if the lower three bits of the id are equal to four or five, as there
                                // is no way to possibly encode it. This means that RSP, RBP, R12, and R13 cannot be used with
                                // this instruction.
                                const id3 = @truncate(u3, reg.id());
                                assert(id3 != 4 and id3 != 5);

                                // Rather than duplicate the logic used for the move, we just use a self-call with a new MCValue.
                                try self.genSetReg(ty, reg, MCValue{ .immediate = x });

                                // Now, the register contains the address of the value to load into it
                                // Currently, we're only allowing 64-bit registers, so we need the `REX.W 8B /r` variant.
                                // TODO: determine whether to allow other sized registers, and if so, handle them properly.

                                // mov reg, [reg]
                                const abi_size = ty.abiSize(self.target.*);
                                const encoder = try X8664Encoder.init(self.code, 3);
                                encoder.rex(.{
                                    .w = abi_size == 8,
                                    .r = reg.isExtended(),
                                    .b = reg.isExtended(),
                                });
                                encoder.opcode_1byte(0x8B);
                                encoder.modRm_indirectDisp0(reg.low_id(), reg.low_id());
                            }
                        }
                    },
                    .stack_offset => |unadjusted_off| {
                        const abi_size = ty.abiSize(self.target.*);
                        const off = unadjusted_off + abi_size;
                        if (off < std.math.minInt(i32) or off > std.math.maxInt(i32)) {
                            return self.fail("stack offset too large", .{});
                        }
                        const ioff = -@intCast(i32, off);
                        const encoder = try X8664Encoder.init(self.code, 3);
                        encoder.rex(.{
                            .w = abi_size == 8,
                            .r = reg.isExtended(),
                        });
                        encoder.opcode_1byte(0x8B);
                        if (std.math.minInt(i8) <= ioff and ioff <= std.math.maxInt(i8)) {
                            // Example: 48 8b 4d 7f           mov    rcx,QWORD PTR [rbp+0x7f]
                            encoder.modRm_indirectDisp8(reg.low_id(), Register.ebp.low_id());
                            encoder.disp8(@intCast(i8, ioff));
                        } else {
                            // Example: 48 8b 8d 80 00 00 00  mov    rcx,QWORD PTR [rbp+0x80]
                            encoder.modRm_indirectDisp32(reg.low_id(), Register.ebp.low_id());
                            encoder.disp32(ioff);
                        }
                    },
                },
                else => return self.fail("TODO implement getSetReg for {}", .{self.target.cpu.arch}),
            }
        }

        fn genPtrToInt(self: *Self, inst: Air.Inst.Index) !MCValue {
            const un_op = self.air.instructions.items(.data)[inst].un_op;
            return self.resolveInst(un_op);
        }

        fn genBitCast(self: *Self, inst: Air.Inst.Index) !MCValue {
            const ty_op = self.air.instructions.items(.data)[inst].ty_op;
            return self.resolveInst(ty_op.operand);
        }

        fn resolveInst(self: *Self, inst: Air.Inst.Index) !MCValue {
            // If the type has no codegen bits, no need to store it.
            if (!inst.ty.hasCodeGenBits())
                return MCValue.none;

            // Constants have static lifetimes, so they are always memoized in the outer most table.
            if (inst.castTag(.constant)) |const_inst| {
                const branch = &self.branch_stack.items[0];
                const gop = try branch.inst_table.getOrPut(self.gpa, inst);
                if (!gop.found_existing) {
                    gop.value_ptr.* = try self.genTypedValue(inst.src, .{ .ty = inst.ty, .val = const_inst.val });
                }
                return gop.value_ptr.*;
            }

            return self.getResolvedInstValue(inst);
        }

        fn getResolvedInstValue(self: *Self, inst: Air.Inst.Index) MCValue {
            // Treat each stack item as a "layer" on top of the previous one.
            var i: usize = self.branch_stack.items.len;
            while (true) {
                i -= 1;
                if (self.branch_stack.items[i].inst_table.get(inst)) |mcv| {
                    assert(mcv != .dead);
                    return mcv;
                }
            }
        }

        /// If the MCValue is an immediate, and it does not fit within this type,
        /// we put it in a register.
        /// A potential opportunity for future optimization here would be keeping track
        /// of the fact that the instruction is available both as an immediate
        /// and as a register.
        fn limitImmediateType(self: *Self, inst: Air.Inst.Index, comptime T: type) !MCValue {
            const mcv = try self.resolveInst(inst);
            const ti = @typeInfo(T).Int;
            switch (mcv) {
                .immediate => |imm| {
                    // This immediate is unsigned.
                    const U = std.meta.Int(.unsigned, ti.bits - @boolToInt(ti.signedness == .signed));
                    if (imm >= math.maxInt(U)) {
                        return MCValue{ .register = try self.copyToTmpRegister(Type.initTag(.usize), mcv) };
                    }
                },
                else => {},
            }
            return mcv;
        }

        fn genTypedValue(self: *Self, src: LazySrcLoc, typed_value: TypedValue) InnerError!MCValue {
            if (typed_value.val.isUndef())
                return MCValue{ .undef = {} };
            const ptr_bits = self.target.cpu.arch.ptrBitWidth();
            const ptr_bytes: u64 = @divExact(ptr_bits, 8);
            switch (typed_value.ty.zigTypeTag()) {
                .Pointer => switch (typed_value.ty.ptrSize()) {
                    .Slice => {
                        var buf: Type.Payload.ElemType = undefined;
                        const ptr_type = typed_value.ty.slicePtrFieldType(&buf);
                        const ptr_mcv = try self.genTypedValue(src, .{ .ty = ptr_type, .val = typed_value.val });
                        const slice_len = typed_value.val.sliceLen();
                        // Codegen can't handle some kinds of indirection. If the wrong union field is accessed here it may mean
                        // the Sema code needs to use anonymous Decls or alloca instructions to store data.
                        const ptr_imm = ptr_mcv.memory;
                        _ = slice_len;
                        _ = ptr_imm;
                        // We need more general support for const data being stored in memory to make this work.
                        return self.fail("TODO codegen for const slices", .{});
                    },
                    else => {
                        if (typed_value.val.castTag(.decl_ref)) |payload| {
                            if (self.bin_file.cast(link.File.Elf)) |elf_file| {
                                const decl = payload.data;
                                const got = &elf_file.program_headers.items[elf_file.phdr_got_index.?];
                                const got_addr = got.p_vaddr + decl.link.elf.offset_table_index * ptr_bytes;
                                return MCValue{ .memory = got_addr };
                            } else if (self.bin_file.cast(link.File.MachO)) |macho_file| {
                                const decl = payload.data;
                                const got_addr = blk: {
                                    const seg = macho_file.load_commands.items[macho_file.data_const_segment_cmd_index.?].Segment;
                                    const got = seg.sections.items[macho_file.got_section_index.?];
                                    break :blk got.addr + decl.link.macho.offset_table_index * ptr_bytes;
                                };
                                return MCValue{ .memory = got_addr };
                            } else if (self.bin_file.cast(link.File.Coff)) |coff_file| {
                                const decl = payload.data;
                                const got_addr = coff_file.offset_table_virtual_address + decl.link.coff.offset_table_index * ptr_bytes;
                                return MCValue{ .memory = got_addr };
                            } else if (self.bin_file.cast(link.File.Plan9)) |p9| {
                                const decl = payload.data;
                                const got_addr = p9.bases.data + decl.link.plan9.got_index.? * ptr_bytes;
                                return MCValue{ .memory = got_addr };
                            } else {
                                return self.fail("TODO codegen non-ELF const Decl pointer", .{});
                            }
                        }
                        if (typed_value.val.tag() == .int_u64) {
                            return MCValue{ .immediate = typed_value.val.toUnsignedInt() };
                        }
                        return self.fail("TODO codegen more kinds of const pointers", .{});
                    },
                },
                .Int => {
                    const info = typed_value.ty.intInfo(self.target.*);
                    if (info.bits > ptr_bits or info.signedness == .signed) {
                        return self.fail("TODO const int bigger than ptr and signed int", .{});
                    }
                    return MCValue{ .immediate = typed_value.val.toUnsignedInt() };
                },
                .Bool => {
                    return MCValue{ .immediate = @boolToInt(typed_value.val.toBool()) };
                },
                .ComptimeInt => unreachable, // semantic analysis prevents this
                .ComptimeFloat => unreachable, // semantic analysis prevents this
                .Optional => {
                    if (typed_value.ty.isPtrLikeOptional()) {
                        if (typed_value.val.isNull())
                            return MCValue{ .immediate = 0 };

                        var buf: Type.Payload.ElemType = undefined;
                        return self.genTypedValue(src, .{
                            .ty = typed_value.ty.optionalChild(&buf),
                            .val = typed_value.val,
                        });
                    } else if (typed_value.ty.abiSize(self.target.*) == 1) {
                        return MCValue{ .immediate = @boolToInt(typed_value.val.isNull()) };
                    }
                    return self.fail("TODO non pointer optionals", .{});
                },
                else => return self.fail("TODO implement const of type '{}'", .{typed_value.ty}),
            }
        }

        const CallMCValues = struct {
            args: []MCValue,
            return_value: MCValue,
            stack_byte_count: u32,
            stack_align: u32,

            fn deinit(self: *CallMCValues, func: *Self) void {
                func.gpa.free(self.args);
                self.* = undefined;
            }
        };

        /// Caller must call `CallMCValues.deinit`.
        fn resolveCallingConventionValues(self: *Self, fn_ty: Type) !CallMCValues {
            const cc = fn_ty.fnCallingConvention();
            const param_types = try self.gpa.alloc(Type, fn_ty.fnParamLen());
            defer self.gpa.free(param_types);
            fn_ty.fnParamTypes(param_types);
            var result: CallMCValues = .{
                .args = try self.gpa.alloc(MCValue, param_types.len),
                // These undefined values must be populated before returning from this function.
                .return_value = undefined,
                .stack_byte_count = undefined,
                .stack_align = undefined,
            };
            errdefer self.gpa.free(result.args);

            const ret_ty = fn_ty.fnReturnType();

            switch (arch) {
                .x86_64 => {
                    switch (cc) {
                        .Naked => {
                            assert(result.args.len == 0);
                            result.return_value = .{ .unreach = {} };
                            result.stack_byte_count = 0;
                            result.stack_align = 1;
                            return result;
                        },
                        .Unspecified, .C => {
                            var next_int_reg: usize = 0;
                            var next_stack_offset: u32 = 0;

                            for (param_types) |ty, i| {
                                if (!ty.hasCodeGenBits()) {
                                    assert(cc != .C);
                                    result.args[i] = .{ .none = {} };
                                    continue;
                                }
                                const param_size = @intCast(u32, ty.abiSize(self.target.*));
                                const pass_in_reg = switch (ty.zigTypeTag()) {
                                    .Bool => true,
                                    .Int => param_size <= 8,
                                    .Pointer => ty.ptrSize() != .Slice,
                                    .Optional => ty.isPtrLikeOptional(),
                                    else => false,
                                };
                                if (pass_in_reg) {
                                    if (next_int_reg >= c_abi_int_param_regs.len) {
                                        result.args[i] = .{ .stack_offset = next_stack_offset };
                                        next_stack_offset += param_size;
                                    } else {
                                        const aliased_reg = registerAlias(
                                            c_abi_int_param_regs[next_int_reg],
                                            param_size,
                                        );
                                        result.args[i] = .{ .register = aliased_reg };
                                        next_int_reg += 1;
                                    }
                                } else {
                                    // For simplicity of codegen, slices and other types are always pushed onto the stack.
                                    // TODO: look into optimizing this by passing things as registers sometimes,
                                    // such as ptr and len of slices as separate registers.
                                    // TODO: also we need to honor the C ABI for relevant types rather than passing on
                                    // the stack here.
                                    result.args[i] = .{ .stack_offset = next_stack_offset };
                                    next_stack_offset += param_size;
                                }
                            }
                            result.stack_byte_count = next_stack_offset;
                            result.stack_align = 16;
                        },
                        else => return self.fail("TODO implement function parameters for {} on x86_64", .{cc}),
                    }
                },
                .arm, .armeb => {
                    switch (cc) {
                        .Naked => {
                            assert(result.args.len == 0);
                            result.return_value = .{ .unreach = {} };
                            result.stack_byte_count = 0;
                            result.stack_align = 1;
                            return result;
                        },
                        .Unspecified, .C => {
                            // ARM Procedure Call Standard, Chapter 6.5
                            var ncrn: usize = 0; // Next Core Register Number
                            var nsaa: u32 = 0; // Next stacked argument address

                            for (param_types) |ty, i| {
                                if (ty.abiAlignment(self.target.*) == 8)
                                    ncrn = std.mem.alignForwardGeneric(usize, ncrn, 2);

                                const param_size = @intCast(u32, ty.abiSize(self.target.*));
                                if (std.math.divCeil(u32, param_size, 4) catch unreachable <= 4 - ncrn) {
                                    if (param_size <= 4) {
                                        result.args[i] = .{ .register = c_abi_int_param_regs[ncrn] };
                                        ncrn += 1;
                                    } else {
                                        return self.fail("TODO MCValues with multiple registers", .{});
                                    }
                                } else if (ncrn < 4 and nsaa == 0) {
                                    return self.fail("TODO MCValues split between registers and stack", .{});
                                } else {
                                    ncrn = 4;
                                    if (ty.abiAlignment(self.target.*) == 8)
                                        nsaa = std.mem.alignForwardGeneric(u32, nsaa, 8);

                                    result.args[i] = .{ .stack_offset = nsaa };
                                    nsaa += param_size;
                                }
                            }

                            result.stack_byte_count = nsaa;
                            result.stack_align = 4;
                        },
                        else => return self.fail("TODO implement function parameters for {} on arm", .{cc}),
                    }
                },
                .aarch64 => {
                    switch (cc) {
                        .Naked => {
                            assert(result.args.len == 0);
                            result.return_value = .{ .unreach = {} };
                            result.stack_byte_count = 0;
                            result.stack_align = 1;
                            return result;
                        },
                        .Unspecified, .C => {
                            // ARM64 Procedure Call Standard
                            var ncrn: usize = 0; // Next Core Register Number
                            var nsaa: u32 = 0; // Next stacked argument address

                            for (param_types) |ty, i| {
                                // We round up NCRN only for non-Apple platforms which allow the 16-byte aligned
                                // values to spread across odd-numbered registers.
                                if (ty.abiAlignment(self.target.*) == 16 and !self.target.isDarwin()) {
                                    // Round up NCRN to the next even number
                                    ncrn += ncrn % 2;
                                }

                                const param_size = @intCast(u32, ty.abiSize(self.target.*));
                                if (std.math.divCeil(u32, param_size, 8) catch unreachable <= 8 - ncrn) {
                                    if (param_size <= 8) {
                                        result.args[i] = .{ .register = c_abi_int_param_regs[ncrn] };
                                        ncrn += 1;
                                    } else {
                                        return self.fail("TODO MCValues with multiple registers", .{});
                                    }
                                } else if (ncrn < 8 and nsaa == 0) {
                                    return self.fail("TODO MCValues split between registers and stack", .{});
                                } else {
                                    ncrn = 8;
                                    // TODO Apple allows the arguments on the stack to be non-8-byte aligned provided
                                    // that the entire stack space consumed by the arguments is 8-byte aligned.
                                    if (ty.abiAlignment(self.target.*) == 8) {
                                        if (nsaa % 8 != 0) {
                                            nsaa += 8 - (nsaa % 8);
                                        }
                                    }

                                    result.args[i] = .{ .stack_offset = nsaa };
                                    nsaa += param_size;
                                }
                            }

                            result.stack_byte_count = nsaa;
                            result.stack_align = 16;
                        },
                        else => return self.fail("TODO implement function parameters for {} on aarch64", .{cc}),
                    }
                },
                else => if (param_types.len != 0)
                    return self.fail("TODO implement codegen parameters for {}", .{self.target.cpu.arch}),
            }

            if (ret_ty.zigTypeTag() == .NoReturn) {
                result.return_value = .{ .unreach = {} };
            } else if (!ret_ty.hasCodeGenBits()) {
                result.return_value = .{ .none = {} };
            } else switch (arch) {
                .x86_64 => switch (cc) {
                    .Naked => unreachable,
                    .Unspecified, .C => {
                        const ret_ty_size = @intCast(u32, ret_ty.abiSize(self.target.*));
                        const aliased_reg = registerAlias(c_abi_int_return_regs[0], ret_ty_size);
                        result.return_value = .{ .register = aliased_reg };
                    },
                    else => return self.fail("TODO implement function return values for {}", .{cc}),
                },
                .arm, .armeb => switch (cc) {
                    .Naked => unreachable,
                    .Unspecified, .C => {
                        const ret_ty_size = @intCast(u32, ret_ty.abiSize(self.target.*));
                        if (ret_ty_size <= 4) {
                            result.return_value = .{ .register = c_abi_int_return_regs[0] };
                        } else {
                            return self.fail("TODO support more return types for ARM backend", .{});
                        }
                    },
                    else => return self.fail("TODO implement function return values for {}", .{cc}),
                },
                .aarch64 => switch (cc) {
                    .Naked => unreachable,
                    .Unspecified, .C => {
                        const ret_ty_size = @intCast(u32, ret_ty.abiSize(self.target.*));
                        if (ret_ty_size <= 8) {
                            result.return_value = .{ .register = c_abi_int_return_regs[0] };
                        } else {
                            return self.fail("TODO support more return types for ARM backend", .{});
                        }
                    },
                    else => return self.fail("TODO implement function return values for {}", .{cc}),
                },
                else => return self.fail("TODO implement codegen return values for {}", .{self.target.cpu.arch}),
            }
            return result;
        }

        /// TODO support scope overrides. Also note this logic is duplicated with `Module.wantSafety`.
        fn wantSafety(self: *Self) bool {
            return switch (self.bin_file.options.optimize_mode) {
                .Debug => true,
                .ReleaseSafe => true,
                .ReleaseFast => false,
                .ReleaseSmall => false,
            };
        }

        fn fail(self: *Self, comptime format: []const u8, args: anytype) InnerError {
            @setCold(true);
            assert(self.err_msg == null);
            self.err_msg = try ErrorMsg.create(self.bin_file.allocator, self.src_loc, format, args);
            return error.CodegenFail;
        }

        fn failSymbol(self: *Self, comptime format: []const u8, args: anytype) InnerError {
            @setCold(true);
            assert(self.err_msg == null);
            self.err_msg = try ErrorMsg.create(self.bin_file.allocator, self.src_loc, format, args);
            return error.CodegenFail;
        }

        usingnamespace switch (arch) {
            .i386 => @import("codegen/x86.zig"),
            .x86_64 => @import("codegen/x86_64.zig"),
            .riscv64 => @import("codegen/riscv64.zig"),
            .arm, .armeb => @import("codegen/arm.zig"),
            .aarch64, .aarch64_be, .aarch64_32 => @import("codegen/aarch64.zig"),
            else => struct {
                pub const Register = enum {
                    dummy,

                    pub fn allocIndex(self: Register) ?u4 {
                        _ = self;
                        return null;
                    }
                };
                pub const callee_preserved_regs = [_]Register{};
            },
        };

        fn parseRegName(name: []const u8) ?Register {
            if (@hasDecl(Register, "parseRegName")) {
                return Register.parseRegName(name);
            }
            return std.meta.stringToEnum(Register, name);
        }

        fn registerAlias(reg: Register, size_bytes: u32) Register {
            switch (arch) {
                // For x86_64 we have to pick a smaller register alias depending on abi size.
                .x86_64 => switch (size_bytes) {
                    1 => return reg.to8(),
                    2 => return reg.to16(),
                    4 => return reg.to32(),
                    8 => return reg.to64(),
                    else => unreachable,
                },
                else => return reg,
            }
        }

        /// For most architectures this does nothing. For x86_64 it resolves any aliased registers
        /// to the 64-bit wide ones.
        fn toCanonicalReg(reg: Register) Register {
            return switch (arch) {
                .x86_64 => reg.to64(),
                else => reg,
            };
        }
    };
}
