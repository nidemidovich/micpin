const std = @import("std");

/// Initialize on the main thread before starting other threads or CoreAudio.
/// Wait on the same thread. Signals remain blocked until the process exits.
pub const SignalsController = struct {
    mask: std.posix.sigset_t,

    pub fn init() !SignalsController {
        var mask = std.posix.sigemptyset();
        std.posix.sigaddset(&mask, .INT);
        std.posix.sigaddset(&mask, .TERM);

        var previous_mask: std.posix.sigset_t = undefined;
        const status = std.c.pthread_sigmask(std.posix.SIG.BLOCK, &mask, &previous_mask);
        if (status != 0) {
            std.log.err("Blocking shutdown signals with pthread_sigmask failed: {d}", .{status});
            return error.SignalMaskFailed;
        }

        return .{ .mask = mask };
    }

    pub fn wait(self: SignalsController) !std.posix.SIG {
        // The libc binding takes a mutable pointer although sigwait only reads it.
        var mask = self.mask;
        var signal: c_int = undefined;
        const status = std.c.sigwait(&mask, &signal);
        if (status != 0) {
            std.log.err("Waiting for a shutdown signal with sigwait failed: {d}", .{status});
            return error.SignalWaitFailed;
        }

        return @fromBackingInt(@intCast(signal));
    }
};
