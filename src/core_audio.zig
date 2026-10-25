const std = @import("std");
const c = @import("c");

const DeviceChangeCallback = *const fn (
    object_id: c.AudioObjectID,
    address_count: c.UInt32,
    addresses: [*c]const c.AudioObjectPropertyAddress,
    context: ?*anyopaque,
) callconv(.c) c.OSStatus;

/// Both registration and removal must use this factory to get the same C function.
fn makeDeviceChangesCallback(
    comptime Context: type,
    comptime onChange: *const fn (Context) void,
) DeviceChangeCallback {
    return struct {
        fn callback(
            _: c.AudioObjectID,
            _: c.UInt32,
            _: [*c]const c.AudioObjectPropertyAddress,
            raw_context: ?*anyopaque,
        ) callconv(.c) c.OSStatus {
            const context: Context = @ptrCast(@alignCast(raw_context orelse return c.noErr));
            // Registered only for device-list changes: HAL includes that property
            // in every notification, and one notification needs one handler call.
            onChange(context);
            return c.noErr;
        }
    }.callback;
}

pub const Device = struct {
    // Рантайм ID. По сути основной идентификатор, который ходит по Core Audio. Хранить нельзя, т.к. может меняться
    id: u32,
    // Постоянный идентификатор устройства. Можно хранить и получать рантайм ID, пока устройство доступно
    uid: []const u8,
    // Имя устройства
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

    pub fn setAsDefaultInput(_: CoreAudioAdapter, device_id: u32) !void {
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

    /// Registers a notification handler without configuring the HAL notification run loop.
    /// The caller owns the context, its synchronization and its lifetime. Keep the
    /// context at a stable address until removal and completion of in-flight callbacks.
    pub fn subscribeDeviceChanges(
        _: CoreAudioAdapter,
        context: anytype,
        comptime onChange: *const fn (@TypeOf(context)) void,
    ) !void {
        try checkStatus(c.AudioObjectAddPropertyListener(
            c.kAudioObjectSystemObject,
            &devices_address,
            makeDeviceChangesCallback(@TypeOf(context), onChange),
            context,
        ), "registering the device listener");
    }

    /// Remove with the same context type, pointer and handler used to subscribe. This only
    /// unregisters the callback; the caller must coordinate in-flight handlers.
    /// Close a handler's queue first if it can be waiting for space there.
    pub fn unsubscribeDeviceChanges(
        _: CoreAudioAdapter,
        context: anytype,
        comptime onChange: *const fn (@TypeOf(context)) void,
    ) !void {
        try checkStatus(c.AudioObjectRemovePropertyListener(
            c.kAudioObjectSystemObject,
            &devices_address,
            makeDeviceChangesCallback(@TypeOf(context), onChange),
            context,
        ), "removing the device listener");
    }
};

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

/// Загружает список рантайм ID всех подключенных устройств
/// Принцип работы:
///     - Запросить размер списка (kAudioHardwarePropertyDevices) у корневой сущности kAudioObjectSystemObject
///     - Аллоцировать слайс по полученному размеру
///     - Запросить сам список в аллоцированный слайс у той же сущности kAudioObjectSystemObject
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

/// Загружает ID устройств, у которых есть хотя бы один входной аудиопоток.
/// Возвращённый слайс освобождает вызывающий код.
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

/// Проверяет поддержку ввода звука, независимо от того, идёт ли сейчас запись.
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

/// Загружает постоянный UID устройства. Возвращённую UTF-8 строку освобождает вызывающий код.
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

test "device callback forwards the typed context" {
    const Counter = struct {
        calls: usize = 0,

        fn changed(self: *@This()) void {
            self.calls += 1;
        }
    };
    const callback = makeDeviceChangesCallback(*Counter, Counter.changed);
    var counter: Counter = .{};

    _ = callback(c.kAudioObjectSystemObject, 1, &devices_address, &counter);

    try std.testing.expectEqual(@as(usize, 1), counter.calls);
}
