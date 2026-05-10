const std = @import("std");

const PtyVariant = enum {
    unix_pty,
    android_pty,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pty_variant = b.option([]const u8, "pty-variant", "pty variant for howl-session") orelse "unix_pty";

    const mod = b.addModule("howl_session", .{
        .root_source_file = b.path("src/howl_session.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const selected_variant: PtyVariant = if (std.mem.eql(u8, pty_variant, "unix_pty"))
        .unix_pty
    else if (std.mem.eql(u8, pty_variant, "android_pty"))
        .android_pty
    else
        std.debug.panic("unsupported howl-session pty variant: {s}", .{pty_variant});

    const module_options = b.addOptions();
    module_options.addOption(PtyVariant, "pty_variant", selected_variant);
    module_options.addOption(bool, "c_abi", false);
    mod.addOptions("session_options", module_options);
    mod.addImport("howl_session", mod);

    const mod_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = mod,
        .filters = b.args orelse &.{},
    });
    mod_tests.use_llvm = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);
    if (b.args != null) {
        run_mod_tests.has_side_effects = true;
    }

    const test_step = b.step("test", "Run all tests");
    const test_unit_step = b.step("test:unit", "Run unit tests");
    const test_unit_build_step = b.step("test:unit:build", "Build unit tests");
    test_unit_build_step.dependOn(&b.addInstallArtifact(mod_tests, .{}).step);
    test_unit_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(test_unit_step);

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/howl_session.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ffi_options = b.addOptions();
    ffi_options.addOption(PtyVariant, "pty_variant", selected_variant);
    ffi_options.addOption(bool, "c_abi", true);
    ffi_mod.addOptions("session_options", ffi_options);
    ffi_mod.addImport("howl_session", ffi_mod);

    const ffi_lib = b.addLibrary(.{
        .name = "howl_session",
        .linkage = .dynamic,
        .root_module = ffi_mod,
    });
    const ffi_build_step = b.step("ffi:build", "Build the howl-session C FFI library");
    ffi_build_step.dependOn(&b.addInstallArtifact(ffi_lib, .{}).step);
    b.installArtifact(ffi_lib);
}
