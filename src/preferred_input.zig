const std = @import("std");
const core_audio = @import("core_audio");
const objc = @import("objc");
const Preferences = @import("preferences.zig").Preferences;

const CoreAudioAdapter = core_audio.CoreAudioAdapter;
const Device = core_audio.Device;

const PreferedDeviceEvent = struct {
    id: u32,
    state: PreferedDeviceState,
};

const PreferedDeviceState = enum {
    connected,
    disconnected,
};

/// Keep the controller at a stable address and retain its UID and allocator until
/// stop succeeds. The allocator must support use from the dispatch queue.
pub const PreferredInputController = struct {
    // A single pointer is ABI-compatible with HAL's address array and lets
    // zig-objc encode the signature; HAL supplies at least one address.
    const Block = objc.Block(
        struct { controller: *PreferredInputController },
        .{ u32, *const core_audio.AudioObjectPropertyAddress },
        void,
    );

    core_audio: CoreAudioAdapter,
    preferences: Preferences,
    connected_device_id: ?u32 = null,
    queue: core_audio.DeviceChangesQueue = undefined,
    block: *Block.Context = undefined,

    /// Call once, outside the controller queue. The initial check finishes before
    /// returning; device-query failures are logged just like later notifications.
    pub fn start(self: *PreferredInputController) !void {
        self.queue = try core_audio.DeviceChangesQueue.init();
        errdefer self.queue.deinit();

        const block = Block.init(.{ .controller = self }, struct {
            fn callback(
                captured: *const Block.Context,
                _: u32,
                _: *const core_audio.AudioObjectPropertyAddress,
            ) callconv(.c) void {
                captured.controller.onDevicesChanged();
            }
        }.callback);
        self.block = try Block.copy(&block);
        errdefer Block.release(self.block);

        try core_audio.subscribeDeviceChanges(self.queue, self.block);
        self.queue.sync(self, onDevicesChanged);
    }

    /// Call after a successful start, outside the controller queue. On removal
    /// failure the registration and its resources remain owned by this controller.
    pub fn stop(self: *PreferredInputController) !void {
        try core_audio.unsubscribeDeviceChanges(self.queue, self.block);
        self.queue.drain();
        Block.release(self.block);
        self.queue.deinit();
    }

    fn onDevicesChanged(self: *PreferredInputController) void {
        self.handle() catch |err| {
            std.log.err("Handling device changes failed: {s}", .{@errorName(err)});
        };
    }

    fn handle(self: *PreferredInputController) !void {
        const devices = try self.core_audio.loadDevices();
        defer self.core_audio.freeDevices(devices);

        const event = self.handleSnapshot(devices) orelse return;
        switch (event.state) {
            .connected => core_audio.setAsDefaultInput(event.id) catch |err| {
                std.log.err("Setting the preferred microphone failed: {s}", .{@errorName(err)});
            },
            .disconnected => std.log.debug("Preferred device disconnected", .{}),
        }
    }

    fn handleSnapshot(self: *PreferredInputController, devices: []const Device) ?PreferedDeviceEvent {
        const preferred_uid = self.preferences.getPreferredUid();
        var connected_id: ?u32 = null;
        for (devices) |device| {
            if (std.mem.eql(u8, device.uid, preferred_uid)) {
                connected_id = device.id;
                break;
            }
        }

        const previous_id = self.connected_device_id;
        self.connected_device_id = connected_id;

        if (connected_id != null and previous_id == null) {
            return .{
                .id = connected_id.?,
                .state = .connected,
            };
        } else if (connected_id == null and previous_id != null) {
            return .{
                .id = previous_id.?,
                .state = .disconnected,
            };
        }

        return null;
    }
};

test "an absent preferred microphone does not emit events" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(PreferredInputController);

    var controller: PreferredInputController = .{
        .core_audio = .{ .allocator = std.testing.allocator },
        .preferences = .{ .preferred_uid = "preferred-mic" },
    };
    const other = [_]Device{.{ .id = 9, .uid = "other-mic", .name = "Other microphone" }};

    try std.testing.expect(controller.handleSnapshot(&.{}) == null);
    try std.testing.expect(controller.handleSnapshot(&other) == null);
    try std.testing.expect(controller.handleSnapshot(&.{}) == null);
    try std.testing.expect(controller.connected_device_id == null);
}

test "preferred microphone emits only connection and disconnection transitions" {
    // Equal UIDs in different storage must identify the same microphone.
    const preferred_uid = try std.testing.allocator.dupe(u8, "preferred-mic");
    defer std.testing.allocator.free(preferred_uid);

    var controller: PreferredInputController = .{
        .core_audio = .{ .allocator = std.testing.allocator },
        .preferences = .{ .preferred_uid = preferred_uid },
    };
    const microphone: Device = .{ .id = 7, .uid = "preferred-mic", .name = "Microphone" };
    const other: Device = .{ .id = 9, .uid = "other-mic", .name = "Other microphone" };
    const reconnected: Device = .{ .id = 12, .uid = "preferred-mic", .name = "Microphone" };

    try std.testing.expectEqual(
        PreferedDeviceEvent{ .id = 7, .state = .connected },
        controller.handleSnapshot(&.{microphone}).?,
    );
    try std.testing.expectEqual(@as(?u32, 7), controller.connected_device_id);
    try std.testing.expect(controller.handleSnapshot(&.{microphone}) == null);
    try std.testing.expect(controller.handleSnapshot(&.{ other, microphone }) == null);

    try std.testing.expectEqual(
        PreferedDeviceEvent{ .id = 7, .state = .disconnected },
        controller.handleSnapshot(&.{other}).?,
    );
    try std.testing.expect(controller.connected_device_id == null);
    try std.testing.expect(controller.handleSnapshot(&.{other}) == null);

    try std.testing.expectEqual(
        PreferedDeviceEvent{ .id = 12, .state = .connected },
        controller.handleSnapshot(&.{reconnected}).?,
    );
    try std.testing.expect(controller.handleSnapshot(&.{ reconnected, other }) == null);
    try std.testing.expectEqual(@as(?u32, 12), controller.connected_device_id);
}

test "a changed runtime ID without an observed disconnection does not emit a transition" {
    var controller: PreferredInputController = .{
        .core_audio = .{ .allocator = std.testing.allocator },
        .preferences = .{ .preferred_uid = "preferred-mic" },
        .connected_device_id = 7,
    };
    const microphone = [_]Device{.{ .id = 12, .uid = "preferred-mic", .name = "Microphone" }};

    try std.testing.expect(controller.handleSnapshot(&microphone) == null);
    try std.testing.expectEqual(@as(?u32, 12), controller.connected_device_id);
    try std.testing.expectEqual(
        PreferedDeviceEvent{ .id = 12, .state = .disconnected },
        controller.handleSnapshot(&.{}).?,
    );
}
