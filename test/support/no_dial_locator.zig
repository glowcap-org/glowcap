//! Shared completion-loop DialResolver for accept-only test Backends that never dial.
//! Production Locators live on the netlayer (`tcp.DialResolver`, `iroh.DialResolver`).
//! These fakes only satisfy `Loop(Backend, DialResolver)`'s comptime contract.

pub const Unsupported = struct {
    pub fn resolve(transport: []const u8, designator: []const u8, hint: []const u8) error{UnsupportedTransport}!void {
        _ = transport;
        _ = designator;
        _ = hint;
        return error.UnsupportedTransport;
    }
};
