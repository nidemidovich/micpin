const std = @import("std");
const core_audio = @import("core_audio");
const Preferences = @import("preferences.zig").Preferences;

const CoreAudioAdapter = core_audio.CoreAudioAdapter;
const Device = core_audio.Device;

pub const PreferedDeviceEvent = struct {
    id: u32,
    state: PreferedDeviceState,
};

pub const PreferedDeviceState = enum {
    connected,
    disconnected,
};

const EventQueue = std.Io.Queue(PreferedDeviceEvent);

/// Keep the listener at a stable address and retain its UID, queue, io and allocator
/// until the registration is removed and all callbacks have finished.
pub const Listener = struct {
    io: std.Io,

    core_audio: CoreAudioAdapter,
    preferences: Preferences,
    event_queue: *EventQueue,
    connected_device_id: ?u32 = null,
    mutex: std.Io.Mutex = .init,

    pub fn handle(self: *Listener) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const devices = try self.core_audio.loadDevices();
        defer self.core_audio.freeDevices(devices);

        try self.handleSnapshot(devices);
    }

    pub fn onDevicesChanged(self: *Listener) void {
        self.handle() catch |err| switch (err) {
            error.Closed => {}, // Closing the queue is part of shutting down the listener.
            else => std.log.err("Handling device changes failed: {s}", .{@errorName(err)}),
        };
    }

    fn handleSnapshot(self: *Listener, devices: []const Device) !void {
        const preferred_uid = self.preferences.getPreferredUid();
        var connected_id: ?u32 = null;
        for (devices) |device| {
            if (std.mem.eql(u8, device.uid, preferred_uid)) {
                connected_id = device.id;
                break;
            }
        }

        if (connected_id != null and self.connected_device_id == null) {
            try self.event_queue.putOneUncancelable(self.io, .{
                .id = connected_id.?,
                .state = .connected,
            });
        } else if (connected_id == null and self.connected_device_id != null) {
            try self.event_queue.putOneUncancelable(self.io, .{
                .id = self.connected_device_id.?,
                .state = .disconnected,
            });
        }

        self.connected_device_id = connected_id;
    }
};

pub const PreferedDeviceConsumer = struct {
    event_queue: *EventQueue,
    core_audio: CoreAudioAdapter,

    pub fn run(self: *PreferedDeviceConsumer, io: std.Io) !void {
        while (true) {
            const value = self.event_queue.getOne(io) catch |err| switch (err) {
                error.Closed => return,
                else => return err,
            };
            switch (value.state) {
                .connected => self.core_audio.setAsDefaultInput(value.id) catch |err| {
                    std.log.err("Setting the preferred microphone failed: {s}", .{@errorName(err)});
                },
                .disconnected => std.log.debug("Prefered device disconnected\n", .{}),
            }
        }
    }
};

test "an absent preferred microphone does not emit events" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Listener);
    std.testing.refAllDecls(PreferedDeviceConsumer);

    var buffer: [4]PreferedDeviceEvent = undefined;
    var queue: EventQueue = .init(&buffer);
    var listener: Listener = .{
        .io = std.testing.io,
        .core_audio = .{ .allocator = std.testing.allocator },
        .preferences = .{ .preferred_uid = "preferred-mic" },
        .event_queue = &queue,
    };
    const other = [_]Device{.{ .id = 9, .uid = "other-mic", .name = "Other microphone" }};

    try listener.handleSnapshot(&.{});
    try listener.handleSnapshot(&other);
    try listener.handleSnapshot(&.{});

    var events: [4]PreferedDeviceEvent = undefined;

    try std.testing.expectEqual(@as(usize, 0), try queue.get(std.testing.io, &events, 0));
    try std.testing.expect(listener.connected_device_id == null);
}

test "preferred microphone emits only connection and disconnection transitions" {
    // Equal UIDs in different storage must identify the same microphone.
    const preferred_uid = try std.testing.allocator.dupe(u8, "preferred-mic");
    defer std.testing.allocator.free(preferred_uid);

    var buffer: [8]PreferedDeviceEvent = undefined;
    var queue: EventQueue = .init(&buffer);
    var listener: Listener = .{
        .io = std.testing.io,
        .core_audio = .{ .allocator = std.testing.allocator },
        .preferences = .{ .preferred_uid = preferred_uid },
        .event_queue = &queue,
    };
    const microphone: Device = .{ .id = 7, .uid = "preferred-mic", .name = "Microphone" };
    const other: Device = .{ .id = 9, .uid = "other-mic", .name = "Other microphone" };
    const reconnected: Device = .{ .id = 12, .uid = "preferred-mic", .name = "Microphone" };

    try listener.handleSnapshot(&.{microphone});
    try listener.handleSnapshot(&.{microphone});
    try listener.handleSnapshot(&.{ other, microphone });
    try listener.handleSnapshot(&.{other});
    try listener.handleSnapshot(&.{other});
    try listener.handleSnapshot(&.{reconnected});
    try listener.handleSnapshot(&.{ reconnected, other });

    var events: [8]PreferedDeviceEvent = undefined;
    const count = try queue.get(std.testing.io, &events, 0);

    try std.testing.expectEqualSlices(PreferedDeviceEvent, &.{
        .{ .id = 7, .state = .connected },
        .{ .id = 7, .state = .disconnected },
        .{ .id = 12, .state = .connected },
    }, events[0..count]);
    try std.testing.expectEqual(@as(?u32, 12), listener.connected_device_id);
}

test "a closed queue does not advance the observed connection state" {
    var buffer: [1]PreferedDeviceEvent = undefined;
    var queue: EventQueue = .init(&buffer);
    queue.close(std.testing.io);
    var listener: Listener = .{
        .io = std.testing.io,
        .core_audio = .{ .allocator = std.testing.allocator },
        .preferences = .{ .preferred_uid = "preferred-mic" },
        .event_queue = &queue,
    };
    const microphone = [_]Device{.{ .id = 7, .uid = "preferred-mic", .name = "Microphone" }};

    try std.testing.expectError(error.Closed, listener.handleSnapshot(&microphone));
    try std.testing.expect(listener.connected_device_id == null);

    listener.connected_device_id = 7;
    try std.testing.expectError(error.Closed, listener.handleSnapshot(&.{}));
    try std.testing.expectEqual(@as(?u32, 7), listener.connected_device_id);
}
