const std = @import("std");
const c = @import("c");

pub const AudioObjectPropertyAddress = c.AudioObjectPropertyAddress;

// translate-c cannot represent Apple's block declarators. A block argument is
// an ABI-compatible pointer to the block object, not a function pointer.
extern fn AudioObjectAddPropertyListenerBlock(
    object_id: c.AudioObjectID,
    address: *const c.AudioObjectPropertyAddress,
    queue: c.dispatch_queue_t,
    block: *const anyopaque,
) c.OSStatus;

extern fn AudioObjectRemovePropertyListenerBlock(
    object_id: c.AudioObjectID,
    address: *const c.AudioObjectPropertyAddress,
    queue: c.dispatch_queue_t,
    block: *const anyopaque,
) c.OSStatus;

pub const DeviceChangesQueue = struct {
    value: c.dispatch_queue_t,

    pub fn init() !DeviceChangesQueue {
        return .{
            .value = c.dispatch_queue_create("micpin.device-changes", null) orelse
                return error.OutOfMemory,
        };
    }

    pub fn deinit(self: DeviceChangesQueue) void {
        c.dispatch_release(.{ ._dq = self.value });
    }

    /// Call from outside this queue. The context must remain valid until return.
    pub fn sync(
        self: DeviceChangesQueue,
        context: anytype,
        comptime work: *const fn (@TypeOf(context)) void,
    ) void {
        c.dispatch_sync_f(self.value, context, struct {
            fn callback(raw_context: ?*anyopaque) callconv(.c) void {
                const typed_context: @TypeOf(context) = @ptrCast(@alignCast(raw_context.?));
                work(typed_context);
            }
        }.callback);
    }

    /// Wait for previously submitted callbacks. Call from outside this queue.
    pub fn drain(self: DeviceChangesQueue) void {
        c.dispatch_sync_f(self.value, null, struct {
            fn callback(_: ?*anyopaque) callconv(.c) void {}
        }.callback);
    }
};

pub const Device = struct {
    /// Runtime identifier used by Core Audio. Do not persist it because it can change.
    id: u32,
    /// Persistent device identifier used to find its runtime ID while it is available.
    uid: []const u8,
    /// Device name.
    name: []const u8,
};

const devices_address = propertyAddress(c.kAudioHardwarePropertyDevices);

pub const CoreAudioAdapter = struct {
    allocator: std.mem.Allocator,

    /// The caller owns the devices and their strings; release them with freeDevices.
    pub fn loadDevices(self: CoreAudioAdapter) ![]Device {
        const ids = try loadInputDeviceIds(self.allocator);
        defer self.allocator.free(ids);

        const devices = try self.allocator.alloc(Device, ids.len);
        var initialized: usize = 0;
        errdefer {
            for (devices[0..initialized]) |device| {
                self.allocator.free(device.uid);
                self.allocator.free(device.name);
            }
            self.allocator.free(devices);
        }

        for (ids) |id| {
            const name = try loadDeviceName(self.allocator, id);
            errdefer self.allocator.free(name);
            const uid = try loadDeviceUid(self.allocator, id);

            devices[initialized] = .{ .id = id, .uid = uid, .name = name };
            initialized += 1;
        }
        return devices;
    }

    pub fn freeDevices(self: CoreAudioAdapter, devices: []Device) void {
        for (devices) |device| {
            self.allocator.free(device.uid);
            self.allocator.free(device.name);
        }
        self.allocator.free(devices);
    }
};

pub fn setAsDefaultInput(device_id: u32) !void {
    const address = propertyAddress(c.kAudioHardwarePropertyDefaultInputDevice);
    const id: c.AudioDeviceID = device_id;
    try checkStatus(c.AudioObjectSetPropertyData(
        c.kAudioObjectSystemObject,
        &address,
        0,
        null,
        @sizeOf(c.AudioDeviceID),
        &id,
    ), "setting the default input device");
}

/// HAL retains the queue and copies the block until removal. Keep the captured
/// context alive until removal and completion of the queue's callbacks.
pub fn subscribeDeviceChanges(
    queue: DeviceChangesQueue,
    block: *const anyopaque,
) !void {
    try checkStatus(AudioObjectAddPropertyListenerBlock(
        c.kAudioObjectSystemObject,
        &devices_address,
        queue.value,
        block,
    ), "registering the device listener");
}

/// Remove with the same queue and block used to subscribe, then drain the queue
/// before releasing the captured context.
pub fn unsubscribeDeviceChanges(
    queue: DeviceChangesQueue,
    block: *const anyopaque,
) !void {
    try checkStatus(AudioObjectRemovePropertyListenerBlock(
        c.kAudioObjectSystemObject,
        &devices_address,
        queue.value,
        block,
    ), "removing the device listener");
}

fn propertyAddress(selector: c.AudioObjectPropertySelector) c.AudioObjectPropertyAddress {
    return .{
        .mSelector = selector,
        .mScope = c.kAudioObjectPropertyScopeGlobal,
        .mElement = c.kAudioObjectPropertyElementMain,
    };
}

fn checkStatus(status: c.OSStatus, operation: []const u8) !void {
    if (status != c.noErr) {
        std.log.err("Core Audio failed while {s}: {d}", .{ operation, status });
        return error.CoreAudioError;
    }
}

