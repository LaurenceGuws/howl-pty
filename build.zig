// This repo ships a C ABI first until further notice.
// Keep build entrypoints aligned around the shipped header and exported symbols, not privileged Zig imports.
// Keep the repo-local test roots explicit; the shipped surface stays the C ABI.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pty_c_translate = b.addTranslateC(.{
        .root_source_file = b.path("include/howl_pty.h"),
        .target = target,
        .optimize = optimize,
    });
    const pty_c_mod = pty_c_translate.createModule();

    const unit_mod = b.createModule(.{
        .root_source_file = b.path("test_unit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_mod.addImport("howl_pty_c", pty_c_mod);

    const mod_tests = add_test_artifact(b, "test-unit", unit_mod);
    const run_mod_tests = add_test_run_artifact(b, mod_tests);

    const abi_mod = b.createModule(.{
        .root_source_file = b.path("test_abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_mod.addImport("howl_pty_c", pty_c_mod);
    const abi_ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_ffi_mod.addImport("howl_pty_c", pty_c_mod);
    abi_mod.addImport("ffi", abi_ffi_mod);
    const abi_tests = add_test_artifact(b, "test-abi", abi_mod);
    const run_abi_tests = add_test_run_artifact(b, abi_tests);

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test_integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_mod.addImport("howl_pty_c", pty_c_mod);
    const integration_tests = add_test_artifact(b, "test-integration", integration_mod);
    const run_integration_tests = add_test_run_artifact(b, integration_tests);

    const check_step = b.step("check", "Build the shipped PTY ABI without installing it");
    const test_step = b.step("test", "Run all tests");
    const test_abi_step = b.step("test:abi", "Run shipped PTY ABI contract tests");
    const test_abi_build_step = b.step("test:abi:build", "Build shipped PTY ABI contract tests");
    const test_integration_step = b.step("test:integration", "Run PTY integration tests");
    const test_integration_build_step = b.step("test:integration:build", "Build PTY integration tests");
    const test_unit_step = b.step("test:unit", "Run unit tests");
    const test_unit_build_step = b.step("test:unit:build", "Build unit tests");
    test_abi_build_step.dependOn(&abi_tests.step);
    test_abi_step.dependOn(&run_abi_tests.step);
    test_integration_build_step.dependOn(&integration_tests.step);
    test_integration_step.dependOn(&run_integration_tests.step);
    test_unit_build_step.dependOn(&mod_tests.step);
    test_unit_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(test_abi_step);
    test_step.dependOn(test_integration_step);
    test_step.dependOn(test_unit_step);

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/libhowl_pty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ffi_mod.addImport("howl_pty_c", pty_c_mod);

    const ffi_lib = b.addLibrary(.{
        .name = "howl_pty",
        .linkage = .dynamic,
        .root_module = ffi_mod,
    });
    check_step.dependOn(&ffi_lib.step);
    b.installArtifact(ffi_lib);
    b.installFile("include/howl_pty.h", "include/howl_pty.h");
}

fn add_test_artifact(b: *std.Build, name: []const u8, root_module: *std.Build.Module) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .name = name,
        .root_module = root_module,
        .filters = b.args orelse &.{},
    });
    tests.use_llvm = true;
    return tests;
}

fn add_test_run_artifact(b: *std.Build, tests: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run_tests = b.addRunArtifact(tests);
    if (b.args != null) {
        run_tests.has_side_effects = true;
    }
    return run_tests;
}
