//! Builds the direct native PTY module consumed by howl-headless.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("howl_pty", .{
        .root_source_file = b.path("src/howl_pty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tests = b.addTest(.{ .name = "howl-pty-native", .root_module = module });
    tests.use_llvm = true;

    const check = b.step("check", "Build the direct native PTY");
    check.dependOn(&tests.step);

    const test_step = b.step("test", "Run direct native PTY proofs");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
