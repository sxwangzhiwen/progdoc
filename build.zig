const Builder = @import("std").build.Builder;
const std = @import("std");

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("progdoc", "progdoc.zig");
    lib.setBuildMode(mode);
    lib.install();

    const exe = b.addExecutable("example", "./example/main.zig");
    exe.setBuildMode(mode);
    exe.addPackage(std.build.Pkg{
        .name = "progdoc",
        .source = .{ .path = "./progdoc.zig" },
        .dependencies = &[_]std.build.Pkg{},
    });
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "run example");
    run_step.dependOn(&run_cmd.step);

    var main_tests = b.addTest("progdoc.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
