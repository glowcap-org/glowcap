//! Private Mbed TLS 4.x projection of the transport-neutral TLS engine.
//!
//! Mbed TLS owns TLS/X.509 state only. Zig supplies socket bytes through the
//! caller-owned `Exchange`, owns readiness and cancellation, and translates
//! the vendor result exactly once at this boundary.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("net").tls.engine;
const runtime_contract = @import("net").tls.runtime;

const c = @import("mbedtls_c");

const CryptoProcess = struct {
    mutex: std.Io.Mutex = .init,
    leases: usize = 0,

    fn acquire(self: *CryptoProcess, io: std.Io) ?i32 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.leases == 0) {
            const status = c.psa_crypto_init();
            if (status != c.PSA_SUCCESS) return @intCast(status);
        }
        self.leases += 1;
        return null;
    }

    fn release(self: *CryptoProcess, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.leases != 0);
        self.leases -= 1;
        if (self.leases == 0) c.mbedtls_psa_crypto_free();
    }
};

var crypto_process: CryptoProcess = .{};

pub const InitOutcome = union(enum) {
    runtime: Initialized,
    failed: engine.Failure,
};

pub const Initialized = struct {
    owner: *Runtime,
    trust: TrustSummary,
};

pub const OpenOutcome = union(enum) {
    client: engine.Client,
    failed: engine.Failure,
};

pub const TrustSummary = struct {
    loaded: usize,
    /// Roots accepted by Zig's platform loader but refused by Mbed TLS.
    /// They are excluded rather than making every other platform root unusable.
    skipped_by_engine: usize = 0,
    first_skipped_engine_code: ?i32 = null,
};

/// Opaque owner of one parsed immutable trust snapshot and shared client
/// configuration. No Mbed TLS type crosses this module boundary.
pub const Runtime = opaque {
    pub fn initCopiedRoots(io: std.Io, allocator: std.mem.Allocator, pem: []const u8) InitOutcome {
        return runtimeInit(io, allocator, .{ .pem = pem });
    }

    /// Load the platform trust store once, copy its validated DER certificates
    /// into Mbed TLS, then release the filesystem/Keychain scan. Connections
    /// share only the resulting immutable runtime; none rescans the process
    /// environment or retains a path.
    pub fn initSystemRoots(io: std.Io, allocator: std.mem.Allocator) InitOutcome {
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(allocator);
        bundle.rescan(allocator, io, std.Io.Clock.real.now(io)) catch |err|
            return failedSystemTrust(err);
        if (bundle.bytes.items.len == 0 or bundle.bytes.items.len > max_trust_bytes)
            return failedSystemTrust(error.SystemTrustStoreEmpty);
        return runtimeInit(io, allocator, .{ .der_bundle = bundle.bytes.items });
    }

    pub fn open(self: *Runtime, hostname: []const u8) OpenOutcome {
        return runtimeOpen(@ptrCast(@alignCast(self)), hostname);
    }

    pub fn deinitOutcome(self: *Runtime) ?foundation.FailureChain {
        return runtimeDeinitOutcome(@ptrCast(@alignCast(self)));
    }

    /// Transfer this runtime into a carrier owner. The returned value remains
    /// valid until its deinit outcome succeeds.
    pub fn intoRuntime(self: *Runtime) runtime_contract.Runtime {
        return .{ .ctx = self, .vtable = &runtime_vtable };
    }
};

const runtime_vtable: runtime_contract.Runtime.VTable = .{
    .open = runtimeOpenErased,
    .same_configuration = runtimeSameConfigurationErased,
    .deinit_outcome = runtimeDeinitErased,
};

fn runtimeOpenErased(raw: *anyopaque, hostname: []const u8) runtime_contract.OpenOutcome {
    const self: *Runtime = @ptrCast(@alignCast(raw));
    return switch (self.open(hostname)) {
        .client => |client| .{ .client = client },
        .failed => |failure| .{ .failed = failure },
    };
}

fn runtimeSameConfigurationErased(left_raw: *anyopaque, right_raw: *anyopaque) bool {
    const left: *RuntimeImpl = @ptrCast(@alignCast(left_raw));
    const right: *RuntimeImpl = @ptrCast(@alignCast(right_raw));
    return left.trust_policy == right.trust_policy and sameRoots(&left.roots, &right.roots);
}

