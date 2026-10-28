const std = @import("std");
const core_audio = @import("core_audio");

pub fn main(init: std.process.Init) !void {
    const adapter = core_audio.CoreAudioAdapter{ .allocator = init.arena.allocator() };
    const devices = try adapter.loadDevices();
    defer adapter.freeDevices(devices);

    std.debug.print("Found {} audio input devices:\n", .{devices.len});
    for (devices) |device| {
        std.debug.print(
            "AudioDeviceID = {d}, Name = {s}, UID = {s}\n",
            .{ device.id, device.name, device.uid },
        );
    }
}

test {
    _ = @import("preferred_input.zig");
}
