const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.runtime);

/// Threaded is retained on every platform until Evented HTTP serving is
/// validated with the supported compiler. Environment propagation applies
/// regardless of backend.
pub const Backend = enum { evented, threaded };
pub var threaded: std.Io.Threaded = undefined;
pub var io: std.Io = undefined;
var active: Backend = .threaded;

// Evented is only available on platforms where the stdlib provides it.
//
// Evented compiles on 0.17.0-dev (the 0.16.0 Uring `ReadOnlyFileSystem`
// compile bug is fixed). It still cannot serve HTTP: `std.Io.Uring`'s vtable
// wires `netListenIp` / `netAccept` to stubs that always return
// `error.NetworkDown`. Keep Threaded until those vtable slots are real.
const stdlib_evented_works = false;
const evented_supported = blk: {
    if (!stdlib_evented_works) break :blk false;
    if (!@hasDecl(std.Io, "Evented")) break :blk false;
    if (std.Io.Evented == void) break :blk false;
    // Only attempt Evented on Linux (io_uring). Other Evented backends are
    // either unavailable or still experimental outside Linux io_uring.
    break :blk builtin.target.os.tag == .linux;
};

// Storage for the Evented instance — only allocated on supported platforms.
var evented: if (evented_supported) std.Io.Evented else void = undefined;

pub fn init(gpa: std.mem.Allocator, environ: std.process.Environ) !void {
    if (evented_supported) {
        evented = undefined;
        if (std.Io.Evented.init(&evented, gpa, .{ .environ = environ })) {
            io = evented.io();
            active = .evented;
            return;
        } else |err| {
            // io_uring not available — fall back to Threaded so we still boot.
            // Common causes: old kernel, restricted seccomp profile, sandboxed
            // container runtime (Docker default seccomp profile, gVisor, etc.).
            log.warn("io_uring init failed ({s}); falling back to Threaded backend", .{@errorName(err)});
        }
    }
    threaded = std.Io.Threaded.init(gpa, .{ .environ = environ });
    io = threaded.io();
    active = .threaded;
}

pub fn deinit() void {
    switch (active) {
        .evented => if (evented_supported) evented.deinit(),
        .threaded => threaded.deinit(),
    }
}

/// Returns true if the active backend is Evented (io_uring).
pub fn isEvented() bool {
    return active == .evented;
}

/// Returns the active backend.
pub fn backend() Backend {
    return active;
}

/// Log which backend is active at startup.
pub fn logBackend() void {
    switch (active) {
        .evented => log.info("io backend: Evented (io_uring)", .{}),
        .threaded => log.info("io backend: Threaded (blocking syscalls)", .{}),
    }
}
