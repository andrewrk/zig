//! SPIR-V Spec documentation: https://www.khronos.org/registry/spir-v/specs/unified1/SPIRV.html
//! According to above documentation, a SPIR-V module has the following logical layout:
//! Header.
//! OpCapability instructions.
//! OpExtension instructions.
//! OpExtInstImport instructions.
//! A single OpMemoryModel instruction.
//! All entry points, declared with OpEntryPoint instructions.
//! All execution-mode declarators; OpExecutionMode and OpExecutionModeId instructions.
//! Debug instructions:
//! - First, OpString, OpSourceExtension, OpSource, OpSourceContinued (no forward references).
//! - OpName and OpMemberName instructions.
//! - OpModuleProcessed instructions.
//! All annotation (decoration) instructions.
//! All type declaration instructions, constant instructions, global variable declarations, (preferrably) OpUndef instructions.
//! All function declarations without a body (extern functions presumably).
//! All regular functions.

// Because SPIR-V requires re-compilation anyway, and so hot swapping will not work
// anyway, we simply generate all the code in flushModule. This keeps
// things considerably simpler.

const SpirV = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.link);

const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const link = @import("../link.zig");
const codegen = @import("../codegen/spirv.zig");
const Word = codegen.Word;
const ResultId = codegen.ResultId;
const trace = @import("../tracy.zig").trace;
const build_options = @import("build_options");
const spec = @import("../codegen/spirv/spec.zig");
const Air = @import("../Air.zig");
const Liveness = @import("../Liveness.zig");

// TODO: Should this struct be used at all rather than just a hashmap of aux data for every decl?
pub const FnData = struct {
    // We're going to fill these in flushModule, and we're going to fill them unconditionally,
    // so just set it to undefined.
    id: ResultId = undefined,
};

base: link.File,

/// This linker backend does not try to incrementally link output SPIR-V code.
/// Instead, it tracks all declarations in this table, and iterates over it
/// in the flush function.
decl_table: std.AutoArrayHashMapUnmanaged(*Module.Decl, void) = .{},

pub fn createEmpty(gpa: *Allocator, options: link.Options) !*SpirV {
    const spirv = try gpa.create(SpirV);
    spirv.* = .{
        .base = .{
            .tag = .spirv,
            .options = options,
            .file = null,
            .allocator = gpa,
        },
    };

    // TODO: Figure out where to put all of these
    switch (options.target.cpu.arch) {
        .spirv32, .spirv64 => {},
        else => return error.TODOArchNotSupported,
    }

    switch (options.target.os.tag) {
        .opencl, .glsl450, .vulkan => {},
        else => return error.TODOOsNotSupported,
    }

    if (options.target.abi != .none) {
        return error.TODOAbiNotSupported;
    }

    return spirv;
}

pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*SpirV {
    assert(options.object_format == .spirv);

    if (options.use_llvm) return error.LLVM_BackendIsTODO_ForSpirV; // TODO: LLVM Doesn't support SpirV at all.
    if (options.use_lld) return error.LLD_LinkingIsTODO_ForSpirV; // TODO: LLD Doesn't support SpirV at all.

    // TODO: read the file and keep vaild parts instead of truncating
    const file = try options.emit.?.directory.handle.createFile(sub_path, .{ .truncate = true, .read = true });
    errdefer file.close();

    const spirv = try createEmpty(allocator, options);
    errdefer spirv.base.destroy();

    spirv.base.file = file;
    return spirv;
}

pub fn deinit(self: *SpirV) void {
    self.decl_table.deinit(self.base.allocator);
}

pub fn updateFunc(self: *SpirV, module: *Module, func: *Module.Fn, air: Air, liveness: Liveness) !void {
    if (build_options.skip_non_native) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }
    _ = module;
    // Keep track of all decls so we can iterate over them on flush().
    _ = try self.decl_table.getOrPut(self.base.allocator, func.owner_decl);

    _ = air;
    _ = liveness;
    @panic("TODO SPIR-V needs to keep track of Air and Liveness so it can use them later");
}

pub fn updateDecl(self: *SpirV, module: *Module, decl: *Module.Decl) !void {
    if (build_options.skip_non_native) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }
    _ = module;
    // Keep track of all decls so we can iterate over them on flush().
    _ = try self.decl_table.getOrPut(self.base.allocator, decl);
}

pub fn updateDeclExports(
    self: *SpirV,
    module: *Module,
    decl: *const Module.Decl,
    exports: []const *Module.Export,
) !void {
    _ = self;
    _ = module;
    _ = decl;
    _ = exports;
}

