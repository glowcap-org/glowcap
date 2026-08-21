//! Every table keyed on a bare name has to say whose name it is, and when.
//!
//! A name that indexes a table is three things: the namespace it belongs to,
//! the party whose namespace that is, and the moment it meant what it meant. A
//! Zig type carries the first. A key of `u64` or `[]const u8` carries only the
//! first, and the other two live in whatever the author was thinking at the
//! time.
//!
//! That gap is the single most expensive class of bug this core has had. Each
//! instance was one missing dimension:
//!
//! - *whose*: a near from one session named an object on another; a resolve
//!   minted an export outside the session's own range; two gifters reusing one
//!   gift id landed on one row; the handoff replay counter keyed on bytes the
//!   withdrawing peer supplied.
//! - *when*: a projection settled an answer position the partner had released
//!   and reasked; an enrolled token outlived the import row it named.
//!
//! Every fix that held added a dimension — disjoint ranges, identity stamps,
//! domain separation, a token that dies with its row. Every fix that had to be
//! taken back tried to *police* the collision instead: refusing a re-deposit
//! invented an ownership rule the protocol does not have and broke the upstream
//! suite.
//!
//! So this is not a style check. Each bare-keyed table below states its answer
//! to both questions, and a table that is not listed fails the build. The point
//! is that the next one has to answer at review time, when answering is a
//! sentence, rather than at incident time, when it is a bisect.
//!
//! A table whose key is a distinct type or a composite struct needs no entry:
//! the key carries the dimensions itself, which is the shape to prefer. Bare
//! means the shape says how wide a name is and nothing about whose it is: a
//! primitive integer, a byte array, or a platform handle (`isBareKeyType`).
//!
//! What this cannot see is a named type that is an integer alias in disguise.
//! `bare_handle_types` lists the ones in this tree by hand for that reason, so
//! a new alias is a name to add there rather than something the check resolves
//! on its own. An entry may also answer "not closed", and two do; that is a
//! recorded boundary, not a pass.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// One bare-keyed table and what makes its key unambiguous.
const Table = struct {
    /// Path under `src/`.
    file: []const u8,
    /// The field or declaration name the key belongs to.
    name: []const u8,
    /// Whose namespace the key lives in, and why one party's name cannot reach
    /// another's row.
    owner: []const u8,
    /// What keeps a name from meaning one thing and later another — or why
    /// reuse cannot happen here.
    epoch: []const u8,
};

