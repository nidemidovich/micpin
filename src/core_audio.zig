const std = @import("std");
const c = @import("c");

/// Загружает список рантайм ID всех подключенных устройств
/// Принцип работы:
///     - Запросить размер списка (kAudioHardwarePropertyDevices) у корневой сущности kAudioObjectSystemObject
///     - Аллоцировать слайс по полученному размеру
///     - Запросить сам список в аллоцированный слайс у той же сущности kAudioObjectSystemObject
pub fn load_device_ids(allocator: std.mem.Allocator) ![]u32 {
    const addr = c.AudioObjectPropertyAddress{
        .mSelector = c.kAudioHardwarePropertyDevices,
        .mScope = c.kAudioObjectPropertyScopeGlobal,
        .mElement = c.kAudioObjectPropertyElementMain,
    };

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

    const device_count = data_size / @sizeOf(c.AudioDeviceID);
    const devices = try allocator.alloc(c.AudioDeviceID, device_count);
    errdefer allocator.free(devices);

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

    return devices;
}

pub fn load_device_name(allocator: std.mem.Allocator, device_id: u32) ![]const u8 {
    return load_device_string(allocator, device_id, c.kAudioObjectPropertyName, "name");
}

/// Загружает постоянный UID устройства. Возвращённую UTF-8 строку освобождает вызывающий код.
pub fn load_device_uid(allocator: std.mem.Allocator, device_id: u32) ![]const u8 {
    return load_device_string(allocator, device_id, c.kAudioDevicePropertyDeviceUID, "UID");
}

fn load_device_string(
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