fn runtimeDeinitErased(raw: *anyopaque) ?foundation.FailureChain {
    const self: *Runtime = @ptrCast(@alignCast(raw));
    return self.deinitOutcome();
}

const RuntimeImpl = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: c.mbedtls_x509_crt,
    config: c.mbedtls_ssl_config,
    trust_policy: TrustPolicy,
    mutex: std.Io.Mutex = .init,
    clients: usize = 0,
};

const TrustSource = union(enum) {
    pem: []const u8,
    der_bundle: []const u8,
};

const TrustPolicy = enum { system, copied_pem };

fn runtimeInit(io: std.Io, allocator: std.mem.Allocator, trust: TrustSource) InitOutcome {
    if (!validTrustSource(trust))
        return failedInit(error.InvalidTrustSnapshot, null);
    if (crypto_process.acquire(io)) |status|
        return failedInit(error.TlsCryptoInitializationFailed, status);
    var crypto_owned = true;
    defer if (crypto_owned) crypto_process.release(io);

    const self = allocator.create(RuntimeImpl) catch
        return failedInit(error.OutOfMemory, null);
    var self_owned = true;
    defer if (self_owned) allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .roots = undefined,
        .config = undefined,
        .trust_policy = switch (trust) {
            .pem => .copied_pem,
            .der_bundle => .system,
        },
    };
    c.mbedtls_x509_crt_init(&self.roots);
    var roots_owned = true;
    defer if (roots_owned) c.mbedtls_x509_crt_free(&self.roots);
    c.mbedtls_ssl_config_init(&self.config);
    var config_owned = true;
    defer if (config_owned) c.mbedtls_ssl_config_free(&self.config);

    const trust_summary = switch (parseTrust(&self.roots, allocator, trust)) {
        .summary => |summary| summary,
        .failed => |failure| return .{ .failed = failure },
    };

    const defaults = c.mbedtls_ssl_config_defaults(
        &self.config,
        c.MBEDTLS_SSL_IS_CLIENT,
        c.MBEDTLS_SSL_TRANSPORT_STREAM,
        c.MBEDTLS_SSL_PRESET_DEFAULT,
    );
    if (defaults != 0)
        return failedInit(error.TlsConfigurationFailed, defaults);
    c.mbedtls_ssl_conf_authmode(&self.config, c.MBEDTLS_SSL_VERIFY_REQUIRED);
    c.mbedtls_ssl_conf_ca_chain(&self.config, &self.roots, null);
    crypto_owned = false;
    self_owned = false;
    roots_owned = false;
    config_owned = false;
    return .{ .runtime = .{
        .owner = @ptrCast(self),
        .trust = trust_summary,
    } };
}

/// Open a client engine. The hostname is both SNI and the verification name;
/// passing a resolved address in its place is a caller contract bug.
fn runtimeOpen(self: *RuntimeImpl, hostname: []const u8) OpenOutcome {
    if (!validHostname(hostname)) return failedOpen(error.InvalidTlsHostname, null);
    const implementation = self.allocator.create(ClientImpl) catch
        return failedOpen(error.OutOfMemory, null);
    implementation.* = .{ .runtime = self, .ssl = undefined };
    c.mbedtls_ssl_init(&implementation.ssl);
    var implementation_owned = true;
    defer if (implementation_owned) {
        c.mbedtls_ssl_free(&implementation.ssl);
        self.allocator.destroy(implementation);
    };

    const setup = c.mbedtls_ssl_setup(&implementation.ssl, &self.config);
    if (setup != 0) return failedOpen(error.TlsClientInitializationFailed, setup);

    const terminated = self.allocator.allocSentinel(u8, hostname.len, 0) catch
        return failedOpen(error.OutOfMemory, null);
    defer self.allocator.free(terminated);
    @memcpy(terminated[0..hostname.len], hostname);
    const set_name = c.mbedtls_ssl_set_hostname(&implementation.ssl, terminated.ptr);
    if (set_name != 0) return failedOpen(error.TlsClientInitializationFailed, set_name);
    c.mbedtls_ssl_set_bio(&implementation.ssl, implementation, send, receive, null);

    self.mutex.lockUncancelable(self.io);
    self.clients += 1;
    self.mutex.unlock(self.io);
    implementation_owned = false;
    return .{ .client = .init(implementation, &vtable) };
}

