//! Runtime lifecycle recipients and listener-owned transport state.
//!
//! These are bounded values retained across turns. They describe who owns a
//! committed outcome. The HostRuntime remains the only component that drives
//! transport I/O or chooses lifecycle policy. The observer callbacks keep
//! `anyerror` return sets: their implementors are application code unknown at
//! these declarations.

const std = @import("std");

const model = @import("model");
const net = @import("net");
const driver_core = @import("driver_core");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

/// One bound listener: a profile's listener on a registered resident.
pub const TransportListener = struct {
    transport: []const u8,
    designator_scheme: net.netlayer.DesignatorScheme,
    /// The resident's index in the runtime's registry.
    resident: usize,
    listener: net.MultiplexedResident.Listener,

    pub fn transportName(self: *const TransportListener) []const u8 {
        return self.transport;
    }

    pub fn designatorScheme(self: *const TransportListener) net.netlayer.DesignatorScheme {
        return self.designator_scheme;
    }
};

pub const ListenerStopOutcome = struct {
    found: bool,
    pending: bool = false,
    failure: ?OperationFailure = null,
};

pub const ActiveListener = struct {
    transport: TransportListener,
    locator: model.PeerLocator,
    closing: bool = false,
    /// A provider/readiness failure that retired the listener. Explicit close
    /// leaves this null. Asynchronous stop failure is then the primary.
    terminal_failure: ?OperationFailure = null,
};

/// A complete locator prepared by the driver but not yet published. status-allow: pending state or quoted runtime label
pub const PreparedListenerLocator = struct {
    value: model.PeerLocator,

    pub fn deinit(self: *PreparedListenerLocator, allocator: std.mem.Allocator) void {
        model.freePeerLocator(allocator, self.value);
        self.* = undefined;
    }
};

pub const PrepareListenerLocatorOutcome = union(enum) {
    ready: PreparedListenerLocator,
    failed: net.netlayer.ListenFailure,
};

/// A taker for application-visible completions the Zig face would
/// otherwise free. Reservation makes post-commit publication infallible.
pub const CompletionSink = struct {
    ctx: *anyopaque,
    reserve: *const fn (ctx: *anyopaque) anyerror!void = reserveNothing,
    release: *const fn (ctx: *anyopaque) void = releaseNothing,
    take: *const fn (ctx: *anyopaque, action: driver_core.HostAction) bool,
};

/// The one recipient for a wire's physically completed close outcome.
pub const CloseObserver = struct {
    ctx: *anyopaque,
    reserve: *const fn (ctx: *anyopaque) anyerror!void = reserveNothing,
    release: *const fn (ctx: *anyopaque) void = releaseNothing,
    closed: *const fn (
        ctx: *anyopaque,
        session: *driver_core.HostSession,
        failure: ?OperationFailure,
    ) void,
};

/// How a HostRuntime is driven, chosen once at construction. The blocking
/// Zig face waits on the live wires itself. The stepped face hands an
/// embedder one readiness descriptor and publishes through the recipients
/// below (ADR-0024).
pub const DriveOptions = union(enum) {
    blocking,
    stepped: SteppedOptions,
};

/// The two recipients a stepped runtime publishes through. Both arrive with
/// the readiness set, before any wire exists, so every wire the runtime adopts
/// reserves its close publication at adoption and every unclaimed completion
/// has a taker. Neither is optional on that face.
pub const SteppedOptions = struct {
    completion_sink: CompletionSink,
    close_observer: CloseObserver,
};

/// One staged session-open outcome recipient.
pub const SessionOpenObserver = struct {
    ctx: *anyopaque,
    reserve: *const fn (ctx: *anyopaque, tag: u64) anyerror!void = reserveNoop,
    release: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
    abandoned: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
    opened: *const fn (ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) anyerror!void,
    failed: *const fn (ctx: *anyopaque, tag: u64, failure: OperationFailure) void,
};

/// Outcome recipient for connections admitted by a listener. Per-arrival
/// handshake abandonment is distinct from terminal listener retirement.
pub const SessionAcceptObserver = struct {
    ctx: *anyopaque,
    /// Ordinary queue pressure refuses this arrival without failing the host.
    can_accept: *const fn (ctx: *anyopaque) bool = canAcceptAlways,
    /// An arrival failed after admission. Reservation release remains with
    /// abandoned. Blocking consumers may additionally report its exact cause.
    arrival_failed: ?*const fn (ctx: *anyopaque, tag: u64, failure: OperationFailure) void = null,
    reserve: *const fn (ctx: *anyopaque, tag: u64) anyerror!void = reserveNoop,
    release: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
    abandoned: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
    retired: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
    opened: *const fn (ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) anyerror!void,
    failed: *const fn (ctx: *anyopaque, tag: u64, failure: OperationFailure) void,
};

/// Outcome recipient for one generic listener-construction operation.
pub const ListenerObserver = struct {
    ctx: *anyopaque,
    reserve: *const fn (ctx: *anyopaque, tag: u64) anyerror!void = reserveNoop,
    release: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
    abandoned: *const fn (ctx: *anyopaque, tag: u64) void = releaseNoop,
    ready: *const fn (ctx: *anyopaque, tag: u64, listener: TransportListener) void,
    failed: *const fn (ctx: *anyopaque, tag: u64, failure: OperationFailure) void,
};

/// Which Host half an externally established channel supplies.
pub const ExternalAdoptionRole = enum { dialed, accepted };
pub const OpenAdmissionAuthority = enum { application, pending_dial };
pub const ExternalEffectMode = enum { operational, cleanup_only };

pub const StepGoal = union(enum) {
    none,
    host_close,
    session_close: *const driver_core.HostSession,
    listener_stop: u64,
    condition: struct {
        ctx: *const anyopaque,
        reached_fn: *const fn (*const anyopaque) bool,
    },

    pub fn reached(self: StepGoal, runtime: anytype) bool {
        return switch (self) {
            .none => false,
            .host_close => runtime.closeOutcome() != .pending,
            .session_close => |session| runtime.sessionCloseOutcome(session) != .pending,
            .listener_stop => |tag| runtime.ownedListenerLocator(tag) == null,
            .condition => |probe| probe.reached_fn(probe.ctx),
        };
    }
};

pub const SessionOpenObservation = struct {
    observer: SessionOpenObserver,
    tag: u64,
};

pub const SessionAcceptObservation = struct {
    observer: SessionAcceptObserver,
    tag: u64,
};

fn reserveNothing(_: *anyopaque) anyerror!void {}
fn canAcceptAlways(_: *anyopaque) bool {
    return true;
}
fn releaseNothing(_: *anyopaque) void {}
fn reserveNoop(_: *anyopaque, _: u64) anyerror!void {}
fn releaseNoop(_: *anyopaque, _: u64) void {}
