//! Rooms peer moved to `cli/app/rooms_peer.zig` (ADR-0084).
//! Build/run: `zig build rooms-peer` or `pancake app rooms-peer …`.
comptime {
    @compileError("rooms-peer lives at cli/app/rooms_peer.zig — use zig build rooms-peer or pancake app rooms-peer");
}