/// Destroy the trust/runtime owner only after every client barrier. A busy
/// refusal consumes nothing and may be retried after clients close.
fn runtimeDeinitOutcome(self: *RuntimeImpl) ?foundation.FailureChain {
    self.mutex.lockUncancelable(self.io);
    if (self.clients != 0) {
        self.mutex.unlock(self.io);
        return .init(error.TlsRuntimeBusy);
    }
    self.mutex.unlock(self.io);
    const allocator = self.allocator;
    c.mbedtls_ssl_config_free(&self.config);
    c.mbedtls_x509_crt_free(&self.roots);
    crypto_process.release(self.io);
    allocator.destroy(self);
    return null;
}

/// Compare the parsed immutable CA chains directly. This neither retains a
/// second trust snapshot nor creates a digest that could be logged or mistaken
/// for a public trust identifier.
fn sameRoots(left_root: *const c.mbedtls_x509_crt, right_root: *const c.mbedtls_x509_crt) bool {
    var left: ?*const c.mbedtls_x509_crt = left_root;
    var right: ?*const c.mbedtls_x509_crt = right_root;
    while (left != null and right != null) {
        const left_cert = left.?;
        const right_cert = right.?;
        if (left_cert.raw.len != right_cert.raw.len) return false;
        if (left_cert.raw.len != 0 and !std.mem.eql(
            u8,
            left_cert.raw.p[0..left_cert.raw.len],
            right_cert.raw.p[0..right_cert.raw.len],
        )) return false;
        left = left_cert.next;
        right = right_cert.next;
    }
    return left == null and right == null;
}

const Io = struct {
    exchange: engine.Exchange,
    ciphertext_in_at: usize = 0,
    ciphertext_out_at: usize = 0,
};

const ClientImpl = struct {
    runtime: *RuntimeImpl,
    ssl: c.mbedtls_ssl_context,
    io: ?*Io = null,
};

pub const max_trust_bytes: usize = 8 * 1024 * 1024;

fn validHostname(hostname: []const u8) bool {
    return hostname.len != 0 and hostname.len <= 253 and
        std.mem.indexOfScalar(u8, hostname, 0) == null;
}

fn validTrustSource(trust: TrustSource) bool {
    return switch (trust) {
        .pem => |pem| pem.len != 0 and pem.len <= max_trust_bytes and
            std.mem.indexOfScalar(u8, pem, 0) == null and
            std.mem.indexOf(u8, pem, "-----BEGIN CERTIFICATE-----") != null,
        .der_bundle => |der| der.len != 0 and der.len <= max_trust_bytes,
    };
}

fn failedInit(cause: anyerror, code: ?i32) InitOutcome {
    var failure = engine.Failure.init(.handshake, cause);
    failure.detail.engine_code = code;
    return .{ .failed = failure };
}

fn failedOpen(cause: anyerror, code: ?i32) OpenOutcome {
    var failure = engine.Failure.init(.handshake, cause);
    failure.detail.engine_code = code;
    return .{ .failed = failure };
}

fn failedSystemTrust(cause: anyerror) InitOutcome {
    var failure = engine.Failure.init(.handshake, error.SystemTrustUnavailable);
    failure.chain.note(cause);
    return .{ .failed = failure };
}

fn parseTrust(
    roots: *c.mbedtls_x509_crt,
    allocator: std.mem.Allocator,
    trust: TrustSource,
) ParseTrustOutcome {
    return switch (trust) {
        .pem => |pem| parsePemRoots(roots, allocator, pem),
        .der_bundle => |der| parseDerRoots(roots, der),
    };
}

const ParseTrustOutcome = union(enum) {
    summary: TrustSummary,
    failed: engine.Failure,
};

fn parsePemRoots(
    roots: *c.mbedtls_x509_crt,
    allocator: std.mem.Allocator,
    pem: []const u8,
) ParseTrustOutcome {
    const terminated = allocator.allocSentinel(u8, pem.len, 0) catch
        return .{ .failed = engine.Failure.init(.handshake, error.OutOfMemory) };
    defer allocator.free(terminated);
    @memcpy(terminated[0..pem.len], pem);
    const result = c.mbedtls_x509_crt_parse(roots, terminated.ptr, terminated.len + 1);
    if (result == 0) return .{ .summary = .{
        .loaded = std.mem.count(u8, pem, "-----BEGIN CERTIFICATE-----"),
    } };
    var failure = engine.Failure.init(.handshake, error.InvalidTrustSnapshot);
    failure.detail.engine_code = result;
    return .{ .failed = failure };
}

