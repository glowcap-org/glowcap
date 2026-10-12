//! Deterministic pass-through TLS engine for transport-projection tests.
//!
//! This fake proves state and ownership choreography, not cryptography. Its
//! ciphertext is identical to plaintext so completion tests can
//! drive the existing WebSocket fixture without a second protocol oracle.

const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const tls = glowcap.net.tls;

pub const FakeRuntime = struct {
    opens: usize = 0,
    client_closes: usize = 0,
    runtime_closes: usize = 0,
    open_failure: ?tls.engine.Failure = null,
    fail_phase: ?tls.engine.Phase = null,
    client_cleanup: ?foundation.FailureChain = null,
    runtime_cleanup: ?foundation.FailureChain = null,
    shutdown_ciphertext: []const u8 = &.{},
    shutdown_steps: usize = 0,

    pub fn erased(self: *FakeRuntime) tls.runtime.Runtime {
        return .{ .ctx = self, .vtable = &runtime_vtable };
    }

    fn open(raw: *anyopaque, _: []const u8) tls.runtime.OpenOutcome {
        const self: *FakeRuntime = @ptrCast(@alignCast(raw));
        self.opens += 1;
        if (self.open_failure) |failure| {
            self.open_failure = null;
            return .{ .failed = failure };
        }
        return .{ .client = .init(self, &client_vtable) };
    }

    fn sameConfiguration(left: *anyopaque, right: *anyopaque) bool {
        return left == right;
    }

    fn deinitRuntime(raw: *anyopaque) ?foundation.FailureChain {
        const self: *FakeRuntime = @ptrCast(@alignCast(raw));
        self.runtime_closes += 1;
        return self.runtime_cleanup;
    }

    fn step(
        raw: *anyopaque,
        phase: tls.engine.Phase,
        exchange: tls.engine.Exchange,
    ) tls.engine.RawOutcome {
        const self: *FakeRuntime = @ptrCast(@alignCast(raw));
        if (self.fail_phase == phase) {
            self.fail_phase = null;
            return .{ .failed = .{
                .failure = .init(phase, phaseFailure(phase)),
            } };
        }
        return .{ .stepped = switch (phase) {
            .handshake => .{ .status = .established },
            .shutdown => self.cleanShutdown(exchange),
            .transmit => copyTransmit(exchange),
            .receive => copyReceive(exchange),
        } };
    }

    fn deinitClient(raw: *anyopaque) ?foundation.FailureChain {
        const self: *FakeRuntime = @ptrCast(@alignCast(raw));
        self.client_closes += 1;
        return self.client_cleanup;
    }

    fn copyTransmit(exchange: tls.engine.Exchange) tls.engine.Step {
        const count = @min(exchange.plaintext_in.len, exchange.ciphertext_out.len);
        @memcpy(exchange.ciphertext_out[0..count], exchange.plaintext_in[0..count]);
        return .{ .transfer = .{
            .plaintext_consumed = count,
            .ciphertext_produced = count,
        } };
    }

    fn copyReceive(exchange: tls.engine.Exchange) tls.engine.Step {
        if (exchange.ciphertext_in.len == 0) return .{ .interest = .{ .read = true } };
        const count = @min(exchange.ciphertext_in.len, exchange.plaintext_out.len);
        @memcpy(exchange.plaintext_out[0..count], exchange.ciphertext_in[0..count]);
        return .{ .transfer = .{
            .ciphertext_consumed = count,
            .plaintext_produced = count,
        } };
    }

    fn cleanShutdown(self: *FakeRuntime, exchange: tls.engine.Exchange) tls.engine.Step {
        self.shutdown_steps += 1;
        const count = @min(self.shutdown_ciphertext.len, exchange.ciphertext_out.len);
        @memcpy(exchange.ciphertext_out[0..count], self.shutdown_ciphertext[0..count]);
        return .{
            .status = .clean_close,
            .transfer = .{ .ciphertext_produced = count },
        };
    }

    fn phaseFailure(phase: tls.engine.Phase) anyerror {
        return switch (phase) {
            .handshake => error.InjectedTlsHandshakeFailure,
            .receive => error.InjectedTlsReceiveFailure,
            .transmit => error.InjectedTlsTransmitFailure,
            .shutdown => error.InjectedTlsShutdownFailure,
        };
    }

    const client_vtable: tls.engine.VTable = .{
        .step = step,
        .deinit = deinitClient,
    };
    const runtime_vtable: tls.runtime.Runtime.VTable = .{
        .open = open,
        .same_configuration = sameConfiguration,
        .deinit_outcome = deinitRuntime,
    };
};
