//! The relay transport profiles over one `std.Io` resident and native
//! completion adapter. RFC 6455 and URL grammar live in
//! `keyed_relay/protocol.zig`, resident socket ownership in `resident.zig`, and
//! completion-only operation accounting and buffer lending in `completion.zig`.

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
