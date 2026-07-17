//! CapTP rooms presence (`pancake app rooms-peer`): a durable peer an agent
//! runs to sit in a room while it works. Dogfoods pancake from an agent's seat
//! on the same core every binding wraps. The `rooms-peer` install name is a
//! thin shim that forwards here (ADR-0084).
//!
//! Sources live under `cli/app/rooms_peer/`; this file is the stable import
//! surface for `cli/cmd/tree.zig`.

pub const Flags = @import("rooms_peer/flags.zig").Flags;
pub const runVerb = @import("rooms_peer/verbs.zig").runVerb;
pub const verbExit = @import("rooms_peer/verbs.zig").verbExit;
pub const peerCliPrefix = @import("rooms_peer/supervise.zig").peerCliPrefix;