/// Loads the runtime IDs of all connected devices. The caller owns the returned slice.
/// Queries the size of kAudioHardwarePropertyDevices on kAudioObjectSystemObject,
/// allocates a slice of that size, then reads the property into the slice.
pub fn loadDeviceIds(allocator: std.mem.Allocator) ![]u32 {
    const addr = devices_address;

    var data_size: c.UInt32 = 0;

    var status = c.AudioObjectGetPropertyDataSize(
        c.kAudioObjectSystemObject,
        &addr,
        0,
        null,
        &data_size,
    );
    if (status != c.noErr) {
        std.debug.print("AudioObjectGetPropertyDataSize failed: {}\n", .{status});

        return error.CoreAudioError;
    }

    if (data_size % @sizeOf(c.AudioDeviceID) != 0) return error.InvalidPropertySize;
    const device_count = data_size / @sizeOf(c.AudioDeviceID);
    const devices = try allocator.alloc(c.AudioDeviceID, device_count);
    errdefer allocator.free(devices);
    if (devices.len == 0) return devices;

    status = c.AudioObjectGetPropertyData(
        c.kAudioObjectSystemObject,
        &addr,
        0,
        null,
        &data_size,
        devices.ptr,
    );
    if (status != c.noErr) {
        std.debug.print(
            "AudioObjectGetPropertyData failed: {}\n",
            .{status},
        );

        return error.CoreAudioError;
    }

    if (data_size % @sizeOf(c.AudioDeviceID) != 0 or
        data_size / @sizeOf(c.AudioDeviceID) > devices.len)
    {
        return error.InvalidPropertySize;
    }
    // Devices can disappear between the size query and the data query.
    return allocator.realloc(devices, data_size / @sizeOf(c.AudioDeviceID));
}

/// Loads the IDs of devices with at least one input audio stream.
/// The caller owns the returned slice.
pub fn loadInputDeviceIds(allocator: std.mem.Allocator) ![]u32 {
    const devices = try loadDeviceIds(allocator);
    errdefer allocator.free(devices);

    var input_count: usize = 0;
    for (devices) |device_id| {
        if (try hasInput(device_id)) {
            devices[input_count] = device_id;
            input_count += 1;
        }
    }

    return allocator.realloc(devices, input_count);
}

/// Checks whether a device supports audio input, regardless of whether it is recording.
pub fn hasInput(device_id: u32) !bool {
    const addr = c.AudioObjectPropertyAddress{
        .mSelector = c.kAudioDevicePropertyStreams,
        .mScope = c.kAudioObjectPropertyScopeInput,
        .mElement = c.kAudioObjectPropertyElementMain,
    };

    var data_size: c.UInt32 = 0;
    const status = c.AudioObjectGetPropertyDataSize(
        device_id,
        &addr,
        0,
        null,
        &data_size,
    );
    if (status != c.noErr) {
        std.debug.print("AudioObjectGetPropertyDataSize while reading input streams failed: {}\n", .{status});
        return error.CoreAudioError;
    }

    return data_size > 0;
}

pub fn loadDeviceName(allocator: std.mem.Allocator, device_id: u32) ![]const u8 {
    return loadDeviceString(allocator, device_id, c.kAudioObjectPropertyName, "name");
}

/// Loads the persistent device UID. The caller owns the returned UTF-8 string.
pub fn loadDeviceUid(allocator: std.mem.Allocator, device_id: u32) ![]const u8 {
    return loadDeviceString(allocator, device_id, c.kAudioDevicePropertyDeviceUID, "UID");
}

fn loadDeviceString(
    allocator: std.mem.Allocator,
    device_id: u32,
    selector: c.AudioObjectPropertySelector,
    property_name: []const u8,
) ![]const u8 {
    const addr = c.AudioObjectPropertyAddress{
        .mSelector = selector,
        .mScope = c.kAudioObjectPropertyScopeGlobal,
        .mElement = c.kAudioObjectPropertyElementMain,
    };

    var value: c.CFStringRef = null;
    var size: c.UInt32 = @sizeOf(c.CFStringRef);

    const status = c.AudioObjectGetPropertyData(
        device_id,
        &addr,
        0,
        null,
        &size,
        @ptrCast(&value),
    );
    if (status != c.noErr) {
        std.debug.print(
            "AudioObjectGetPropertyData while reading {s} failed: {}\n",
            .{ property_name, status },
        );

        return error.CoreAudioError;
    }

    if (value == null) return error.MissingStringProperty;
    defer c.CFRelease(value);

    const length = c.CFStringGetLength(value);

    const max_size =
        c.CFStringGetMaximumSizeForEncoding(
            length,
            c.kCFStringEncodingUTF8,
        ) + 1;

    const buffer = try allocator.alloc(
        u8,
        @intCast(max_size),
    );
    errdefer allocator.free(buffer);

    if (c.CFStringGetCString(
        value,
        buffer.ptr,
        max_size,
        c.kCFStringEncodingUTF8,
    ) == 0) {
        return error.StringConversionFailed;
    }

    const len =
        std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;

    return allocator.realloc(buffer, len);
}
