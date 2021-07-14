const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Compilation = @import("../Compilation.zig");
const llvm = @import("llvm/bindings.zig");
const link = @import("../link.zig");
const log = std.log.scoped(.codegen);
const math = std.math;

const Module = @import("../Module.zig");
const TypedValue = @import("../TypedValue.zig");
const Air = @import("../Air.zig");
const Inst = ir.Inst;

const Value = @import("../value.zig").Value;
const Type = @import("../type.zig").Type;

const LazySrcLoc = Module.LazySrcLoc;

pub fn targetTriple(allocator: *Allocator, target: std.Target) ![:0]u8 {
    const llvm_arch = switch (target.cpu.arch) {
        .arm => "arm",
        .armeb => "armeb",
        .aarch64 => "aarch64",
        .aarch64_be => "aarch64_be",
        .aarch64_32 => "aarch64_32",
        .arc => "arc",
        .avr => "avr",
        .bpfel => "bpfel",
        .bpfeb => "bpfeb",
        .csky => "csky",
        .hexagon => "hexagon",
        .mips => "mips",
        .mipsel => "mipsel",
        .mips64 => "mips64",
        .mips64el => "mips64el",
        .msp430 => "msp430",
        .powerpc => "powerpc",
        .powerpcle => "powerpcle",
        .powerpc64 => "powerpc64",
        .powerpc64le => "powerpc64le",
        .r600 => "r600",
        .amdgcn => "amdgcn",
        .riscv32 => "riscv32",
        .riscv64 => "riscv64",
        .sparc => "sparc",
        .sparcv9 => "sparcv9",
        .sparcel => "sparcel",
        .s390x => "s390x",
        .tce => "tce",
        .tcele => "tcele",
        .thumb => "thumb",
        .thumbeb => "thumbeb",
        .i386 => "i386",
        .x86_64 => "x86_64",
        .xcore => "xcore",
        .nvptx => "nvptx",
        .nvptx64 => "nvptx64",
        .le32 => "le32",
        .le64 => "le64",
        .amdil => "amdil",
        .amdil64 => "amdil64",
        .hsail => "hsail",
        .hsail64 => "hsail64",
        .spir => "spir",
        .spir64 => "spir64",
        .kalimba => "kalimba",
        .shave => "shave",
        .lanai => "lanai",
        .wasm32 => "wasm32",
        .wasm64 => "wasm64",
        .renderscript32 => "renderscript32",
        .renderscript64 => "renderscript64",
        .ve => "ve",
        .spu_2 => return error.LLVMBackendDoesNotSupportSPUMarkII,
        .spirv32 => return error.LLVMBackendDoesNotSupportSPIRV,
        .spirv64 => return error.LLVMBackendDoesNotSupportSPIRV,
    };

    const llvm_os = switch (target.os.tag) {
        .freestanding => "unknown",
        .ananas => "ananas",
        .cloudabi => "cloudabi",
        .dragonfly => "dragonfly",
        .freebsd => "freebsd",
        .fuchsia => "fuchsia",
        .ios => "ios",
        .kfreebsd => "kfreebsd",
        .linux => "linux",
        .lv2 => "lv2",
        .macos => "macosx",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .solaris => "solaris",
        .windows => "windows",
        .zos => "zos",
        .haiku => "haiku",
        .minix => "minix",
        .rtems => "rtems",
        .nacl => "nacl",
        .aix => "aix",
        .cuda => "cuda",
        .nvcl => "nvcl",
        .amdhsa => "amdhsa",
        .ps4 => "ps4",
        .elfiamcu => "elfiamcu",
        .tvos => "tvos",
        .watchos => "watchos",
        .mesa3d => "mesa3d",
        .contiki => "contiki",
        .amdpal => "amdpal",
        .hermit => "hermit",
        .hurd => "hurd",
        .wasi => "wasi",
        .emscripten => "emscripten",
        .uefi => "windows",
        .opencl => return error.LLVMBackendDoesNotSupportOpenCL,
        .glsl450 => return error.LLVMBackendDoesNotSupportGLSL450,
        .vulkan => return error.LLVMBackendDoesNotSupportVulkan,
        .plan9 => return error.LLVMBackendDoesNotSupportPlan9,
        .other => "unknown",
    };

    const llvm_abi = switch (target.abi) {
        .none => "unknown",
        .gnu => "gnu",
        .gnuabin32 => "gnuabin32",
        .gnuabi64 => "gnuabi64",
        .gnueabi => "gnueabi",
        .gnueabihf => "gnueabihf",
        .gnux32 => "gnux32",
        .gnuilp32 => "gnuilp32",
        .code16 => "code16",
        .eabi => "eabi",
        .eabihf => "eabihf",
        .android => "android",
        .musl => "musl",
        .musleabi => "musleabi",
        .musleabihf => "musleabihf",
        .msvc => "msvc",
        .itanium => "itanium",
        .cygnus => "cygnus",
        .coreclr => "coreclr",
        .simulator => "simulator",
        .macabi => "macabi",
    };

    return std.fmt.allocPrintZ(allocator, "{s}-unknown-{s}-{s}", .{ llvm_arch, llvm_os, llvm_abi });
}