pub fn freeDecl(self: *SpirV, decl: *Module.Decl) void {
    assert(self.decl_table.swapRemove(decl));
}

pub fn flush(self: *SpirV, comp: *Compilation) !void {
    if (build_options.have_llvm and self.base.options.use_lld) {
        return error.LLD_LinkingIsTODO_ForSpirV; // TODO: LLD Doesn't support SpirV at all.
    } else {
        return self.flushModule(comp);
    }
}

pub fn flushModule(self: *SpirV, comp: *Compilation) !void {
    if (build_options.skip_non_native) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }

    const tracy = trace(@src());
    defer tracy.end();

    const module = self.base.options.module.?;
    const target = comp.getTarget();

    var spv = codegen.SPIRVModule.init(self.base.allocator, module);
    defer spv.deinit();

    // Allocate an ID for every declaration before generating code,
    // so that we can access them before processing them.
    // TODO: We're allocating an ID unconditionally now, are there
    // declarations which don't generate a result?
    // TODO: fn_link is used here, but thats probably not the right field. It will work anyway though.
    {
        for (self.decl_table.keys()) |decl| {
            if (!decl.has_tv) continue;

            decl.fn_link.spirv.id = spv.allocResultId();
        }
    }

    // Now, actually generate the code for all declarations.
    {
        var decl_gen = codegen.DeclGen.init(&spv);
        defer decl_gen.deinit();

        for (self.decl_table.keys()) |decl| {
            if (!decl.has_tv) continue;

            if (try decl_gen.gen(decl)) |msg| {
                try module.failed_decls.put(module.gpa, decl, msg);
                return; // TODO: Attempt to generate more decls?
            }
        }
    }

    try writeCapabilities(&spv.binary.capabilities_and_extensions, target);
    try writeMemoryModel(&spv.binary.capabilities_and_extensions, target);

    const header = [_]Word{
        spec.magic_number,
        (spec.version.major << 16) | (spec.version.minor << 8),
        0, // TODO: Register Zig compiler magic number.
        spv.resultIdBound(),
        0, // Schema (currently reserved for future use in the SPIR-V spec).
    };

    // Note: The order of adding sections to the final binary
    // follows the SPIR-V logical module format!
    const buffers = &[_][]const Word{
        &header,
        spv.binary.capabilities_and_extensions.items,
        spv.binary.debug_strings.items,
        spv.binary.types_globals_constants.items,
        spv.binary.fn_decls.items,
    };

    var iovc_buffers: [buffers.len]std.os.iovec_const = undefined;
    for (iovc_buffers) |*iovc, i| {
        const bytes = std.mem.sliceAsBytes(buffers[i]);
        iovc.* = .{ .iov_base = bytes.ptr, .iov_len = bytes.len };
    }

    var file_size: u64 = 0;
    for (iovc_buffers) |iov| {
        file_size += iov.iov_len;
    }

    const file = self.base.file.?;
    try file.seekTo(0);
    try file.setEndPos(file_size);
    try file.pwritevAll(&iovc_buffers, 0);
}

fn writeCapabilities(binary: *std.ArrayList(Word), target: std.Target) !void {
    // TODO: Integrate with a hypothetical feature system
    const cap: spec.Capability = switch (target.os.tag) {
        .opencl => .Kernel,
        .glsl450 => .Shader,
        .vulkan => .VulkanMemoryModel,
        else => unreachable, // TODO
    };

    try codegen.writeInstruction(binary, .OpCapability, &[_]Word{@enumToInt(cap)});
}

fn writeMemoryModel(binary: *std.ArrayList(Word), target: std.Target) !void {
    const addressing_model = switch (target.os.tag) {
        .opencl => switch (target.cpu.arch) {
            .spirv32 => spec.AddressingModel.Physical32,
            .spirv64 => spec.AddressingModel.Physical64,
            else => unreachable, // TODO
        },
        .glsl450, .vulkan => spec.AddressingModel.Logical,
        else => unreachable, // TODO
    };

    const memory_model: spec.MemoryModel = switch (target.os.tag) {
        .opencl => .OpenCL,
        .glsl450 => .GLSL450,
        .vulkan => .Vulkan,
        else => unreachable,
    };

    try codegen.writeInstruction(binary, .OpMemoryModel, &[_]Word{
        @enumToInt(addressing_model), @enumToInt(memory_model),
    });
}
