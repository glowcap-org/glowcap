//! Every first-party stream symbol on one completion backend, as one
//! HostRuntime resident (ADR-0018).
//!
//! The adapters stack the way their dial targets allow: keyed-relay sits on
//! the platform, whose socket addresses it dials. Onion over relay, `inproc`
//! over onion, and foreign stream providers outermost. Each adapter passes
//! the operations it does not own to the one it wraps, and each policy the
//! symbols it does not own to its inner policy, so the one backend serves
//! `tcp`, `keyed-tcp`, `noise-tcp`, `keyed-relay`, `noise-relay`, `onion`,
//! `inproc`, and any registered provider symbol. The Host seals the Noise
//! symbols (ADR-0041). An adapter left unconfigured refuses its own symbols
//! and costs nothing on the others.

const std = @import("std");

const completion_resident = @import("completion_resident.zig");
const tcp = @import("transport/tcp.zig");
const relay = @import("transport/keyed_relay/completion.zig");
const onion = @import("transport/onion/completion.zig");
const inproc = @import("transport/inproc/completion.zig");
const external = @import("transport/external/completion.zig");

pub fn Stack(comptime Platform: type) type {
    return struct {
        pub const Relay = relay.CompletionBackend(Platform);
        pub const Onion = onion.CompletionBackend(Relay);
        pub const Inproc = inproc.CompletionBackend(Onion);
        pub const Backend = external.CompletionBackend(Inproc);

        pub const Policy = external.ResidentPolicy(Backend, inproc.ResidentPolicy(
            Inproc,
            onion.ResidentPolicy(Onion, relay.ResidentPolicy(Relay, tcp.CompletionPolicy(Platform))),
        ));
        pub const Resident = completion_resident.Resident(Backend, Policy);
        pub const RelayOptions = relay.RelayOptions;
        pub const OnionConfig = onion.Config(Platform);

        /// Each transport's deployment state. A null arm leaves that
        /// transport's symbols refused.
        pub const Options = struct {
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
            relay: ?RelayOptions = null,
            /// Tor's endpoints as platform addresses.
            onion: ?OnionConfig = null,
            inproc: inproc.Options = .{},
            external: external.Options = .{ .providers = &.{} },
        };

        /// Build the stack. The caller wraps it in `Resident.init`.
        pub fn initBackend(allocator: std.mem.Allocator, options: Options) !Backend {
            const relay_backend = if (options.relay) |relay_options|
                try Relay.initWithRelay(allocator, options.queue_entries, options.read_buffers, options.read_buffer_bytes, relay_options)
            else
                try Relay.init(allocator, options.queue_entries, options.read_buffers, options.read_buffer_bytes);
            // Each wrapper below owns what it wraps from entry, error paths
            // included, so nothing here unwinds after the hand-off.
            const onion_backend = if (options.onion) |config| Onion.initOnion(allocator, relay_backend, .{
                .socks = .{ .tcp = config.socks },
                .control = if (config.control) |control| .{ .tcp = control } else null,
                .auth = config.auth,
                .service_key = config.service_key,
                .setup_timeout_ms = config.setup_timeout_ms,
            }) else Onion.initOnion(allocator, relay_backend, null);
            const inproc_backend = try Inproc.initWithPlatform(allocator, options.inproc, onion_backend, options.read_buffers, options.read_buffer_bytes);
            return Backend.initWithPlatform(allocator, options.external, inproc_backend, options.read_buffers, options.read_buffer_bytes);
        }
    };
}