fn parseDerRoots(roots: *c.mbedtls_x509_crt, bytes: []const u8) ParseTrustOutcome {
    var at: usize = 0;
    var loaded: usize = 0;
    var skipped: usize = 0;
    var first_unsupported: ?i32 = null;
    while (at < bytes.len) {
        const len = derObjectLength(bytes[at..]) orelse return .{
            .failed = engine.Failure.init(.handshake, error.InvalidSystemTrustStore),
        };
        const result = c.mbedtls_x509_crt_parse_der(roots, bytes[at..][0..len].ptr, len);
        if (result == 0) {
            loaded += 1;
        } else if (result == c.MBEDTLS_ERR_X509_ALLOC_FAILED) {
            var failure = engine.Failure.init(.handshake, error.InvalidSystemTrustStore);
            failure.detail.engine_code = result;
            return .{ .failed = failure };
        } else {
            first_unsupported = first_unsupported orelse result;
            skipped += 1;
        }
        at += len;
    }
    if (loaded != 0) return .{ .summary = .{
        .loaded = loaded,
        .skipped_by_engine = skipped,
        .first_skipped_engine_code = first_unsupported,
    } };
    var failure = engine.Failure.init(.handshake, error.InvalidSystemTrustStore);
    failure.detail.engine_code = first_unsupported;
    return .{ .failed = failure };
}

/// Length of one definite-length DER object, including tag and length bytes.
/// The platform bundle has already validated each certificate; this framing
/// walk exists only because Mbed TLS accepts one DER certificate per call.
fn derObjectLength(bytes: []const u8) ?usize {
    if (bytes.len < 2 or bytes[0] != 0x30) return null;
    const first = bytes[1];
    if (first & 0x80 == 0) {
        const total = @as(usize, 2) + first;
        return if (total <= bytes.len) total else null;
    }
    const length_bytes: usize = first & 0x7f;
    if (length_bytes == 0 or length_bytes > @sizeOf(usize) or
        bytes.len < 2 + length_bytes)
        return null;
    var payload: usize = 0;
    for (bytes[2 .. 2 + length_bytes]) |byte|
        payload = std.math.add(usize, std.math.mul(usize, payload, 256) catch return null, byte) catch return null;
    const header = 2 + length_bytes;
    const total = std.math.add(usize, header, payload) catch return null;
    return if (total <= bytes.len) total else null;
}

fn send(raw: ?*anyopaque, bytes: [*c]const u8, len: usize) callconv(.c) c_int {
    const self: *ClientImpl = @ptrCast(@alignCast(raw orelse return c.MBEDTLS_ERR_SSL_INTERNAL_ERROR));
    const io = self.io orelse return c.MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    const available = io.exchange.ciphertext_out.len - io.ciphertext_out_at;
    if (available == 0) return c.MBEDTLS_ERR_SSL_WANT_WRITE;
    const count = @min(len, @min(available, @as(usize, std.math.maxInt(c_int))));
    @memcpy(
        io.exchange.ciphertext_out[io.ciphertext_out_at..][0..count],
        bytes[0..count],
    );
    io.ciphertext_out_at += count;
    return @intCast(count);
}

fn receive(raw: ?*anyopaque, bytes: [*c]u8, len: usize) callconv(.c) c_int {
    const self: *ClientImpl = @ptrCast(@alignCast(raw orelse return c.MBEDTLS_ERR_SSL_INTERNAL_ERROR));
    const io = self.io orelse return c.MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    const available = io.exchange.ciphertext_in.len - io.ciphertext_in_at;
    if (available == 0) return c.MBEDTLS_ERR_SSL_WANT_READ;
    const count = @min(len, @min(available, @as(usize, std.math.maxInt(c_int))));
    @memcpy(bytes[0..count], io.exchange.ciphertext_in[io.ciphertext_in_at..][0..count]);
    io.ciphertext_in_at += count;
    return @intCast(count);
}