const registered = [_]Table{
    .{
        .file = "ocapn/session/answers/store.zig",
        .name = "rows",
        .owner = "Detached inbound-answer notifications inside one Session; no other session can reach this private store.",
        .epoch = "The key is Session.nextStoreStamp's monotonic row id, never a reusable wire position; the store and counter die with the session.",
    },
    .{
        .file = "ocapn/session/slot_table.zig",
        .name = "rows",
        .owner = "Reached only through ExportTable/ImportTable, whose Id types are distinct and whose export half admits a position only inside this session's range.",
        .epoch = "Export positions are ours and monotonic. Import positions are the partner's and may be reused; readers that hold one across time are named in docs/boundaries.md.",
    },
    .{
        .file = "ocapn/session/slot_table.zig",
        .name = "IdentityMap",
        .owner = "One map per import table, so Node tokens and Host refs are looked up only under the session that owns the import row.",
        .epoch = "The import row owns both identities and drops them when it goes; the Host target also carries a monotonic incarnation, so a reused position cannot revive either old handle.",
    },
    .{
        .file = "ocapn/session/mod.zig",
        .name = "bootstrap",
        .owner = "Swissnums this session published; the map is per session, so another partner's names are not in it.",
        .epoch = "Registering a swissnum replaces its mapping, and the map dies with the session.",
    },
    .{
        .file = "ocapn/session/mod.zig",
        .name = "pending_enlivens",
        .owner = "Swissnums this session is enlivening; per session.",
        .epoch = "A row lives only between the enliven's send and its settle, and is removed at either outcome.",
    },
    .{
        .file = "ocapn/session/mod.zig",
        .name = "sturdyref_cache_index",
        .owner = "Swissnums this session enlivened; per session.",
        .epoch = "NOT CLOSED. The cached row holds a partner-allocated import position across time without re-checking identity, so a partner that reused one would be answered for the object the number used to name. Recorded in docs/boundaries.md as a dependence on the partner allocating monotonically.",
    },
    .{
        .file = "ocapn/session/gc.zig",
        .name = "map",
        .owner = "Positions in one session's own tables, reached through the typed GC verbs.",
        .epoch = "Counters are per position and cleared when the row they count is released.",
    },
    .{
        .file = "ocapn/engine/bootstrap/gifts.zig",
        .name = "gifts",
        .owner = "Gift ids the partner chose, scoped by the containing Peer: only deposits and withdrawals resolved to this exact CapTP session can reach the row.",
        .epoch = "A live row is replaced by re-deposit, removed by withdrawal, and every remaining row dies with the session; no id survives into a later session epoch.",
    },
    .{
        .file = "ocapn/engine/node/handoffs/waiters.zig",
        .name = "gifts",
        .owner = "A fixed scheduler tag is reached only beneath the outer gifter PeerHandle row, so equal gift ids on different sessions cannot share waiters.",
        .epoch = "The group exists only while receivers await that exact live gifter session; consuming the last waiter removes it, and gifter closure marks only that session's groups for settlement.",
    },
    .{
        .file = "ocapn/engine/node/locators.zig",
        .name = "by_transport",
        .owner = "Transport names in this node's own locator Catalog; callers cannot select another node because the Catalog is an inline Node field.",
        .epoch = "Replacement atomically swaps the owned snapshot for that transport, removal deletes it, and the complete registry dies with the Node.",
    },
    .{
        .file = "ocapn/engine/node/redeem/dials.zig",
        .name = "exporters",
        .owner = "Canonical exporter locator bytes, which name a peer rather than a slot in any conversation.",
        .epoch = "Rows naming a dead session are evicted at removePeer, so a later give dials fresh rather than failing against a gone one.",
    },
    .{
        .file = "ocapn/engine/node/redeem/dials.zig",
        .name = "by_identity",
        .owner = "Exporter identity parsed from a give, not a spelling a peer chose.",
        .epoch = "A row lives only between staging a dial and its outcome, and is removed at either.",
    },
    .{
        .file = "ocapn/engine/node/redeem/dials.zig",
        .name = "pending",
        .owner = "Tickets this node mints from the same `actions.State.next_ticket` counter as gifter entropy tickets; a peer never names one.",
        .epoch = "A row lives only between staging a dial and its outcome, removed at either, and the counter is monotonic so a retired ticket finds nothing.",
    },
    .{
        .file = "ocapn/engine/node/redeem/dials.zig",
        .name = "pending_dials",
        .owner = "A cancellation iterator borrows the ticket namespace owned by `State.pending`; it is not a second table or ticket authority.",
        .epoch = "The iterator exists only for one cancellation pass over the live pending rows and cannot outlive its Node.",
    },
    .{
        .file = "ocapn/engine/node/handoffs/gifts/tickets.zig",
        .name = "by_ticket",
        .owner = "Tickets this node mints for its own gift-id draws.",
        .epoch = "Monotonic; a row is removed when its ticket is answered.",
    },
    .{
        .file = "driver/core/host.zig",
        .name = "peer_by_durable",
        .owner = "Durable peer identities a partner *proved* to this host (ADR-0097). Only an authenticated designator is indexed, so an unproved claim cannot occupy dial availability, and the bytes are the session's own arena-held designator. Deliberately not partner_by_side, which names a session incarnation by the key that signed it.",
        .epoch = "Written when the partner's handshake half arrives and never rewritten; the row clears on unindex, condemn, and release, and removal is identity-checked so a released session cannot evict a newer session's row for the same peer.",
    },
    .{
        .file = "driver/core/host.zig",
        .name = "giftables",
        .owner = "Application-installed bootstrap aliases in one Host; only that Host's projection seam resolves them for its session Ports.",
        .epoch = "Replacement intentionally changes discovery in place and Host teardown removes the row. Issued capabilities and deposited gifts retain Vat targets instead of this mutable name.",
    },
    .{
        .file = "driver/core/host.zig",
        .name = "transport_profiles",
        .owner = "Transport symbols supplied by providers attached to this Host; canonical symbols must carry their exact model.transport profile, and extension names are copied into Host ownership.",
        .epoch = "A registration owns the row until its provider is removed, duplicate occupancy is refused, and sessions retain their transport symbol only while that registration's owning driver remains alive.",
    },
    .{
        .file = "driver/host_runtime.zig",
        .name = "listener_profiles",
        .owner = "Canonical transport symbols from providers attached to this HostRuntime; the runtime itself is the owner dimension and no other runtime can reach the map.",
        .epoch = "A row exists only while one listener setup or active listener owns that transport profile, and close or setup failure removes it before the provider registry is released.",
    },
    .{
        .file = "driver/host_runtime.zig",
        .name = "active_listeners",
        .owner = "Observer tags supplied to one HostRuntime; the containing runtime is the owner dimension, and no other runtime can route a callback to this map.",
        .epoch = "The pending setup transfers its tag to at most one active row. Close or setup failure cancels every callback before removing that row, so later tag reuse cannot reach an earlier listener.",
    },
    .{
        .file = "driver/core/host.zig",
        .name = "vows",
        .owner = "Vow ids this host mints from one counter.",
        .epoch = "Monotonic; a row retires when its vow settles.",
    },
    .{
        .file = "actors/vat/mod.zig",
        .name = "actors",
        .owner = "Actor ids one vat mints; the table is per vat.",
        .epoch = "Monotonic within the vat; a cell is removed when its actor is gone.",
    },
    .{
        .file = "actors/vat/port.zig",
        .name = "exports",
        .owner = "Export positions the session allocated, mapped to vat-local actor ids; one table per Port.",
        .epoch = "Export positions are never reused, so a stale one maps to nothing.",
    },
    .{
        .file = "actors/vat/port.zig",
        .name = "reverse_exports",
        .owner = "Vat-local actor ids projected by one Port; the containing Port supplies the session owner dimension.",
        .epoch = "Actor ids are monotonic within the Vat and never reused; rollback removes a projection that never became observable.",
    },
    .{
        .file = "actors/vat/mod.zig",
        .name = "listeners",
        .owner = "Answer positions on the vat's own sessions; per vat.",
        .epoch = "A listener row is removed when it fires or its session goes.",
    },
    .{
        .file = "actors/vat/mod.zig",
        .name = "resolver_vows",
        .owner = "Resolver ids minted by this vat's own monotonic counter (ADR-0102); the map is the vat's, so the vat is the owner dimension.",
        .epoch = "Ids are never reused, and a row is consumed by the first settle attempt, so a resolver maps to a live authority or to nothing.",
    },
    .{
        .file = "driver/core/host.zig",
        .name = "resolver_index",
        .owner = "Host resolver ids from the host's own monotonic counter (ADR-0102), distinct from the vow-id namespace beside it; per host.",
        .epoch = "Ids are never reused, and a row is consumed by the first settle attempt, so a resolver maps to a live authority or to nothing.",
    },
    .{
        .file = "actors/vat/boxed.zig",
        .name = "boxes",
        .owner = "Actor ids from the same vat-local space as `actors`.",
        .epoch = "A box is refcounted and freed at the last reference, so an id maps to a live box or to nothing.",
    },
    .{
        .file = "driver/core/host.zig",
        .name = "partner_by_side",
        .owner = "The OCapN side derived from a partner session key whose handshake signature this Host verified; a peer cannot choose another side without presenting a key that hashes to it.",
        .epoch = "The row is inserted when the key is verified and removed on unindex, condemn, and release; key-shaped lookups compare the selected shell's exact retained key before accepting equality.",
    },
    .{
        .file = "c_abi/net_transport/iroh/ownership.zig",
        .name = "conns",
        .owner = "The sidecar's endpoint-scoped connection ids: the endpoint mints them from one counter and never reuses one for its lifetime, so no other endpoint's id can alias a row (one adapter per netlayer, one netlayer per endpoint).",
        .epoch = "A row enters when `finish_connect` claims the connection and leaves at `conn_close` (or netlayer release, which sweeps stragglers). A stale id looks up nothing — the resident contract's drain-to-nothing rule.",
    },
    .{
        .file = "driver/bridge.zig",
        .name = "pending_connects",
        .owner = "Loop slot indices this bridge itself handed out; a slot is the loop's own array position, never a number a partner supplied.",
        .epoch = "A row lives only between the dial and its outcome, removed by `makeConnCtx` on connect and `onClose` on refusal, so a reused slot cannot inherit the previous dial's row.",
    },
    .{
        .file = "net/completion/kqueue.zig",
        .name = "pending",
        .owner = "File descriptors this backend opened or accepted, in one process's descriptor table. No peer names one.",
        .epoch = "NOT CLOSED by the key. The OS reuses a descriptor as soon as it closes, so a row outliving its socket would be read for the next socket to land on that number. What holds it is the submit/complete discipline: the row is inserted when the completion is submitted and removed when it fires or the fd closes, and the fd cannot be reused while the backend still holds it open.",
    },
    .{
        .file = "net/transport/iroh/backend.zig",
        .name = "conns",
        .owner = "Synthetic descriptors this backend mints from its own `next_fd` counter to stand in for sidecar connections. They are not OS descriptors and nothing outside this backend chooses one.",
        .epoch = "Monotonic and never reused, so a stale synthetic fd finds no row rather than another connection's.",
    },
    .{
        .file = "net/transport/iroh/backend.zig",
        .name = "by_id",
        .owner = "Connection ids the bound sidecar endpoint mints; the reverse of `conns`, scoped to this backend and endpoint.",
        .epoch = "Monotonic and never reused during the endpoint lifetime, so queued readiness for a released connection cannot name its replacement.",
    },
    .{
        .file = "net/transport/webrtc/backend/state.zig",
        .name = "conns",
        .owner = "Synthetic descriptors this backend mints from its own `next_fd` counter to stand in for sidecar peers. They are not OS descriptors and nothing outside this backend chooses one.",
        .epoch = "Monotonic and never reused, so a stale synthetic fd finds no row rather than another peer's.",
    },
    .{
        .file = "net/transport/webrtc/backend/state.zig",
        .name = "by_id",
        .owner = "Peer ids the bound sidecar resident mints (`ReadyEvent.subject`); the reverse of `conns` plus the pre-open rows, scoped to this backend and resident.",
        .epoch = "Stable and never reused during the resident lifetime, so queued readiness for a released peer cannot name its replacement.",
    },
    .{
        .file = "c_abi/net_transport/webrtc/ownership.zig",
        .name = "peers",
        .owner = "Peer subjects minted by this WebRTC netlayer resident; callers can submit only an id returned by this same endpoint's peer handle.",
        .epoch = "Stable and never reused during the netlayer lifetime. A row remains while either the caller handle or the provider claim owns a reference, and stale readiness resolves to nothing.",
    },
    .{
        .file = "c_abi/net_transport/relay/runtime/mod.zig",
        .name = "by_id",
        .owner = "Connection ids minted by one relay runtime and returned only through handles from that same provider lease.",
        .epoch = "Monotonic and never reused during the runtime lifetime, so stale readiness or handles cannot resolve to a replacement connection.",
    },
    .{
        .file = "net/transport/webrtc/backend/state.zig",
        .name = "pending_dials",
        .owner = "Synthetic descriptors this backend reserves from its own `next_fd` counter, doubling as the signaling exchange tokens its authority routes by.",
        .epoch = "Monotonic and never reused. A row lives from `startDial` through the channel's open, its close, or `closeFd`.",
    },
    .{
        .file = "net/transport/webrtc/backend/state.zig",
        .name = "adopting",
        .owner = "The same synthetic-descriptor namespace as `pending_dials`, reserved by `adoptAnswerer` for signaled inbound peers.",
        .epoch = "Monotonic and never reused. A row lives from adoption through the channel's open or its close.",
    },
    .{
        .file = "net/transport/iroh/backend.zig",
        .name = "pending_dials",
        .owner = "Synthetic descriptors this backend reserves from its own `next_fd` counter and also supplies as sidecar request ids.",
        .epoch = "Monotonic and never reused. A row lives from accepted start through the sole terminal EV_CONNECT, including cancellation.",
    },
    .{
        .file = "net/transport/inproc.zig",
        .name = "listeners",
        .owner = "In-process designators registered in one process-local registry.",
        .epoch = "A row lives while its listener is bound and is removed when it closes.",
    },
};

