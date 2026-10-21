const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const core_audio = b.addModule("core_audio", .{
        .root_source_file = b.path("src/core_audio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "c",
                .module = translator.mod,
            },
        },
    });
    core_audio.linkFramework("CoreAudio", .{});
    core_audio.linkFramework("CoreFoundation", .{});

    const exe = b.addExecutable(.{
        .name = "micpin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "core_audio",
                    .module = core_audio,
                },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const core_audio_tests = b.addTest(.{ .root_module = core_audio });
    const run_core_audio_tests = b.addRunArtifact(core_audio_tests);
    test_step.dependOn(&run_core_audio_tests.step);
}
