//! Ban rows: the one writer of the Host's callback latch, id counter, and
//! vow rows, and the policy the C ABI projects without re-deciding.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

/// `CallbackLatch` is the one writer of the Host's reentrancy latch. A site
/// that sets or clears the flag by hand can unlatch an outer holder.
pub const callback_latch_owner: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"}, .exclude = &.{"src/driver/core/host/admission.zig"} } },
        .kind = .forbid,
        .needles = &.{"callback_latch.held"},
        .check = "callback-latch-owner",
        .why = "hold the Host's callback latch through CallbackLatch.hold so every holder restores the state it found",
    },
    .{
        .where = .{ .tree = .{ .dir = "test", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"callback_latch.held"},
        .check = "callback-latch-owner",
        .why = "hold the Host's callback latch through CallbackLatch.hold so every holder restores the state it found",
    },
};

/// `IdIssuer` alone advances an id counter, so an id is spent only when its
/// operation commits and the counter cannot overflow.
pub const id_issuer_owner: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"}, .exclude = &.{"src/foundation/id_issuer.zig"} } },
        .kind = .forbid,
        .needles = &.{"_ids.next"},
        .check = "id-issuer-owner",
        .why = "peek and commit ids through IdIssuer so a refusal spends nothing and the counter never overflows",
    },
};

/// `settlement.retireRow` is the one exit for a published Host vow row, so a
/// row retires only once settled and never strands the pending count.
pub const vow_row_retirement: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/driver", .suffixes = &.{".zig"}, .exclude = &.{"src/driver/core/vows/settlement.zig"} } },
        .kind = .forbid,
        .needles = &.{ ".vows.remove(", ".vows.fetchRemove(" },
        .check = "vow-row-retirement",
        .why = "retire a Host vow row through settlement.retireRow so only a settled row leaves the table",
    },
};

/// The C ABI projects what `driver_core` decides and re-decides none of it.
/// `arch-check` sees only imports, so a C surface reaching into the runtime's
/// sessions, options, latch, or admission verbs looks like an ordinary call to
/// the compiler. These names are the policy the C layer must stay out of.
pub const c_abi_policy_projection: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/c_abi/driver/loop", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &driver_loop_policy,
        .check = "c-abi-policy-projection",
        .why = "the C driver loop invokes HostRuntime and projects its result instead of re-deciding admission, failure, or ownership",
    },
    .{
        .where = .{ .file = "src/c_abi/driver/loop.zig" },
        .kind = .forbid,
        .needles = &driver_loop_policy,
        .check = "c-abi-policy-projection",
        .why = "the C driver loop invokes HostRuntime and projects its result instead of re-deciding admission, failure, or ownership",
    },
    .{
        .where = .{ .files = &.{
            "src/c_abi/host/error.zig",
            "src/c_abi/host/hosted_behavior.zig",
            "src/c_abi/host/instance.zig",
            "src/c_abi/host/marshal.zig",
            "src/c_abi/host/host.zig",
            "src/c_abi/host/session.zig",
            "src/c_abi/host/turn.zig",
        } },
        .kind = .forbid,
        .needles = &.{
            "registerBootstrapCap(",
            "exportNextObject(",
            "restoreBootstrapMapping(",
            "releaseUnsharedExport(",
            ".vat.spawnHosted(",
            ".served.bindExport(",
            "liftLocalActor(",
            ".core.sessions",
            ".session_state.",
            ".core.callback_latch",
            ".core.opts",
            "refuseLatched",
            ".liftCapabilityTracked(",
            ".rollbackCapabilityLift(",
            ".discardCapabilityObservation(",
            "fn issueCapabilityId(",
            "capability_key_state",
            "permuteCapabilityId(",
        },
        .check = "c-abi-policy-projection",
        .why = "bootstrap, export, Vat insertion, and capability adoption stay behind one driver_core operation that the C Host surface calls",
    },
};

const driver_loop_policy = [_][]const u8{
    "admitRuntimeOperation",
    "mutationCode(",
    "if (terminalCode(inst))",
    "err == error.MissingAdvertisedLocator",
    "runtime.wires",
    "inst.runtime.core",
    "runtime.core.releaseDriverOwnership",
    ".core.callback_latch",
    ".core.opts",
    "runtime.terminalFailure()",
    "runtime.terminalCleanupPending()",
};

/// A peer locator and an authority-bearing sturdyref are distinct values at
/// the C boundary. The shared locator view carries no swissnum, and the C URI
/// surface spells a sturdyref through the caller's CapTP profile rather than
/// the model's 1.0 convenience verbs.
pub const locator_sturdyref_split: []const Ban = &.{
    .{
        .where = .{ .file = "src/c_abi/shared/locator.zig" },
        .kind = .forbid,
        .needles = &.{ "swiss", "Swiss" },
        .check = "locator-sturdyref-split",
        .why = "GlowcapLocatorView names a peer and never carries sturdyref authority",
    },
    .{
        .where = .{ .file = "src/c_abi/ocapn/uri.zig" },
        .kind = .forbid,
        .needles = &.{ "parseSturdyref(allocator", "writeSturdyref(alloc" },
        .check = "locator-sturdyref-split",
        .why = "the C URI surface selects swissnum form through the caller's CapTP profile",
    },
};
