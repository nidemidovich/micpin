const std = @import("std");
const core_audio = @import("core_audio.zig");

pub const Device = struct {
    // Рантайм ID. По сути основной идентификатор, который ходит по Core Audio. Хранить нельзя, т.к. может меняться
    id: u32,
    // Постоянный идентификатор устройства. Можно хранить и получать рантайм ID, пока устройство доступно
    uid: []const u8,
    // Имя устройства
    name: []const u8,
};

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