fn step(raw: *anyopaque, phase: engine.Phase, exchange: engine.Exchange) engine.RawOutcome {
    const self: *ClientImpl = @ptrCast(@alignCast(raw));
    var io = Io{ .exchange = exchange };
    std.debug.assert(self.io == null);
    self.io = &io;
    defer self.io = null;

    const result: c_int = switch (phase) {
        .handshake => c.mbedtls_ssl_handshake(&self.ssl),
        .receive => c.mbedtls_ssl_read(&self.ssl, exchange.plaintext_out.ptr, exchange.plaintext_out.len),
        .transmit => c.mbedtls_ssl_write(&self.ssl, exchange.plaintext_in.ptr, exchange.plaintext_in.len),
        .shutdown => c.mbedtls_ssl_close_notify(&self.ssl),
    };
    var transfer = engine.Transfer{
        .ciphertext_consumed = io.ciphertext_in_at,
        .ciphertext_produced = io.ciphertext_out_at,
    };

    if (result == c.MBEDTLS_ERR_SSL_WANT_READ or result == c.MBEDTLS_ERR_SSL_WANT_WRITE) {
        return .{ .stepped = .{
            .interest = .{
                .read = result == c.MBEDTLS_ERR_SSL_WANT_READ,
                .write = result == c.MBEDTLS_ERR_SSL_WANT_WRITE,
            },
            .transfer = transfer,
        } };
    }
    if (phase == .handshake and result == 0)
        return .{ .stepped = .{ .status = .established, .transfer = transfer } };
    if (phase == .receive and result > 0) {
        transfer.plaintext_produced = @intCast(result);
        return .{ .stepped = .{ .transfer = transfer } };
    }
    if (phase == .transmit and result > 0) {
        transfer.plaintext_consumed = @intCast(result);
        return .{ .stepped = .{ .transfer = transfer } };
    }
    if (result == c.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY or
        (phase == .shutdown and result == 0))
        return .{ .stepped = .{ .status = .clean_close, .transfer = transfer } };
    if (phase == .receive and result == 0)
        return failed(self, phase, error.TlsTruncated, result, transfer);
    return failed(self, phase, phaseCause(phase), result, transfer);
}

fn phaseCause(phase: engine.Phase) anyerror {
    return switch (phase) {
        .handshake => error.TlsHandshakeFailed,
        .receive => error.TlsReceiveFailed,
        .transmit => error.TlsTransmitFailed,
        .shutdown => error.TlsShutdownFailed,
    };
}

fn failed(
    self: *ClientImpl,
    phase: engine.Phase,
    fallback: anyerror,
    code: i32,
    transfer: engine.Transfer,
) engine.RawOutcome {
    // Mbed documents the verification result only for a completed
    // certificate-verification attempt. Before that point it can contain a
    // sentinel whose bits resemble real certificate refusals.
    const flags: u32 = if (code == c.MBEDTLS_ERR_X509_CERT_VERIFY_FAILED)
        c.mbedtls_ssl_get_verify_result(&self.ssl)
    else
        0;
    const cause = if (code == c.MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE)
        error.TlsPeerAlert
    else if (flags & c.MBEDTLS_X509_BADCERT_CN_MISMATCH != 0)
        error.CertificateNameMismatch
    else if (flags & c.MBEDTLS_X509_BADCERT_EXPIRED != 0)
        error.CertificateExpired
    else if (flags & c.MBEDTLS_X509_BADCERT_NOT_TRUSTED != 0)
        error.CertificateUntrusted
    else if (flags != 0)
        error.CertificateVerificationFailed
    else
        fallback;
    const alert = c.mbedtls_ssl_get_fatal_alert(&self.ssl);
    return .{ .failed = .{
        .failure = .{
            .phase = phase,
            .chain = .init(cause),
            .detail = .{
                .verification_flags = flags,
                .peer_alert = if (alert >= 0 and alert <= std.math.maxInt(u8)) @intCast(alert) else null,
                .engine_code = code,
            },
        },
        .transfer = transfer,
    } };
}

fn deinit(raw: *anyopaque) ?foundation.FailureChain {
    const self: *ClientImpl = @ptrCast(@alignCast(raw));
    const runtime = self.runtime;
    c.mbedtls_ssl_free(&self.ssl);
    runtime.mutex.lockUncancelable(runtime.io);
    std.debug.assert(runtime.clients != 0);
    runtime.clients -= 1;
    runtime.mutex.unlock(runtime.io);
    runtime.allocator.destroy(self);
    return null;
}

const vtable: engine.VTable = .{ .step = step, .deinit = deinit };
