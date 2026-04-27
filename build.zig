const std = @import("std");

const TransportVariant = enum {
    unix_pty,
    android_pty,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const transport_variant = b.option([]const u8, "transport-variant", "Runtime transport lane for howl-session") orelse "unix_pty";

    const vt_core_dep = b.dependency("vt_core", .{
        .target = target,
        .optimize = optimize,
    });
    const vt_core_mod = vt_core_dep.module("vt_core");

    const mod = b.addModule("howl_session", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("vt_core", vt_core_mod);
    const selected_variant: TransportVariant = if (std.mem.eql(u8, transport_variant, "unix_pty"))
        .unix_pty
    else if (std.mem.eql(u8, transport_variant, "android_pty"))
        .android_pty
    else
        std.debug.panic("unsupported howl-session transport variant: {s}", .{transport_variant});
    const build_options = b.addOptions();
    build_options.addOption(TransportVariant, "transport_variant", selected_variant);
    mod.addOptions("build_options", build_options);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
