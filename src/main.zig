const std = @import("std");
const core_audio = @import("core_audio");
const Preferences = @import("preferences.zig").Preferences;
const PreferredInputController = @import("preferred_input.zig").PreferredInputController;
const SignalsController = @import("signals_controller.zig").SignalsController;

// TODO: Replace with the persistent UID of the preferred microphone.
const preferred_uid = "REPLACE_WITH_PREFERRED_DEVICE_UID";

pub fn main(init: std.process.Init) !void {
    const signals_controller = try SignalsController.init();
    const preferences: Preferences = .{ .preferred_uid = preferred_uid };
    const adapter: core_audio.CoreAudioAdapter = .{ .allocator = init.gpa };
    var controller: PreferredInputController = .{
        .core_audio = adapter,
        .preferences = preferences,
    };

    try controller.start();
    defer {
        controller.stop() catch |err| {
            std.log.err("Stopping the preferred input controller failed: {s}", .{@errorName(err)});
            // The listener may still use the controller and its allocator.
            std.process.exit(1);
        };
        std.log.info("Micpin stopped", .{});
    }

    std.log.info("Micpin started", .{});
    const signal = try signals_controller.wait();
    std.log.info("Received SIG{s}; stopping Micpin", .{@tagName(signal)});
}

test {
    _ = @import("preferred_input.zig");
}
