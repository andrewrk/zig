const std = @import("std");
const Builder = std.build.Builder;
const CrossTarget = std.zig.CrossTarget;

fn isUnpecifiedTarget(t: CrossTarget) bool {
    return t.cpu_arch == null and t.abi == null and t.os_tag == null;
}
fn isRunnableTarget(t: CrossTarget) bool {
    if (t.isNative()) return true;

    return (t.getOsTag() == std.Target.current.os.tag and
        t.getCpuArch() == std.Target.current.cpu.arch);
}

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const test_step = b.step("test", "Test the program");

    const exe = b.addExecutable("test", "main.zig");
    exe.addCSourceFile("test.c", &[_][]const u8{"-std=c11"});
    exe.setBuildMode(mode);
    exe.linkLibC();
    exe.setTarget(target);
    b.default_step.dependOn(&exe.step);

    if (isRunnableTarget(target)) {
        const run_cmd = exe.run();
        test_step.dependOn(&run_cmd.step);
    } else {
        test_step.dependOn(&exe.step);
    }
}