/// Named types that are integer handles in disguise. The compiler sees a name,
/// but the value is a number an operating system or a peer chose, so both
/// questions still apply — an fd in particular is reused the moment it closes.
/// Add one here rather than teaching this to resolve aliases: the list is short
/// because a genuinely distinct key type is the shape to prefer.
const bare_handle_types = [_][]const u8{ "Fd", "c.fd_t", "std.posix.fd_t", "posix.fd_t", "PendingId" };

/// Whether `key` names a shape that carries no owner and no epoch of its own.
///
/// A primitive integer or a byte array says how wide a name is and nothing
/// about whose it is. A named type is not bare, which is what exempts a
/// composite key like `WithdrawKey` without an entry: the type carries the
/// dimensions itself.
fn isBareKeyType(key: []const u8) bool {
    const t = std.mem.trim(u8, key, " \t");
    if (t.len == 0) return false;
    if (t[0] == '[') return true;
    if (std.mem.eql(u8, t, "usize") or std.mem.eql(u8, t, "isize")) return true;
    if ((t[0] == 'u' or t[0] == 'i') and t.len > 1) {
        var digits = true;
        for (t[1..]) |c| {
            if (!std.ascii.isDigit(c)) {
                digits = false;
                break;
            }
        }
        if (digits) return true;
    }
    for (bare_handle_types) |h| {
        if (std.mem.eql(u8, t, h)) return true;
    }
    return false;
}