pub const Object = struct {
    llvm_module: *const llvm.Module,
    context: *const llvm.Context,
    target_machine: *const llvm.TargetMachine,
    object_pathZ: [:0]const u8,

    pub fn create(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*Object {
        _ = sub_path;
        const self = try allocator.create(Object);
        errdefer allocator.destroy(self);

        const obj_basename = try std.zig.binNameAlloc(allocator, .{
            .root_name = options.root_name,
            .target = options.target,
            .output_mode = .Obj,
        });
        defer allocator.free(obj_basename);

        const o_directory = options.module.?.zig_cache_artifact_directory;
        const object_path = try o_directory.join(allocator, &[_][]const u8{obj_basename});
        defer allocator.free(object_path);

        const object_pathZ = try allocator.dupeZ(u8, object_path);
        errdefer allocator.free(object_pathZ);

        const context = llvm.Context.create();
        errdefer context.dispose();

        initializeLLVMTargets();

        const root_nameZ = try allocator.dupeZ(u8, options.root_name);
        defer allocator.free(root_nameZ);
        const llvm_module = llvm.Module.createWithName(root_nameZ.ptr, context);
        errdefer llvm_module.dispose();

        const llvm_target_triple = try targetTriple(allocator, options.target);
        defer allocator.free(llvm_target_triple);

        var error_message: [*:0]const u8 = undefined;
        var target: *const llvm.Target = undefined;
        if (llvm.Target.getFromTriple(llvm_target_triple.ptr, &target, &error_message).toBool()) {
            defer llvm.disposeMessage(error_message);

            const stderr = std.io.getStdErr().writer();
            try stderr.print(
                \\Zig is expecting LLVM to understand this target: '{s}'
                \\However LLVM responded with: "{s}"
                \\
            ,
                .{ llvm_target_triple, error_message },
            );
            return error.InvalidLLVMTriple;
        }

        const opt_level: llvm.CodeGenOptLevel = if (options.optimize_mode == .Debug) .None else .Aggressive;
        const target_machine = llvm.TargetMachine.create(
            target,
            llvm_target_triple.ptr,
            "",
            "",
            opt_level,
            .Static,
            .Default,
        );
        errdefer target_machine.dispose();

        self.* = .{
            .llvm_module = llvm_module,
            .context = context,
            .target_machine = target_machine,
            .object_pathZ = object_pathZ,
        };
        return self;
    }

    pub fn deinit(self: *Object, allocator: *Allocator) void {
        self.target_machine.dispose();
        self.llvm_module.dispose();
        self.context.dispose();

        allocator.free(self.object_pathZ);
        allocator.destroy(self);
    }

    fn initializeLLVMTargets() void {
        llvm.initializeAllTargets();
        llvm.initializeAllTargetInfos();
        llvm.initializeAllTargetMCs();
        llvm.initializeAllAsmPrinters();
        llvm.initializeAllAsmParsers();
    }

    pub fn flushModule(self: *Object, comp: *Compilation) !void {
        if (comp.verbose_llvm_ir) {
            const dump = self.llvm_module.printToString();
            defer llvm.disposeMessage(dump);

            const stderr = std.io.getStdErr().writer();
            try stderr.writeAll(std.mem.spanZ(dump));
        }

        {
            var error_message: [*:0]const u8 = undefined;
            // verifyModule always allocs the error_message even if there is no error
            defer llvm.disposeMessage(error_message);

            if (self.llvm_module.verify(.ReturnStatus, &error_message).toBool()) {
                const stderr = std.io.getStdErr().writer();
                try stderr.print("broken LLVM module found: {s}\nThis is a bug in the Zig compiler.", .{error_message});
                return error.BrokenLLVMModule;
            }
        }

        var error_message: [*:0]const u8 = undefined;
        if (self.target_machine.emitToFile(
            self.llvm_module,
            self.object_pathZ.ptr,
            .ObjectFile,
            &error_message,
        ).toBool()) {
            defer llvm.disposeMessage(error_message);

            const stderr = std.io.getStdErr().writer();
            try stderr.print("LLVM failed to emit file: {s}\n", .{error_message});
            return error.FailedToEmit;
        }
    }

    pub fn updateDecl(self: *Object, module: *Module, decl: *Module.Decl) !void {
        const tracy = trace(@src());
        defer tracy.end();

        var dg: DeclGen = .{
            .object = self,
            .module = module,
            .decl = decl,
            .err_msg = null,
            .gpa = module.gpa,
        };
        dg.genDecl() catch |err| switch (err) {
            error.CodegenFail => {
                decl.analysis = .codegen_failure;
                try module.failed_decls.put(module.gpa, decl, dg.err_msg.?);
                dg.err_msg = null;
                return;
            },
            else => |e| return e,
        };
    }
};

pub const DeclGen = struct {
    object: *Object,
    module: *Module,
    decl: *Module.Decl,
    err_msg: ?*Module.ErrorMsg,

    gpa: *Allocator,

    fn todo(self: *DeclGen, comptime format: []const u8, args: anytype) error{ OutOfMemory, CodegenFail } {
        @setCold(true);
        assert(self.err_msg == null);
        const src_loc = @as(LazySrcLoc, .{ .node_offset = 0 }).toSrcLocWithDecl(self.decl);
        self.err_msg = try Module.ErrorMsg.create(self.gpa, src_loc, "TODO (LLVM): " ++ format, args);
        return error.CodegenFail;
    }

    fn llvmModule(self: *DeclGen) *const llvm.Module {
        return self.object.llvm_module;
    }

    fn context(self: *DeclGen) *const llvm.Context {
        return self.object.context;
    }

    fn genDecl(self: *DeclGen) !void {
        const decl = self.decl;
        assert(decl.has_tv);

        log.debug("gen: {s} type: {}, value: {}", .{ decl.name, decl.ty, decl.val });

        if (decl.val.castTag(.function)) |func_payload| {
            const func = func_payload.data;

            const llvm_func = try self.resolveLLVMFunction(func.owner_decl);

            // This gets the LLVM values from the function and stores them in `self.args`.
            const fn_param_len = func.owner_decl.ty.fnParamLen();
            var args = try self.gpa.alloc(*const llvm.Value, fn_param_len);

            for (args) |*arg, i| {
                arg.* = llvm.getParam(llvm_func, @intCast(c_uint, i));
            }

            // We remove all the basic blocks of a function to support incremental
            // compilation!
            // TODO: remove all basic blocks if functions can have more than one
            if (llvm_func.getFirstBasicBlock()) |bb| {
                bb.deleteBasicBlock();
            }

            const builder = self.context().createBuilder();

            const entry_block = self.context().appendBasicBlock(llvm_func, "Entry");
            builder.positionBuilderAtEnd(entry_block);

            var fg: FuncGen = .{
                .dg = self,
                .builder = builder,
                .args = args,
                .arg_index = 0,
                .func_inst_table = .{},
                .entry_block = entry_block,
                .latest_alloca_inst = null,
                .llvm_func = llvm_func,
                .blocks = .{},
            };
            defer fg.deinit();

            try fg.genBody(func.body);
        } else if (decl.val.castTag(.extern_fn)) |extern_fn| {
            _ = try self.resolveLLVMFunction(extern_fn.data);
        } else {
            _ = try self.resolveGlobalDecl(decl);
        }
    }

    /// If the llvm function does not exist, create it
    fn resolveLLVMFunction(self: *DeclGen, func: *Module.Decl) !*const llvm.Value {
        // TODO: do we want to store this in our own datastructure?
        if (self.llvmModule().getNamedFunction(func.name)) |llvm_fn| return llvm_fn;

        assert(func.has_tv);
        const zig_fn_type = func.ty;
        const return_type = zig_fn_type.fnReturnType();

        const fn_param_len = zig_fn_type.fnParamLen();

        const fn_param_types = try self.gpa.alloc(Type, fn_param_len);
        defer self.gpa.free(fn_param_types);
        zig_fn_type.fnParamTypes(fn_param_types);

        const llvm_param = try self.gpa.alloc(*const llvm.Type, fn_param_len);
        defer self.gpa.free(llvm_param);

        for (fn_param_types) |fn_param, i| {
            llvm_param[i] = try self.getLLVMType(fn_param);
        }

        const fn_type = llvm.Type.functionType(
            try self.getLLVMType(return_type),
            if (fn_param_len == 0) null else llvm_param.ptr,
            @intCast(c_uint, fn_param_len),
            .False,
        );
        const llvm_fn = self.llvmModule().addFunction(func.name, fn_type);

        if (return_type.tag() == .noreturn) {
            self.addFnAttr(llvm_fn, "noreturn");
        }

        return llvm_fn;
    }

    fn resolveGlobalDecl(self: *DeclGen, decl: *Module.Decl) error{ OutOfMemory, CodegenFail }!*const llvm.Value {
        // TODO: do we want to store this in our own datastructure?
        if (self.llvmModule().getNamedGlobal(decl.name)) |val| return val;

        assert(decl.has_tv);

        // TODO: remove this redundant `getLLVMType`, it is also called in `genTypedValue`.
        const llvm_type = try self.getLLVMType(decl.ty);
        const val = try self.genTypedValue(.{ .ty = decl.ty, .val = decl.val }, null);
        const global = self.llvmModule().addGlobal(llvm_type, decl.name);
        llvm.setInitializer(global, val);

        // TODO ask the Decl if it is const
        // https://github.com/ziglang/zig/issues/7582

        return global;
    }

    fn getLLVMType(self: *DeclGen, t: Type) error{ OutOfMemory, CodegenFail }!*const llvm.Type {
        log.debug("getLLVMType for {}", .{t});
        switch (t.zigTypeTag()) {
            .Void => return self.context().voidType(),
            .NoReturn => return self.context().voidType(),
            .Int => {
                const info = t.intInfo(self.module.getTarget());
                return self.context().intType(info.bits);
            },
            .Bool => return self.context().intType(1),
            .Pointer => {
                if (t.isSlice()) {
                    return self.todo("implement slices", .{});
                } else {
                    const elem_type = try self.getLLVMType(t.elemType());
                    return elem_type.pointerType(0);
                }
            },
            .Array => {
                const elem_type = try self.getLLVMType(t.elemType());
                return elem_type.arrayType(@intCast(c_uint, t.abiSize(self.module.getTarget())));
            },
            .Optional => {
                if (!t.isPtrLikeOptional()) {
                    var buf: Type.Payload.ElemType = undefined;
                    const child_type = t.optionalChild(&buf);

                    var optional_types: [2]*const llvm.Type = .{
                        try self.getLLVMType(child_type),
                        self.context().intType(1),
                    };
                    return self.context().structType(&optional_types, 2, .False);
                } else {
                    return self.todo("implement optional pointers as actual pointers", .{});
                }
            },
            .ComptimeInt => unreachable,
            .ComptimeFloat => unreachable,
            .Type => unreachable,
            .Undefined => unreachable,
            .Null => unreachable,
            .EnumLiteral => unreachable,

            .BoundFn => @panic("TODO remove BoundFn from the language"),

            .Float,
            .Struct,
            .ErrorUnion,
            .ErrorSet,
            .Enum,
            .Union,
            .Fn,
            .Opaque,
            .Frame,
            .AnyFrame,
            .Vector,
            => return self.todo("implement getLLVMType for type '{}'", .{t}),
        }
    }

    // TODO: figure out a way to remove the FuncGen argument
    fn genTypedValue(self: *DeclGen, tv: TypedValue, fg: ?*FuncGen) error{ OutOfMemory, CodegenFail }!*const llvm.Value {
        const llvm_type = try self.getLLVMType(tv.ty);

        if (tv.val.isUndef())
            return llvm_type.getUndef();

        switch (tv.ty.zigTypeTag()) {
            .Bool => return if (tv.val.toBool()) llvm_type.constAllOnes() else llvm_type.constNull(),
            .Int => {
                var bigint_space: Value.BigIntSpace = undefined;
                const bigint = tv.val.toBigInt(&bigint_space);

                if (bigint.eqZero()) return llvm_type.constNull();

                if (bigint.limbs.len != 1) {
                    return self.todo("implement bigger bigint", .{});
                }
                const llvm_int = llvm_type.constInt(bigint.limbs[0], .False);
                if (!bigint.positive) {
                    return llvm.constNeg(llvm_int);
                }
                return llvm_int;
            },
            .Pointer => switch (tv.val.tag()) {
                .decl_ref => {
                    const decl = tv.val.castTag(.decl_ref).?.data;
                    const val = try self.resolveGlobalDecl(decl);

                    const usize_type = try self.getLLVMType(Type.initTag(.usize));

                    // TODO: second index should be the index into the memory!
                    var indices: [2]*const llvm.Value = .{
                        usize_type.constNull(),
                        usize_type.constNull(),
                    };

                    // TODO: consider using buildInBoundsGEP2 for opaque pointers
                    return fg.?.builder.buildInBoundsGEP(val, &indices, 2, "");
                },
                .ref_val => {
                    const elem_value = tv.val.castTag(.ref_val).?.data;
                    const elem_type = tv.ty.castPointer().?.data;
                    const alloca = fg.?.buildAlloca(try self.getLLVMType(elem_type));
                    _ = fg.?.builder.buildStore(try self.genTypedValue(.{ .ty = elem_type, .val = elem_value }, fg), alloca);
                    return alloca;
                },
                else => return self.todo("implement const of pointer type '{}'", .{tv.ty}),
            },
            .Array => {
                if (tv.val.castTag(.bytes)) |payload| {
                    const zero_sentinel = if (tv.ty.sentinel()) |sentinel| blk: {
                        if (sentinel.tag() == .zero) break :blk true;
                        return self.todo("handle other sentinel values", .{});
                    } else false;

                    return self.context().constString(payload.data.ptr, @intCast(c_uint, payload.data.len), llvm.Bool.fromBool(!zero_sentinel));
                } else {
                    return self.todo("handle more array values", .{});
                }
            },
            .Optional => {
                if (!tv.ty.isPtrLikeOptional()) {
                    var buf: Type.Payload.ElemType = undefined;
                    const child_type = tv.ty.optionalChild(&buf);
                    const llvm_child_type = try self.getLLVMType(child_type);

                    if (tv.val.tag() == .null_value) {
                        var optional_values: [2]*const llvm.Value = .{
                            llvm_child_type.constNull(),
                            self.context().intType(1).constNull(),
                        };
                        return self.context().constStruct(&optional_values, 2, .False);
                    } else {
                        var optional_values: [2]*const llvm.Value = .{
                            try self.genTypedValue(.{ .ty = child_type, .val = tv.val }, fg),
                            self.context().intType(1).constAllOnes(),
                        };
                        return self.context().constStruct(&optional_values, 2, .False);
                    }
                } else {
                    return self.todo("implement const of optional pointer", .{});
                }
            },
            else => return self.todo("implement const of type '{}'", .{tv.ty}),
        }
    }

    // Helper functions
    fn addAttr(self: *DeclGen, val: *const llvm.Value, index: llvm.AttributeIndex, name: []const u8) void {
        const kind_id = llvm.getEnumAttributeKindForName(name.ptr, name.len);
        assert(kind_id != 0);
        const llvm_attr = self.context().createEnumAttribute(kind_id, 0);
        val.addAttributeAtIndex(index, llvm_attr);
    }

    fn addFnAttr(self: *DeclGen, val: *const llvm.Value, attr_name: []const u8) void {
        // TODO: improve this API, `addAttr(-1, attr_name)`
        self.addAttr(val, std.math.maxInt(llvm.AttributeIndex), attr_name);
    }
};

pub const FuncGen = struct {
    dg: *DeclGen,

    builder: *const llvm.Builder,

    /// This stores the LLVM values used in a function, such that they can be
    /// referred to in other instructions. This table is cleared before every function is generated.
    /// TODO: Change this to a stack of Branch. Currently we store all the values from all the blocks
    /// in here, however if a block ends, the instructions can be thrown away.
    func_inst_table: std.AutoHashMapUnmanaged(*Inst, *const llvm.Value),

    /// These fields are used to refer to the LLVM value of the function paramaters in an Arg instruction.
    args: []*const llvm.Value,
    arg_index: usize,

    entry_block: *const llvm.BasicBlock,
    /// This fields stores the last alloca instruction, such that we can append more alloca instructions
    /// to the top of the function.
    latest_alloca_inst: ?*const llvm.Value,

    llvm_func: *const llvm.Value,

    /// This data structure is used to implement breaking to blocks.
    blocks: std.AutoHashMapUnmanaged(*Inst.Block, struct {
        parent_bb: *const llvm.BasicBlock,
        break_bbs: *BreakBasicBlocks,
        break_vals: *BreakValues,
    }),

    const BreakBasicBlocks = std.ArrayListUnmanaged(*const llvm.BasicBlock);
    const BreakValues = std.ArrayListUnmanaged(*const llvm.Value);

    fn deinit(self: *FuncGen) void {
        self.builder.dispose();
        self.func_inst_table.deinit(self.gpa());
        self.gpa().free(self.args);
        self.blocks.deinit(self.gpa());
    }

    fn todo(self: *FuncGen, comptime format: []const u8, args: anytype) error{ OutOfMemory, CodegenFail } {
        @setCold(true);
        return self.dg.todo(format, args);
    }

    fn llvmModule(self: *FuncGen) *const llvm.Module {
        return self.dg.object.llvm_module;
    }

    fn context(self: *FuncGen) *const llvm.Context {
        return self.dg.object.context;
    }

    fn gpa(self: *FuncGen) *Allocator {
        return self.dg.gpa;
    }

    fn resolveInst(self: *FuncGen, inst: *ir.Inst) !*const llvm.Value {
        if (inst.value()) |val| {
            return self.dg.genTypedValue(.{ .ty = inst.ty, .val = val }, self);
        }
        if (self.func_inst_table.get(inst)) |value| return value;

        return self.todo("implement global llvm values (or the value is not in the func_inst_table table)", .{});
    }

    fn genBody(self: *FuncGen, body: ir.Body) error{ OutOfMemory, CodegenFail }!void {
        for (body.instructions) |inst| {
            const opt_value = switch (inst.tag) {
                .add => try self.genAdd(inst.castTag(.add).?),
                .alloc => try self.genAlloc(inst.castTag(.alloc).?),
                .arg => try self.genArg(inst.castTag(.arg).?),
                .bitcast => try self.genBitCast(inst.castTag(.bitcast).?),
                .block => try self.genBlock(inst.castTag(.block).?),
                .br => try self.genBr(inst.castTag(.br).?),
                .breakpoint => try self.genBreakpoint(inst.castTag(.breakpoint).?),
                .br_void => try self.genBrVoid(inst.castTag(.br_void).?),
                .call => try self.genCall(inst.castTag(.call).?),
                .cmp_eq => try self.genCmp(inst.castTag(.cmp_eq).?, .eq),
                .cmp_gt => try self.genCmp(inst.castTag(.cmp_gt).?, .gt),
                .cmp_gte => try self.genCmp(inst.castTag(.cmp_gte).?, .gte),
                .cmp_lt => try self.genCmp(inst.castTag(.cmp_lt).?, .lt),
                .cmp_lte => try self.genCmp(inst.castTag(.cmp_lte).?, .lte),
                .cmp_neq => try self.genCmp(inst.castTag(.cmp_neq).?, .neq),
                .condbr => try self.genCondBr(inst.castTag(.condbr).?),
                .intcast => try self.genIntCast(inst.castTag(.intcast).?),
                .is_non_null => try self.genIsNonNull(inst.castTag(.is_non_null).?, false),
                .is_non_null_ptr => try self.genIsNonNull(inst.castTag(.is_non_null_ptr).?, true),
                .is_null => try self.genIsNull(inst.castTag(.is_null).?, false),
                .is_null_ptr => try self.genIsNull(inst.castTag(.is_null_ptr).?, true),
                .load => try self.genLoad(inst.castTag(.load).?),
                .loop => try self.genLoop(inst.castTag(.loop).?),
                .not => try self.genNot(inst.castTag(.not).?),
                .ret => try self.genRet(inst.castTag(.ret).?),
                .retvoid => self.genRetVoid(inst.castTag(.retvoid).?),
                .store => try self.genStore(inst.castTag(.store).?),
                .sub => try self.genSub(inst.castTag(.sub).?),
                .unreach => self.genUnreach(inst.castTag(.unreach).?),
                .optional_payload => try self.genOptionalPayload(inst.castTag(.optional_payload).?, false),
                .optional_payload_ptr => try self.genOptionalPayload(inst.castTag(.optional_payload_ptr).?, true),
                .dbg_stmt => blk: {
                    // TODO: implement debug info
                    break :blk null;
                },
                else => |tag| return self.todo("implement TZIR instruction: {}", .{tag}),
            };
            if (opt_value) |val| try self.func_inst_table.putNoClobber(self.gpa(), inst, val);
        }
    }

    fn genCall(self: *FuncGen, inst: *Inst.Call) !?*const llvm.Value {
        if (inst.func.value()) |func_value| {
            const fn_decl = if (func_value.castTag(.extern_fn)) |extern_fn|
                extern_fn.data
            else if (func_value.castTag(.function)) |func_payload|
                func_payload.data.owner_decl
            else
                unreachable;

            assert(fn_decl.has_tv);
            const zig_fn_type = fn_decl.ty;
            const llvm_fn = try self.dg.resolveLLVMFunction(fn_decl);

            const num_args = inst.args.len;

            const llvm_param_vals = try self.gpa().alloc(*const llvm.Value, num_args);
            defer self.gpa().free(llvm_param_vals);

            for (inst.args) |arg, i| {
                llvm_param_vals[i] = try self.resolveInst(arg);
            }

            // TODO: LLVMBuildCall2 handles opaque function pointers, according to llvm docs
            //       Do we need that?
            const call = self.builder.buildCall(
                llvm_fn,
                if (num_args == 0) null else llvm_param_vals.ptr,
                @intCast(c_uint, num_args),
                "",
            );

            const return_type = zig_fn_type.fnReturnType();
            if (return_type.tag() == .noreturn) {
                _ = self.builder.buildUnreachable();
            }

            // No need to store the LLVM value if the return type is void or noreturn
            if (!return_type.hasCodeGenBits()) return null;

            return call;
        } else {
            return self.todo("implement calling runtime known function pointer", .{});
        }
    }

    fn genRetVoid(self: *FuncGen, inst: *Inst.NoOp) ?*const llvm.Value {
        _ = inst;
        _ = self.builder.buildRetVoid();
        return null;
    }

    fn genRet(self: *FuncGen, inst: *Inst.UnOp) !?*const llvm.Value {
        if (!inst.operand.ty.hasCodeGenBits()) {
            // TODO: in astgen these instructions should turn into `retvoid` instructions.
            _ = self.builder.buildRetVoid();
            return null;
        }
        _ = self.builder.buildRet(try self.resolveInst(inst.operand));
        return null;
    }

    fn genCmp(self: *FuncGen, inst: *Inst.BinOp, op: math.CompareOperator) !?*const llvm.Value {
        const lhs = try self.resolveInst(inst.lhs);
        const rhs = try self.resolveInst(inst.rhs);

        if (!inst.base.ty.isInt())
            if (inst.base.ty.tag() != .bool)
                return self.todo("implement 'genCmp' for type {}", .{inst.base.ty});

        const is_signed = inst.base.ty.isSignedInt();
        const operation = switch (op) {
            .eq => .EQ,
            .neq => .NE,
            .lt => @as(llvm.IntPredicate, if (is_signed) .SLT else .ULT),
            .lte => @as(llvm.IntPredicate, if (is_signed) .SLE else .ULE),
            .gt => @as(llvm.IntPredicate, if (is_signed) .SGT else .UGT),
            .gte => @as(llvm.IntPredicate, if (is_signed) .SGE else .UGE),
        };

        return self.builder.buildICmp(operation, lhs, rhs, "");
    }

    fn genBlock(self: *FuncGen, inst: *Inst.Block) !?*const llvm.Value {
        const parent_bb = self.context().createBasicBlock("Block");

        // 5 breaks to a block seems like a reasonable default.
        var break_bbs = try BreakBasicBlocks.initCapacity(self.gpa(), 5);
        var break_vals = try BreakValues.initCapacity(self.gpa(), 5);
        try self.blocks.putNoClobber(self.gpa(), inst, .{
            .parent_bb = parent_bb,
            .break_bbs = &break_bbs,
            .break_vals = &break_vals,
        });
        defer {
            assert(self.blocks.remove(inst));
            break_bbs.deinit(self.gpa());
            break_vals.deinit(self.gpa());
        }

        try self.genBody(inst.body);

        self.llvm_func.appendExistingBasicBlock(parent_bb);
        self.builder.positionBuilderAtEnd(parent_bb);

        // If the block does not return a value, we dont have to create a phi node.
        if (!inst.base.ty.hasCodeGenBits()) return null;

        const phi_node = self.builder.buildPhi(try self.dg.getLLVMType(inst.base.ty), "");
        phi_node.addIncoming(
            break_vals.items.ptr,
            break_bbs.items.ptr,
            @intCast(c_uint, break_vals.items.len),
        );
        return phi_node;
    }

    fn genBr(self: *FuncGen, inst: *Inst.Br) !?*const llvm.Value {
        var block = self.blocks.get(inst.block).?;

        // If the break doesn't break a value, then we don't have to add
        // the values to the lists.
        if (!inst.operand.ty.hasCodeGenBits()) {
            // TODO: in astgen these instructions should turn into `br_void` instructions.
            _ = self.builder.buildBr(block.parent_bb);
        } else {
            const val = try self.resolveInst(inst.operand);

            // For the phi node, we need the basic blocks and the values of the
            // break instructions.
            try block.break_bbs.append(self.gpa(), self.builder.getInsertBlock());
            try block.break_vals.append(self.gpa(), val);

            _ = self.builder.buildBr(block.parent_bb);
        }
        return null;
    }

    fn genBrVoid(self: *FuncGen, inst: *Inst.BrVoid) !?*const llvm.Value {
        var block = self.blocks.get(inst.block).?;
        _ = self.builder.buildBr(block.parent_bb);
        return null;
    }

    fn genCondBr(self: *FuncGen, inst: *Inst.CondBr) !?*const llvm.Value {
        const condition_value = try self.resolveInst(inst.condition);

        const then_block = self.context().appendBasicBlock(self.llvm_func, "Then");
        const else_block = self.context().appendBasicBlock(self.llvm_func, "Else");
        {
            const prev_block = self.builder.getInsertBlock();
            defer self.builder.positionBuilderAtEnd(prev_block);

            self.builder.positionBuilderAtEnd(then_block);
            try self.genBody(inst.then_body);

            self.builder.positionBuilderAtEnd(else_block);
            try self.genBody(inst.else_body);
        }
        _ = self.builder.buildCondBr(condition_value, then_block, else_block);
        return null;
    }

    fn genLoop(self: *FuncGen, inst: *Inst.Loop) !?*const llvm.Value {
        const loop_block = self.context().appendBasicBlock(self.llvm_func, "Loop");
        _ = self.builder.buildBr(loop_block);

        self.builder.positionBuilderAtEnd(loop_block);
        try self.genBody(inst.body);

        _ = self.builder.buildBr(loop_block);
        return null;
    }

    fn genNot(self: *FuncGen, inst: *Inst.UnOp) !?*const llvm.Value {
        return self.builder.buildNot(try self.resolveInst(inst.operand), "");
    }

    fn genUnreach(self: *FuncGen, inst: *Inst.NoOp) ?*const llvm.Value {
        _ = inst;
        _ = self.builder.buildUnreachable();
        return null;
    }

    fn genIsNonNull(self: *FuncGen, inst: *Inst.UnOp, operand_is_ptr: bool) !?*const llvm.Value {
        const operand = try self.resolveInst(inst.operand);

        if (operand_is_ptr) {
            const index_type = self.context().intType(32);

            var indices: [2]*const llvm.Value = .{
                index_type.constNull(),
                index_type.constInt(1, .False),
            };

            return self.builder.buildLoad(self.builder.buildInBoundsGEP(operand, &indices, 2, ""), "");
        } else {
            return self.builder.buildExtractValue(operand, 1, "");
        }
    }

    fn genIsNull(self: *FuncGen, inst: *Inst.UnOp, operand_is_ptr: bool) !?*const llvm.Value {
        return self.builder.buildNot((try self.genIsNonNull(inst, operand_is_ptr)).?, "");
    }

    fn genOptionalPayload(self: *FuncGen, inst: *Inst.UnOp, operand_is_ptr: bool) !?*const llvm.Value {
        const operand = try self.resolveInst(inst.operand);

        if (operand_is_ptr) {
            const index_type = self.context().intType(32);

            var indices: [2]*const llvm.Value = .{
                index_type.constNull(),
                index_type.constNull(),
            };

            return self.builder.buildInBoundsGEP(operand, &indices, 2, "");
        } else {
            return self.builder.buildExtractValue(operand, 0, "");
        }
    }

    fn genAdd(self: *FuncGen, inst: *Inst.BinOp) !?*const llvm.Value {
        const lhs = try self.resolveInst(inst.lhs);
        const rhs = try self.resolveInst(inst.rhs);

        if (!inst.base.ty.isInt())
            return self.todo("implement 'genAdd' for type {}", .{inst.base.ty});

        return if (inst.base.ty.isSignedInt())
            self.builder.buildNSWAdd(lhs, rhs, "")
        else
            self.builder.buildNUWAdd(lhs, rhs, "");
    }

    fn genSub(self: *FuncGen, inst: *Inst.BinOp) !?*const llvm.Value {
        const lhs = try self.resolveInst(inst.lhs);
        const rhs = try self.resolveInst(inst.rhs);

        if (!inst.base.ty.isInt())
            return self.todo("implement 'genSub' for type {}", .{inst.base.ty});

        return if (inst.base.ty.isSignedInt())
            self.builder.buildNSWSub(lhs, rhs, "")
        else
            self.builder.buildNUWSub(lhs, rhs, "");
    }

    fn genIntCast(self: *FuncGen, inst: *Inst.UnOp) !?*const llvm.Value {
        const val = try self.resolveInst(inst.operand);

        const signed = inst.base.ty.isSignedInt();
        // TODO: Should we use intcast here or just a simple bitcast?
        //       LLVM does truncation vs bitcast (+signed extension) in the intcast depending on the sizes
        return self.builder.buildIntCast2(val, try self.dg.getLLVMType(inst.base.ty), llvm.Bool.fromBool(signed), "");
    }

    fn genBitCast(self: *FuncGen, inst: *Inst.UnOp) !?*const llvm.Value {
        const val = try self.resolveInst(inst.operand);
        const dest_type = try self.dg.getLLVMType(inst.base.ty);

        return self.builder.buildBitCast(val, dest_type, "");
    }

    fn genArg(self: *FuncGen, inst: *Inst.Arg) !?*const llvm.Value {
        const arg_val = self.args[self.arg_index];
        self.arg_index += 1;

        const ptr_val = self.buildAlloca(try self.dg.getLLVMType(inst.base.ty));
        _ = self.builder.buildStore(arg_val, ptr_val);
        return self.builder.buildLoad(ptr_val, "");
    }

    fn genAlloc(self: *FuncGen, inst: *Inst.NoOp) !?*const llvm.Value {
        // buildAlloca expects the pointee type, not the pointer type, so assert that
        // a Payload.PointerSimple is passed to the alloc instruction.
        const pointee_type = inst.base.ty.castPointer().?.data;

        // TODO: figure out a way to get the name of the var decl.
        // TODO: set alignment and volatile
        return self.buildAlloca(try self.dg.getLLVMType(pointee_type));
    }

    /// Use this instead of builder.buildAlloca, because this function makes sure to
    /// put the alloca instruction at the top of the function!
    fn buildAlloca(self: *FuncGen, t: *const llvm.Type) *const llvm.Value {
        const prev_block = self.builder.getInsertBlock();
        defer self.builder.positionBuilderAtEnd(prev_block);

        if (self.latest_alloca_inst) |latest_alloc| {
            // builder.positionBuilder adds it before the instruction,
            // but we want to put it after the last alloca instruction.
            self.builder.positionBuilder(self.entry_block, latest_alloc.getNextInstruction().?);
        } else {
            // There might have been other instructions emitted before the
            // first alloca has been generated. However the alloca should still
            // be first in the function.
            if (self.entry_block.getFirstInstruction()) |first_inst| {
                self.builder.positionBuilder(self.entry_block, first_inst);
            }
        }

        const val = self.builder.buildAlloca(t, "");
        self.latest_alloca_inst = val;
        return val;
    }

    fn genStore(self: *FuncGen, inst: *Inst.BinOp) !?*const llvm.Value {
        const val = try self.resolveInst(inst.rhs);
        const ptr = try self.resolveInst(inst.lhs);
        _ = self.builder.buildStore(val, ptr);
        return null;
    }

    fn genLoad(self: *FuncGen, inst: *Inst.UnOp) !?*const llvm.Value {
        const ptr_val = try self.resolveInst(inst.operand);
        return self.builder.buildLoad(ptr_val, "");
    }

    fn genBreakpoint(self: *FuncGen, inst: *Inst.NoOp) !?*const llvm.Value {
        _ = inst;
        const llvn_fn = self.getIntrinsic("llvm.debugtrap");
        _ = self.builder.buildCall(llvn_fn, null, 0, "");
        return null;
    }

    fn getIntrinsic(self: *FuncGen, name: []const u8) *const llvm.Value {
        const id = llvm.lookupIntrinsicID(name.ptr, name.len);
        assert(id != 0);
        // TODO: add support for overload intrinsics by passing the prefix of the intrinsic
        //       to `lookupIntrinsicID` and then passing the correct types to
        //       `getIntrinsicDeclaration`
        return self.llvmModule().getIntrinsicDeclaration(id, null, 0);
    }
};
