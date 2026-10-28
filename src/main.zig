const std = @import("std");
const core_audio = @import("core_audio");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const devices = try core_audio.loadInputDeviceIds(allocator);

    std.debug.print("Found {} audio input devices:\n", .{devices.len});
    for (devices) |device_id| {
        const name = try core_audio.loadDeviceName(allocator, device_id);
        const uid = try core_audio.loadDeviceUid(allocator, device_id);

        std.debug.print(
            "AudioDeviceID = {d}, Name = {s}, UID = {s}\n",
            .{ device_id, name, uid },
        );
    }
}

test {
    _ = @import("preferred_input.zig");
}
