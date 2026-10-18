const std = @import("std");

// Build Pic:        zig build -Doptimize=ReleaseSmall
// Run it:           zig build run
// Cross-compile:    zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall
//                   (also aarch64-macos, x86_64-macos, x86_64-linux, aarch64-linux)
// The binary lands in zig-out/bin/.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
                                      .target = target,
                                      .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // `zig build run`. Pic reads from the terminal, so hand it stdin directly.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run Pic");
    run_step.dependOn(&run_cmd.step);
}