/// The key type of a hash-map declaration on `line`, or null when the line
/// declares no map. A `StringHashMap` keys on bytes, which is bare by
/// construction and has no key argument to read.
fn bareKeyOn(line: []const u8) bool {
    for ([_][]const u8{ "StringHashMapUnmanaged(", "StringHashMap(" }) |needle| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    for ([_][]const u8{ "AutoHashMapUnmanaged(", "AutoHashMap(" }) |needle| {
        const at = std.mem.indexOf(u8, line, needle) orelse continue;
        const rest = line[at + needle.len ..];
        // The key runs to the first comma outside any brackets, so `[N]u8`
        // survives and a nested generic does not end the key early.
        var depth: usize = 0;
        for (rest, 0..) |c, i| {
            switch (c) {
                '[', '(' => depth += 1,
                ']', ')' => {
                    if (depth == 0) return isBareKeyType(rest[0..i]);
                    depth -= 1;
                },
                ',' => if (depth == 0) return isBareKeyType(rest[0..i]),
                else => {},
            }
        }
    }
    return false;
}

fn isRegistered(file: []const u8, name: []const u8) bool {
    for (registered) |t| {
        if (std.mem.eql(u8, t.file, file) and std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

/// The declared name on a line like `    gifts: std.StringHashMapUnmanaged(...)`
/// or `    pub const TokenMap = std.AutoHashMapUnmanaged(u64, u64);`, or null
/// when the line is not a declaration (a local `var`, a parameter, a comment).
fn declaredName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "//")) return null;
    // A local binding is not a table the type system will carry anywhere.
    if (std.mem.startsWith(u8, trimmed, "var ")) return null;

    const decl = if (std.mem.startsWith(u8, trimmed, "pub const "))
        trimmed["pub const ".len..]
    else if (std.mem.startsWith(u8, trimmed, "const "))
        trimmed["const ".len..]
    else
        trimmed;

    const stop = std.mem.indexOfAny(u8, decl, ": =") orelse return null;
    if (stop == 0) return null;
    const name = decl[0..stop];
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    return name;
}

