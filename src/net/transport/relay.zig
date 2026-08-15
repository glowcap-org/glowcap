//! The relay provider package. One configured provider realizes both the
//! cleartext `keyed-relay` and Noise-sealed `noise-relay` transport profiles.
//! RFC 6455 and URL grammar live in `keyed_relay/protocol.zig`, resident socket
//! ownership in `keyed_relay/resident.zig`, and completion-only operation
//! accounting and buffer lending in `keyed_relay/completion.zig`.

const model = @import("model");
const protocol = @import("keyed_relay/protocol.zig");
const resident = @import("keyed_relay/resident.zig");
const completion = @import("keyed_relay/completion.zig");

pub const transport_name = resident.transport_name;
pub const rendezvous_query = protocol.rendezvous_query;
pub const register_query = protocol.register_query;
pub const rendezvous_relay_hint = protocol.rendezvous_relay_hint;
pub const max_rendezvous_relay_hint_bytes = protocol.max_rendezvous_relay_hint_bytes;
pub const Opcode = protocol.Opcode;
pub const OutgoingOpcode = protocol.OutgoingOpcode;
pub const FrameHeader = protocol.FrameHeader;
pub const FrameError = resident.FrameError;
pub const max_control_payload = protocol.max_control_payload;
pub const max_header_len = protocol.max_header_len;
pub const readFrameHeader = resident.readFrameHeader;
pub const writeFrameHeader = protocol.writeFrameHeader;
pub const acceptKey = protocol.acceptKey;
pub const RelayUrl = protocol.RelayUrl;
pub const validateClosePayload = protocol.validateClosePayload;
pub const validUpgradeResponse = protocol.validUpgradeResponse;
pub const Resident = resident.Resident;
pub const Provider = resident.Provider;
pub const ChannelProfile = resident.ChannelProfile;
pub const RawConnection = resident.RawConnection;
pub const RawListener = resident.RawListener;

pub const LoopConnectTarget = completion.LoopConnectTarget;
pub const DialResolver = completion.DialResolver;
pub const RelayOptions = completion.RelayOptions;
pub const CompletionBackend = completion.CompletionBackend;
pub const default_send_staging_bytes = completion.default_send_staging_bytes;

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
