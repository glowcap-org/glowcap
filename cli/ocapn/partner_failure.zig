//! Which failures belong to one partner and which end a listener. Both
//! `listen` loops ask here, so a partner that fails its handshake or its
//! session costs that one arrival, and a listener that stops ends its loop
//! with the listener's own cause.

const std = @import("std");
const driver = @import("glowcap").driver;

/// Whether a failure on an accepted session belongs to that partner.
/// Transport, protocol, and timeout failures do. The driver's classification
/// decides, so a new pump error cannot silently end a listener here.
pub fn isSessionFailure(err: anyerror) bool {
    return switch (driver.OperationFailure.classify(err)) {
        .timeout, .closed, .session, .malformed, .frame_too_large, .io => true,
        .invalid_argument, .not_found, .would_block, .internal => false,
    };
}

/// Whether a session failure is the partner hanging up, the ordinary end of a
/// served session rather than a failure of it.
pub fn partnerLeft(err: anyerror) bool {
    return err == error.ConnectionLost or err == error.TruncatedFrame;
}

/// Whether a failed `accept` costs only that arrival, so the loop accepts
/// again. It does only while the server is `listening`: once the listener
/// stops, `accept` returns the listener's cause and then `ServerClosed`,
/// and neither belongs to a partner.
pub fn acceptAgain(listening: bool, err: anyerror) bool {
    if (!listening) return false;
    return switch (err) {
        // The listener's own socket and runtime machinery, not bytes the
        // arriving partner supplied.
        error.SocketConfigurationFailed,
        error.WakeNudgeFailed,
        error.WakeDrainFailed,
        => false,
        else => isSessionFailure(err),
    };
}

test "a partner's failure costs one arrival while the listener listens" {
    try std.testing.expect(acceptAgain(true, error.ConnectionLost));
    try std.testing.expect(acceptAgain(true, error.HandshakeTimedOut));
    try std.testing.expect(!acceptAgain(true, error.SocketConfigurationFailed));
    try std.testing.expect(!acceptAgain(true, error.WakeDrainFailed));
    try std.testing.expect(!acceptAgain(false, error.ProcessFdQuotaExceeded));
    try std.testing.expect(!acceptAgain(false, error.ServerClosed));
    try std.testing.expect(!acceptAgain(false, error.ConnectionLost));
}

test "a partner hanging up ends its session without failing it" {
    try std.testing.expect(partnerLeft(error.ConnectionLost));
    try std.testing.expect(partnerLeft(error.TruncatedFrame));
    try std.testing.expect(!partnerLeft(error.FrameTooLarge));
    try std.testing.expect(!partnerLeft(error.ProtocolAbort));
}

test "a session's transport, protocol, and timeout failures are the partner's" {
    try std.testing.expect(isSessionFailure(error.ConnectionLost));
    try std.testing.expect(isSessionFailure(error.MalformedFrame));
    try std.testing.expect(isSessionFailure(error.ProtocolAbort));
    try std.testing.expect(isSessionFailure(error.AbortFlushFailed));
    try std.testing.expect(!isSessionFailure(error.OutOfMemory));
}
