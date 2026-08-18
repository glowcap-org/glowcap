//! Relay channel profiles shared by every native execution model.

const model = @import("model");

/// Which byte protocol runs over the relay pipe. Both profiles use the same
/// key-addressed rendezvous; only `noise-relay` asks the owning Host to run the
/// sealed channel before CapTP bytes move.
pub const Channel = enum {
    keyed,
    noise,

    pub fn known(self: Channel) model.transport.Known {
        return switch (self) {
            .keyed => .keyed_relay,
            .noise => .noise_relay,
        };
    }

    pub fn transportName(self: Channel) []const u8 {
        return self.known().metadata().symbol;
    }
};