/// Every bare-keyed table under `src/` states its owner and epoch, and every
/// stated table still exists. Both directions, so a registry entry cannot
/// outlive the table it describes and quietly vouch for nothing.
pub fn checkBareKeyedTables(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var seen: std.StringHashMap(void) = .init(gpa);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit();
    }

    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const rel = try gpa.dupe(u8, entry.path);
        defer gpa.free(rel);
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{rel});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(contents);

        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (!bareKeyOn(line)) continue;
            const name = declaredName(line) orelse continue;

            const key = try std.fmt.allocPrint(gpa, "{s}|{s}", .{ rel, name });
            if (seen.contains(key)) {
                gpa.free(key);
            } else {
                try seen.put(key, {});
            }

            if (!isRegistered(rel, name)) {
                try appendViolation(gpa, violations, "src/{s}:{d}: `{s}` is keyed on a bare name (an integer or bytes), which carries no owner and no epoch. Add it to `registered` in tools/check/source_check/namespaces.zig with the two answers, or give the key a type that carries them.", .{ rel, line_no, name });
            }
        }
    }

    for (registered) |t| {
        const key = try std.fmt.allocPrint(gpa, "{s}|{s}", .{ t.file, t.name });
        defer gpa.free(key);
        if (!seen.contains(key)) {
            try appendViolation(gpa, violations, "tools/check/source_check/namespaces.zig: `registered` still lists `{s}` in src/{s}, which no longer declares a bare-keyed table of that name. Drop the entry, or fix the path.", .{ t.name, t.file });
        }
    }
}
