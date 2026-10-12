//! The relay provider package. One configured provider realizes both the
//! cleartext `keyed-relay` and Noise-sealed `noise-relay` transport profiles.
//! Relay route policy lives in `keyed_relay/route.zig`, reusable RFC 6455
//! grammar in `websocket.zig`'s `client_protocol`, resident socket ownership in
//! `keyed_relay/resident.zig`, and completion-only operation accounting and
//! buffer lending in `keyed_relay/completion.zig`.

const model = @import("model");
const builtin = @import("builtin");
const address_race = @import("keyed_relay/address_race.zig");
const blocking_frame = @import("keyed_relay/blocking_frame.zig");
const close_machine = @import("keyed_relay/close.zig");
const endpoint_race = @import("keyed_relay/endpoint_race.zig");
const protocol = @import("../websocket.zig").client_protocol;
const profile = @import("keyed_relay/profile.zig");
const provider = @import("keyed_relay/provider.zig");
const route = @import("keyed_relay/route.zig");
const resident = @import("keyed_relay/resident.zig");
const completion = @import("keyed_relay/completion.zig");
const configuration = @import("keyed_relay/configuration.zig");

pub const transport_name = resident.transport_name;
pub const rendezvous_query = route.rendezvous_query;
pub const register_query = route.register_query;
pub const rendezvous_relay_hint = route.rendezvous_relay_hint;
pub const max_rendezvous_relay_hint_bytes = route.max_rendezvous_relay_hint_bytes;
pub const Opcode = protocol.Opcode;
pub const OutgoingOpcode = protocol.OutgoingOpcode;
pub const FrameHeader = protocol.FrameHeader;
pub const FrameError = blocking_frame.FrameError;
pub const max_control_payload = protocol.max_control_payload;
pub const max_header_len = protocol.max_header_len;
pub const readFrameHeader = blocking_frame.readFrameHeader;
pub const writeFrameHeader = protocol.writeFrameHeader;
pub const acceptKey = protocol.acceptKey;
pub const RelayUrl = route.RelayUrl;
pub const Scheme = route.Scheme;
pub const OpenRequest = route.OpenRequest;
pub const validateClosePayload = protocol.validateClosePayload;
pub const validUpgradeResponse = protocol.validUpgradeResponse;
pub const Resident = resident.Resident;
pub const Provider = provider.Provider;
pub const ChannelProfile = profile.Channel;
pub const RawConnection = resident.RawConnection;
pub const RawListener = resident.RawListener;

pub const LoopConnectTarget = completion.LoopConnectTarget;
pub const DialResolver = completion.DialResolver;
pub const ResidentPolicy = completion.ResidentPolicy;
pub const RelayOptions = completion.RelayOptions;
pub const CompletionBackend = completion.CompletionBackend;
pub const default_send_staging_bytes = completion.default_send_staging_bytes;
pub const validateConfigurationUrls = configuration.validateUrls;
pub const Configuration = configuration.Options;

pub const white_box = if (builtin.is_test) struct {
    pub const FailureLedger = address_race.FailureLedger;
    pub const drainAfterLocalClose = close_machine.drainAfterLocalClose;
    pub const pollable_address_race = endpoint_race.white_box;
} else struct {};

fn Profile(comptime transport: model.transport.Known) type {
    const metadata = transport.metadata();
    if (metadata.dial_shape != .rendezvous)
        @compileError("a relay profile must use rendezvous dialing");

    return struct {
        pub const transport_name = metadata.symbol;

        /// Build a routed relay locator without parsing or allocating. The
        /// returned locator borrows the designator, relay URL, and hint storage.
        pub fn locator(
            designator: []const u8,
            relay_url: []const u8,
            hint_storage: *[1]model.HintEntry,
        ) model.PeerLocator {
            hint_storage[0] = .{
                .name = rendezvous_relay_hint,
                .value = .{ .string = relay_url },
            };
            return .{
                .transport = metadata.symbol,
                .designator = designator,
                .hints = .{ .entries = hint_storage[0..1] },
            };
        }
    };
}

/// Identity-addressed cleartext over the relay provider package.
pub const keyed = Profile(.keyed_relay);

/// Noise_XK-sealed streams over the relay provider package.
pub const noise = Profile(.noise_relay);
