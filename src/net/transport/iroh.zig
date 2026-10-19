//! The iroh netlayer resident: an encrypted QUIC transport behind the same
//! contract as tcp and inproc, carried by the Rust sidecar (ADR-0021).
//!
//! The wire is iroh: each `Resident` owns one iroh endpoint (created through
//! the C ABI in `transports/iroh/include/glowcap_iroh_sidecar.h`, implemented
//! by the `libglowcap_iroh_sidecar.a` staticlib), and every connection is one
//! bidirectional QUIC stream presented as the same reader/writer pair the other
//! residents produce. The transport symbol is `iroh`. The locator designator
//! is the endpoint id, and direct socket addresses ride
//! `hint_direct_addresses`.
//!
//! This facade is not reachable from the default `glowcap`
//! module graph. The private extern declarations reachable through it resolve
//! only when the iroh sidecar is linked, so the dedicated iroh build steps
//! compile this as their supported consumer surface. Internal leaves use `pub`
//! only for cross-file visibility.

const net = @import("net");
const locators = @import("iroh/locators.zig");
const policy = @import("iroh/policy.zig");
const sidecar = @import("iroh/sidecar.zig");
const resident = @import("iroh/resident.zig");
const backend = @import("iroh/backend.zig");
const resolver = @import("iroh/resolver.zig");

pub const transport_profile = locators.transport_profile;
pub const transport_name = locators.transport_name;
pub const Reachability = locators.Reachability;
pub const hint_direct_addresses = locators.hint_direct_addresses;
pub const max_direct_address_bytes = locators.max_direct_address_bytes;
pub const node_id_len = locators.node_id_len;
pub const read_chunk_bytes = policy.read_chunk_bytes;
pub const locator = locators.locator;
pub const locatorWithDirectAddresses = locators.locatorWithDirectAddresses;

pub const ReadyEvent = sidecar.ReadyEvent;
pub const DialText = sidecar.DialText;
pub const dial_text_bytes = sidecar.dial_text_bytes;
pub const Resident = resident.Resident;
pub const MultiplexedAdapter = @import("iroh/multiplexed.zig").MultiplexedAdapter;
pub const loop_would_block = resident.loop_would_block;
pub const loop_ev_readable = resident.loop_ev_readable;
pub const loop_ev_writable = resident.loop_ev_writable;
pub const loop_ev_closed = resident.loop_ev_closed;
pub const loop_ev_accept = resident.loop_ev_accept;
pub const loop_ev_connect = resident.loop_ev_connect;

pub const ConnectTarget = locators.ConnectTarget;
pub const resolveConnectTarget = locators.resolveConnectTarget;
pub const DialResolver = resolver.DialResolver;
pub const CompositeDialResolver = resolver.CompositeDialResolver;
pub const validateListenerLocator = locators.validateListenerLocator;
pub const CompletionBackend = backend.CompletionBackend;
pub const Backend = CompletionBackend(net.Backend);
