const std = @import("std");
const tests = @import("tests.zig");

pub fn addCases(cases: *tests.StandaloneContext) void {
    cases.add("test/standalone/hello_world/hello.zig");
    cases.addC("test/standalone/hello_world/hello_libc.zig");
    cases.add("test/standalone/cat/main.zig");
    cases.add("test/standalone/guess_number/main.zig");
    cases.add("test/standalone/main_return_error/error_u8.zig");
    cases.add("test/standalone/main_return_error/error_u8_non_zero.zig");
    cases.addBuildFile("test/standalone/main_pkg_path/build.zig", .{});
    cases.addBuildFile("test/standalone/shared_library/build.zig", .{});
    cases.addBuildFile("test/standalone/mix_o_files/build.zig", .{});
    if (std.Target.current.os.tag == .macos) {
        // TODO zld cannot link llvm-ir object files for LTO yet.
        cases.addBuildFile("test/standalone/mix_c_files/build.zig", .{ .build_modes = false, .cross_targets = true });
    } else {
        cases.addBuildFile("test/standalone/mix_c_files/build.zig", .{ .build_modes = true, .cross_targets = true });
    }
    cases.addBuildFile("test/standalone/global_linkage/build.zig", .{});
    cases.addBuildFile("test/standalone/static_c_lib/build.zig", .{});
    cases.addBuildFile("test/standalone/link_interdependent_static_c_libs/build.zig", .{});
    cases.addBuildFile("test/standalone/link_static_lib_as_system_lib/build.zig", .{});
    cases.addBuildFile("test/standalone/link_common_symbols/build.zig", .{});
    cases.addBuildFile("test/standalone/issue_339/build.zig", .{});
    cases.addBuildFile("test/standalone/issue_8550/build.zig", .{});
    cases.addBuildFile("test/standalone/issue_794/build.zig", .{});
    cases.addBuildFile("test/standalone/issue_5825/build.zig", .{});
    cases.addBuildFile("test/standalone/pkg_import/build.zig", .{});
    cases.addBuildFile("test/standalone/use_alias/build.zig", .{});
    cases.addBuildFile("test/standalone/brace_expansion/build.zig", .{});
    cases.addBuildFile("test/standalone/empty_env/build.zig", .{});
    cases.addBuildFile("test/standalone/issue_7030/build.zig", .{});
    if (std.Target.current.os.tag != .wasi) {
        cases.addBuildFile("test/standalone/load_dynamic_library/build.zig", .{});
    }
    if (std.Target.current.cpu.arch == .x86_64) { // TODO add C ABI support for other architectures
        cases.addBuildFile("test/stage1/c_abi/build.zig", .{});
    }
    cases.addBuildFile("test/standalone/c_compiler/build.zig", .{ .build_modes = true, .cross_targets = true });

    // Try to build and run a PIE executable.
    if (std.Target.current.os.tag == .linux) {
        cases.addBuildFile("test/standalone/pie/build.zig", .{});
    }

    // Ensure the development tools are buildable.
    cases.add("tools/gen_spirv_spec.zig");
    cases.add("tools/gen_stubs.zig");
    cases.add("tools/update_clang_options.zig");
    cases.add("tools/update_cpu_features.zig");
    cases.add("tools/update_glibc.zig");
    cases.add("tools/update_spirv_features.zig");
}
