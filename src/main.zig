const std = @import("std");
const core_audio = @import("core_audio");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const devices = try core_audio.load_input_device_ids(allocator);

    std.debug.print("Found {} audio input devices:\n", .{devices.len});
    for (devices) |device_id| {
        const name = try core_audio.load_device_name(allocator, device_id);
        const uid = try core_audio.load_device_uid(allocator, device_id);

        std.debug.print(
            "AudioDeviceID = {d}, Name = {s}, UID = {s}\n",
            .{ device_id, name, uid },
        );
    }
}

test {
    _ = @import("consume.zig");
}
