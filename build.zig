// This repo ships a C ABI first until further notice.
// Keep build entrypoints aligned around the shipped header and exported symbols, not privileged Zig imports.
// Keep the repo-local test roots explicit; the shipped surface stays the C ABI.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/test_unit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const mod_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = unit_mod,
        .filters = b.args orelse &.{},
    });
    mod_tests.use_llvm = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);
    if (b.args != null) {
        run_mod_tests.has_side_effects = true;
    }

    const abi_mod = b.createModule(.{
        .root_source_file = b.path("src/test/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_mod.addIncludePath(b.path("include"));
    const abi_ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_mod.addImport("ffi", abi_ffi_mod);
    const abi_tests = b.addTest(.{
        .name = "test-abi",
        .root_module = abi_mod,
        .filters = b.args orelse &.{},
    });
    abi_tests.use_llvm = true;
    const run_abi_tests = b.addRunArtifact(abi_tests);
    if (b.args != null) {
        run_abi_tests.has_side_effects = true;
    }

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("src/test_integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const integration_tests = b.addTest(.{
        .name = "test-integration",
        .root_module = integration_mod,
        .filters = b.args orelse &.{},
    });
    integration_tests.use_llvm = true;
    const run_integration_tests = b.addRunArtifact(integration_tests);
    if (b.args != null) {
        run_integration_tests.has_side_effects = true;
    }

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

    const ffi_lib = b.addLibrary(.{
        .name = "howl_pty",
        .linkage = .dynamic,
        .root_module = ffi_mod,
    });
    check_step.dependOn(&ffi_lib.step);
    b.installArtifact(ffi_lib);
    b.installFile("include/howl_pty.h", "include/howl_pty.h");
}
