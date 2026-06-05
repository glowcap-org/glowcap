# Examples port + inbound-`'fetch` serving — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the inbound-`'fetch` responder half in the Zig runtime and bring the Rust `docs/examples/` chapters over as runnable Zig programs, starting with the two (02, 08) that the responder unblocks.

**Architecture:** Mirror the canonical Rust substrate (Invariant 12): a session-owned `BootstrapTable` (swissnum→export) plus a runtime recognizer/synthesizer (`runtime/bootstrap.zig`) hooked into `Peer.dispatchOwnedFrameInner`. The responder synthesizes a semantic `Resolve`; the existing V1_0 outbound translation turns it into a resolver-callback on the wire automatically. Examples are runnable `examples/zig/NN_*.zig` programs with narrative in `//!` headers, run by `zig build examples`/`check`.

**Tech Stack:** Zig (build via `zig build`), pancake-zig core (`src/session`, `src/runtime`, `src/codec/syrup`), the spec gate `ADR-0006` (already amended to accept serving).

**Spec of record:** [`examples-and-inbound-fetch-serving.md`](examples-and-inbound-fetch-serving.md). **Decision:** [`../decisions/adr/ADR-0006-handshake-substrate-and-bootstrap-fetch.md`](../decisions/adr/ADR-0006-handshake-substrate-and-bootstrap-fetch.md).

**Repo note on commits:** git is read-only for agents in this repo. Each task's final step runs the gate (`zig build check`) as the checkpoint; the **user** commits. "Commit" steps below mean "ask the user to commit after the gate is green."

---

## Phase 1 — Inbound-`'fetch` serving + examples 01–02

### Task 1: Session `BootstrapTable`

**Files:**
- Modify: `src/session/mod.zig` (add `BootstrapTable` struct near `RefTable` ~line 200; add field to `Session` ~line 282; init lists ~line 322/338; `deinit` ~line 386; methods near `allocateExport` ~line 714)
- Test: `test/session/bootstrap_test.zig` (new) — register it in `test/all_test.zig`

- [ ] **Step 1: Write the failing test**

Create `test/session/bootstrap_test.zig`:

```zig
const std = @import("std");
const pancake = @import("pancake");
const session = pancake.session;

test "registerBootstrapCap maps a swissnum to a fresh export; lookup round-trips" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();

    const export_id = try s.registerBootstrapCap("thermostat");
    try std.testing.expect(s.hasExport(export_id));
    try std.testing.expectEqual(@as(?u64, export_id), s.bootstrapLookup("thermostat"));
    try std.testing.expectEqual(@as(?u64, null), s.bootstrapLookup("unknown"));
}

test "re-registering a swissnum replaces the export id" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();

    const first = try s.registerBootstrapCap("k");
    const second = try s.registerBootstrapCap("k");
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(?u64, second), s.bootstrapLookup("k"));
}
```

Add to `test/all_test.zig` (alongside the other session test imports):

```zig
test {
    _ = @import("session/bootstrap_test.zig");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `Session` has no `registerBootstrapCap` / `bootstrapLookup`.

- [ ] **Step 3: Add the `BootstrapTable` struct**

In `src/session/mod.zig`, after the `RefTable` struct (ends ~line 253), add:

```zig
/// Maps swiss-numbers to the local export id that serves them (ADR-0006
/// responder half). Owns each swissnum slice. The session is a passive table
/// owner — `lookup` is the only read; the runtime recognizes the inbound
/// `'fetch` shape and synthesizes the reply.
const BootstrapTable = struct {
    entries: std.ArrayList(Entry),

    const Entry = struct { swissnum: []u8, export_id: u64 };

    const empty: BootstrapTable = .{ .entries = .empty };

    fn deinit(self: *BootstrapTable, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.swissnum);
        self.entries.deinit(allocator);
    }

    fn register(self: *BootstrapTable, allocator: std.mem.Allocator, swissnum: []const u8, export_id: u64) !void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.swissnum, swissnum)) {
                entry.export_id = export_id;
                return;
            }
        }
        const owned = try allocator.dupe(u8, swissnum);
        errdefer allocator.free(owned);
        try self.entries.append(allocator, .{ .swissnum = owned, .export_id = export_id });
    }

    fn lookup(self: *const BootstrapTable, swissnum: []const u8) ?u64 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.swissnum, swissnum)) return entry.export_id;
        }
        return null;
    }
};
```

- [ ] **Step 4: Add the `bootstrap` field + init + deinit**

In the `Session` struct field list (after `pending_enlivens` ~line 307):

```zig
    /// Swissnum→export registry the inbound-`'fetch` responder consults (ADR-0006).
    bootstrap: BootstrapTable,
```

In `initWithAllocatorProfileAndFeatures`'s returned struct literal (~line 341, after `.pending_enlivens = .empty,`):

```zig
            .bootstrap = .empty,
```

In `deinit` (after the `pending_enlivens` cleanup ~line 388):

```zig
        self.bootstrap.deinit(self.allocator);
```

- [ ] **Step 5: Add the session methods**

After `allocateExport` (~line 714):

```zig
    /// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
    /// (ADR-0006 responder half): allocate a fresh export and map the swissnum to
    /// it. Returns the export id. Re-registering a swissnum replaces its mapping.
    pub fn registerBootstrapCap(self: *Session, swissnum: []const u8) !u64 {
        const export_id = try self.allocateExport();
        try self.bootstrap.register(self.allocator, swissnum, export_id);
        return export_id;
    }

    /// The local export serving `swissnum`, or null if none is registered.
    pub fn bootstrapLookup(self: *const Session, swissnum: []const u8) ?u64 {
        return self.bootstrap.lookup(swissnum);
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 7: Gate + commit (user)**

Run: `zig build check`
Expected: green (arch-check tolerates the new struct; it adds no new top-level module). Ask the user to commit: `feat(session): add BootstrapTable for inbound-'fetch serving`.

---

### Task 2: `runtime/bootstrap.zig` recognizer + synthesizer

**Files:**
- Create: `src/runtime/bootstrap.zig`
- Modify: `src/runtime/mod.zig:11` area (add `pub const bootstrap = @import("bootstrap.zig");`)
- Modify: `tools/arch_check.zig` if it requires an explicit rule for each `src/runtime/*.zig` (check; `fetch.zig`/`sturdyref.zig` precedent applies)
- Test: `test/runtime/bootstrap_test.zig` (new) — register in `test/all_test.zig`

- [ ] **Step 1: Write the failing test**

Create `test/runtime/bootstrap_test.zig`:

```zig
const std = @import("std");
const pancake = @import("pancake");
const runtime = pancake.runtime;
const codec = pancake.codec;
const model = pancake.model;

test "pendingBootstrapRequest matches a 'fetch deliver to export 0 with an answer" {
    // <op:deliver <desc:export 0> ['fetch "swiss"] 7> — built by encoding a model
    // deliver, then decoding the view (the shape the dispatcher sees).
    var s = model.... // see Step 3 note: construct via codec round-trip
    _ = s;
}
```

NOTE: building a `DeliverView` directly is awkward; the recognizer is exercised end-to-end in Task 3. For this unit test, assert the pure synthesizer instead:

```zig
test "resolveForSwissnum fulfills with the mapped export, breaks on a miss" {
    var sess = pancake.session.Session.init(std.testing.allocator);
    defer sess.deinit();
    const export_id = try sess.registerBootstrapCap("k");

    const hit = runtime.bootstrap.resolveForSwissnum(&sess, .{ .swissnum = "k", .answer = 7 });
    try std.testing.expectEqual(@as(u64, 7), hit.resolve.answer);
    try std.testing.expectEqual(model.NearRef.object(export_id), hit.resolve.resolution.fulfill.reference.near);

    const miss = runtime.bootstrap.resolveForSwissnum(&sess, .{ .swissnum = "nope", .answer = 9 });
    try std.testing.expectEqualStrings("unknown swissnum", miss.resolve.resolution.break_.message);
}
```

Add to `test/all_test.zig`:

```zig
test {
    _ = @import("runtime/bootstrap_test.zig");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — no `runtime.bootstrap`.

- [ ] **Step 3: Create `src/runtime/bootstrap.zig`**

```zig
//! Inbound bootstrap-`'fetch` responder primitives — the no-I/O half of
//! answering "give me the cap behind this swissnum" (ADR-0006 responder half).
//!
//! Two pure pieces, wired into `Peer.dispatchOwnedFrameInner`:
//!
//! 1. [`pendingBootstrapRequest`]: structurally recognize an inbound
//!    `op:deliver` to the bootstrap export (id 0) carrying `['fetch <swissnum>]`
//!    and a reply answer. Borrows the swissnum from the decoded view.
//! 2. [`resolveForSwissnum`]: synthesize the semantic `Resolve` — `Fulfill(Near
//!    <export>)` for a known swissnum, `Break("unknown swissnum")` for a miss.
//!    On Goblins V1.0 the outbound `step` translates this `Resolve` into a
//!    resolver-callback `op:deliver` automatically (`encodeResolverCallback`),
//!    so this half is profile-agnostic.

const std = @import("std");

const codec = @import("../codec/mod.zig");
const model = @import("../model/mod.zig");
const session_mod = @import("../session/mod.zig");

/// A recognized inbound bootstrap-fetch. `swissnum` borrows the inbound frame
/// (valid while the surfaced event owns it); `answer` is the partner's
/// answer-pos the synthesized `Resolve` keys on.
pub const Request = struct {
    swissnum: []const u8,
    answer: u64,
};

/// Recognize an inbound bootstrap-fetch `op:deliver`, or null if `deliver` is
/// not the canonical fetch shape (target export 0, args `['fetch <bytes>]`,
/// answer present). A malformed-looking fetch returns null — it falls through
/// to ordinary deliver handling rather than becoming a session refusal.
pub fn pendingBootstrapRequest(deliver: codec.syrup.DeliverView) codec.syrup.Error!?Request {
    const answer = deliver.answer orelse return null;
    if (referencePosition(deliver.target) != session_mod.BOOTSTRAP_EXPORT_ID) return null;
    if ((try deliver.args.count()) != 2) return null;

    // Syrup symbols project into `ArgumentView.bytes` (same as the resolver-
    // callback `'fulfill` / `'break` tags), so the method name is read as bytes.
    const method = switch (try deliver.args.at(0)) {
        .bytes => |bytes| bytes,
        else => return null,
    };
    if (!std.mem.eql(u8, method, "fetch")) return null;

    const swissnum = switch (try deliver.args.at(1)) {
        .bytes => |bytes| bytes,
        else => return null,
    };
    return .{ .swissnum = swissnum, .answer = answer };
}

/// Synthesize the semantic `Resolve` for `request`. Borrows nothing heap-owned:
/// `Fulfill` carries a POD `NearRef`; `Break` a static reason. The caller pushes
/// it with `Peer.sendCopying` (which clones), so the static reason is safe.
pub fn resolveForSwissnum(session: *const session_mod.Session, request: Request) model.Message {
    if (session.bootstrapLookup(request.swissnum)) |export_id| {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(export_id) } } },
        } };
    }
    return .{ .resolve = .{
        .answer = request.answer,
        .resolution = .{ .break_ = .{ .message = "unknown swissnum" } },
    } };
}

/// The export/import position a reference view names, or null for a promise.
/// Mirrors `runtime`'s view-side helper: an inbound deliver to our bootstrap
/// export decodes `<desc:export 0>` to `.near{export_id = 0}`.
fn referencePosition(reference: codec.syrup.ReferenceView) ?u64 {
    return switch (reference) {
        .near => |near| near.export_id,
        .far => |far| far.import_id,
        .promise => null,
    };
}
```

- [ ] **Step 4: Re-export from `src/runtime/mod.zig`**

After `pub const fetch = @import("fetch.zig");` (line 11):

```zig
pub const bootstrap = @import("bootstrap.zig");
```

- [ ] **Step 5: Check the arch gate**

Run: `zig build arch-check`
Expected: PASS. If it fails demanding a rule for `runtime/bootstrap.zig`, add a rule mirroring `runtime/fetch.zig`'s in `tools/arch_check.zig` (it may import `codec`, `model`, `session`).

- [ ] **Step 6: Run test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 7: Gate + commit (user)**

Run: `zig build check`
Ask the user to commit: `feat(runtime): add bootstrap-fetch recognizer + synthesizer`.

---

### Task 3: Dispatch hook + `Peer.registerBootstrapCap`

**Files:**
- Modify: `src/runtime/mod.zig` — add `Peer.registerBootstrapCap` (near `send`/`sendCopying` ~line 256); hook in `dispatchOwnedFrameInner` (~lines 691–738)
- Test: `test/runtime/bootstrap_test.zig` (extend) — an end-to-end auto-resolve

- [ ] **Step 1: Write the failing test (end-to-end auto-serve)**

Append to `test/runtime/bootstrap_test.zig`:

```zig
const foundation = pancake.foundation;

test "responder auto-resolves an inbound bootstrap fetch (no manual reply)" {
    var pair = try runtime.factories.paired(std.testing.allocator);
    defer pair.deinit();

    // p2 exposes a cap behind a swissnum.
    const export_id = try pair.p2.registerBootstrapCap("thermostat");

    // p1 fetches it.
    const prepared = try runtime.fetch.prepareFetchSwissnum(std.testing.allocator, &pair.p1.session_state, "thermostat");
    try pair.p1.send(prepared.message);
    _ = try pair.p1.step();

    // Shuttle the fetch deliver to p2 and let it dispatch (surfaces deliver
    // event) and then encode its synthesized resolve.
    {
        const frame = pair.p1.takeOutbound().?;
        try pair.p2.feedInbound(frame);
    }
    _ = try pair.p2.step(); // dispatch inbound: recognize + enqueue resolve
    {
        var ev = pair.p2.pollEvent().?; // the deliver event still surfaces
        defer ev.deinit();
        try std.testing.expectEqual(runtime.EventKind.deliver, ev.kind());
    }
    _ = try pair.p2.step(); // drain pending_send: encode the resolve (as a V1.0 resolver-callback)

    // Shuttle the settlement back to p1 and match it.
    {
        const frame = pair.p2.takeOutbound().?;
        try pair.p1.feedInbound(frame);
    }
    _ = try pair.p1.step();
    var settle = pair.p1.pollEvent().?;
    defer settle.deinit();
    const owned = try settle.decodeOwned(std.testing.allocator);
    var match = try runtime.fetch.tryMatchFetchOutcome(
        std.testing.allocator,
        prepared.resolver_export,
        prepared.answer_id,
        owned,
    );
    switch (match.settled) {
        .fulfilled => |ref| {
            defer model.freeReference(std.testing.allocator, ref);
            // p1 sees p2's Near(export_id) flipped to its own import.
            try std.testing.expectEqual(@as(u64, export_id), ref.far.import_id);
        },
        else => return error.TestUnexpectedResult,
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `Peer` has no `registerBootstrapCap`; the inbound fetch surfaces a deliver but no resolve is synthesized.

- [ ] **Step 3: Add `Peer.registerBootstrapCap`**

In `src/runtime/mod.zig` after `sendCopying` (~line 256):

```zig
    /// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
    /// (ADR-0006 responder half). Allocates a fresh export, maps the swissnum to
    /// it, and returns the export id. The adapter calls this at config time; an
    /// inbound `'fetch` for the swissnum is then served automatically by
    /// `dispatchOwnedFrameInner`.
    pub fn registerBootstrapCap(self: *Peer, swissnum: []const u8) !u64 {
        return self.session_state.registerBootstrapCap(swissnum);
    }
```

- [ ] **Step 4: Hook recognition into `dispatchOwnedFrameInner`**

In `dispatchOwnedFrameInner`, immediately after the pipelining branch (the `if (decoded_view == .deliver and try self.maybeEnqueuePipelinedCall(...))` block, ~line 694), insert:

```zig
        // An inbound `op:deliver` to our bootstrap export carrying `['fetch
        // <swissnum>]` is a bootstrap-fetch we answer automatically (ADR-0006
        // responder half). Recognized here (borrowing the frame the event will
        // own), the synthesized `Resolve` is enqueued after `recordRecv` below
        // so the inbound answer is installed first. The deliver still surfaces
        // as an event for observability.
        const bootstrap_request: ?bootstrap.Request = if (decoded_view == .deliver)
            try bootstrap.pendingBootstrapRequest(decoded_view.deliver)
        else
            null;
```

Then, at the very end of the function, after `appended = false;` (~line 738), add:

```zig

        if (bootstrap_request) |req| {
            try self.sendCopying(bootstrap.resolveForSwissnum(&self.session_state, req));
        }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Gate + commit (user)**

Run: `zig build check`
Ask the user to commit: `feat(runtime): serve inbound bootstrap-fetch automatically`.

---

### Task 4: Conformance scenario + de-manualize the round-trip tests

**Files:**
- Modify: `src/conformance/mod.zig` — add `runHandshakeThenBootstrapFetch`
- Modify: `test/conformance/parity_test.zig` — assert against a golden trace
- Create: `test/oracles/handshake_bootstrap_fetch.trace`
- Modify: `test/runtime/fetch_test.zig`, `test/runtime/sturdyref_test.zig` — drop the hand-rolled responder resolve, drive the auto-serve

- [ ] **Step 1: Add the scenario**

In `src/conformance/mod.zig`, after `runDrivenDeliverResolve` (~line 127):

```zig
/// Handshake → register a bootstrap cap on the responder → the initiator fetches
/// it → the responder AUTO-resolves (no hand-rolled reply). The exporter-side
/// proof for ADR-0006's responder half: serving an inbound `'fetch` is in the
/// runtime, not the test harness.
pub fn runHandshakeThenBootstrapFetch(allocator: std.mem.Allocator) ![]u8 {
    var pair = try runtime.factories.paired(allocator);
    defer pair.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "scenario=handshake_bootstrap_fetch\n");

    const export_id = try pair.p2.registerBootstrapCap("thermostat");
    try appendTraceLine(allocator, &out, "p2=registered:swissnum=thermostat:export={d}\n", .{export_id});

    const prepared = try runtime.fetch.prepareFetchSwissnum(allocator, &pair.p1.session_state, "thermostat");
    try pair.p1.send(prepared.message);
    _ = try pair.p1.step();
    try out.appendSlice(allocator, "p1=sent:fetch\n");

    {
        const frame = pair.p1.takeOutbound().?;
        try pair.p2.feedInbound(frame);
    }
    _ = try pair.p2.step();
    if (pair.p2.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        try appendTraceLine(allocator, &out, "p2=event:{s}\n", .{@tagName(event.kind())});
    }
    _ = try pair.p2.step();
    try out.appendSlice(allocator, "p2=auto:resolved\n");

    {
        const frame = pair.p2.takeOutbound().?;
        try pair.p1.feedInbound(frame);
    }
    _ = try pair.p1.step();
    {
        var settle = pair.p1.pollEvent().?;
        defer settle.deinit();
        const owned = try settle.decodeOwned(allocator);
        var match = try runtime.fetch.tryMatchFetchOutcome(allocator, prepared.resolver_export, prepared.answer_id, owned);
        switch (match.settled) {
            .fulfilled => |ref| {
                defer pancake_model.freeReference(allocator, ref);
                try appendTraceLine(allocator, &out, "p1=fulfilled:import={d}\n", .{ref.far.import_id});
            },
            .broken => |reason| {
                defer allocator.free(reason);
                try appendTraceLine(allocator, &out, "p1=broken:{s}\n", .{reason});
            },
            .malformed => try out.appendSlice(allocator, "p1=malformed\n"),
        }
    }
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}
```

Add the model import at the top of `src/conformance/mod.zig` if not present:

```zig
const pancake_model = @import("../model/mod.zig");
```

- [ ] **Step 2: Wire the golden trace assertion**

Inspect how `parity_test.zig` loads `test/oracles/stage0_abort.trace`, then add a parallel case calling `conformance.runHandshakeThenBootstrapFetch` and comparing to `test/oracles/handshake_bootstrap_fetch.trace`. Read `test/conformance/parity_test.zig` first to match its exact harness shape.

- [ ] **Step 3: Generate the golden trace**

Run a one-off to capture expected output (use a scratch test or temporarily print in `parity_test.zig`), then write the captured bytes to `test/oracles/handshake_bootstrap_fetch.trace`. Expected content shape:

```text
scenario=handshake_bootstrap_fetch
p2=registered:swissnum=thermostat:export=1
p1=sent:fetch
p2=event:deliver
p2=auto:resolved
p1=fulfilled:import=1

```

(`export=1` because export 0 is the bootstrap object; the first `allocateExport` after open returns 1. Confirm against the actual run and pin the real value.)

- [ ] **Step 4: De-manualize `fetch_test.zig` / `sturdyref_test.zig`**

Read `test/runtime/fetch_test.zig` (~lines 98–138) and `test/runtime/sturdyref_test.zig` (~lines 196–245). Replace the blocks where the "server" peer hand-rolls `sendCopying(.{ .resolve = … })` with `registerBootstrapCap` + letting `step` auto-serve (the Task 3 pattern). Keep each test's assertion on the initiator's matched outcome unchanged.

- [ ] **Step 5: Run tests + oracle**

Run: `zig build test && zig build oracle-check`
Expected: PASS, including the new parity case.

- [ ] **Step 6: Gate + commit (user)**

Run: `zig build check`
Ask the user to commit: `test(conformance): exercise inbound bootstrap-fetch auto-serve`.

---

### Task 5: Examples build harness + index

**Files:**
- Modify: `build.zig` (the examples wiring ~lines 57–88, 148–149)
- Create: `examples/README.md`

- [ ] **Step 1: Refactor the examples wiring to a list**

Replace the per-example module blocks (`zig_example_mod` … `examples_step` ~lines 57–88) with a loop that keeps the existing C example and adds the Zig chapter programs:

```zig
    const examples_step = b.step("examples", "Build and run examples");

    const zig_examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "pancake-zig-frame-view", .path = "examples/zig/frame_view.zig" },
        .{ .name = "pancake-ex-01-call-a-remote-method", .path = "examples/zig/01_call_a_remote_method.zig" },
        .{ .name = "pancake-ex-02-look-up-by-name", .path = "examples/zig/02_look_up_by_name.zig" },
    };
    for (zig_examples) |ex| {
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("pancake", lib_mod);
        const exe = b.addExecutable(.{ .name = ex.name, .root_module = mod });
        const run = b.addRunArtifact(exe);
        examples_step.dependOn(&run.step);
        check_step.dependOn(&run.step); // NOTE: declare check_step before this loop; see Step 2
    }

    const c_example_mod = b.createModule(.{ .target = target, .optimize = optimize });
    c_example_mod.addCSourceFile(.{ .file = b.path("examples/c/frame_view.c") });
    c_example_mod.addIncludePath(b.path("include"));
    c_example_mod.linkLibrary(static_lib);
    c_example_mod.link_libc = true;
    const c_frame_view_example = b.addExecutable(.{ .name = "pancake-c-frame-view", .root_module = c_example_mod });
    const run_c_frame_view_example = b.addRunArtifact(c_frame_view_example);
    examples_step.dependOn(&run_c_frame_view_example.step);
```

- [ ] **Step 2: Reorder `check_step` declaration**

`check_step` is currently declared near the end (~line 144). Move its declaration above the examples loop so the loop can `check_step.dependOn` each example run. Then in the final `check_step` block, replace the two `run_zig_frame_view_example` / `run_c_frame_view_example` dependencies with a single `examples_step` dependency:

```zig
    check_step.dependOn(&run_c_frame_view_example.step);
    // (the Zig chapter runs are added inside the loop above)
```

Confirm `frame_view.zig` still runs under `check` (it's first in the list).

- [ ] **Step 3: Write `examples/README.md`**

```markdown
# pancake by example (Zig)

Runnable CapTP/OCapN walkthroughs. Each program carries its narrative in a `//!`
header and runs under `zig build examples` (and `zig build check`), so the prose
and the API calls can't drift from each other.

| # | Program | What it does |
| --- | --- | --- |
| 01 | [`zig/01_call_a_remote_method.zig`](zig/01_call_a_remote_method.zig) | Pair two peers; one calls a method on the other and gets the result. |
| 02 | [`zig/02_look_up_by_name.zig`](zig/02_look_up_by_name.zig) | Fetch a capability through the bootstrap object using a swiss-number. |

Lower-level library mechanics:

- [`zig/frame_view.zig`](zig/frame_view.zig) — owned `Frame` → borrowed `FrameView`.
- [`c/frame_view.c`](c/frame_view.c) — the same over the C ABI.
```

- [ ] **Step 4: Gate**

Run: `zig build check`
Expected: PASS (no example programs referenced yet beyond frame_view; the array entries for 01/02 will fail to build until Tasks 6–7 create the files — so add the array entries for 01/02 in the SAME change as Tasks 6/7, or temporarily list only `frame_view` here and add 01/02 entries in their tasks). Prefer: add the `01`/`02` array entries in Tasks 6 and 7 respectively.

- [ ] **Step 5: Commit (user)**

Ask the user to commit: `build: drive Zig example chapters from a list + add index`.

---

### Task 6: Example 01 — Call a remote method

**Files:**
- Create: `examples/zig/01_call_a_remote_method.zig`
- Modify: `build.zig` (add the `01_…` entry to the `zig_examples` array if not already)

- [ ] **Step 1: Write the program**

```zig
//! 01 — Call a remote method.
//!
//! A phone calls `speaker.queue("Hot Knife")` on the kitchen speaker — the basic
//! CapTP pattern: invoke a method on a remote object and get the result back.
//!
//! `factories.paired` runs both `op:start-session` halves in-process; both
//! sessions return `open`. Production peers handshake over a netlayer. The pair
//! negotiates the Goblins V1.0 profile, so the runtime translates our semantic
//! `Resolve` into a resolver-callback `op:deliver` on the wire automatically —
//! the consumer just sends a `deliver` with an `answer` and reads the resolve.

const std = @import("std");
const pancake = @import("pancake");
const model = pancake.model;
const runtime = pancake.runtime;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pair = try runtime.factories.paired(allocator);
    defer pair.deinit();
    const phone = &pair.p1;
    const speaker = &pair.p2;

    // The speaker hosts an object at export id 1; the phone holds it as import 1.
    // (Chapter 02 derives this from a bootstrap fetch instead of pre-wiring it.)
    try speaker.session_state.registerExport(1);
    try phone.session_state.registerImport(1);

    // The phone calls queue("Hot Knife"), tagging the call answer 42.
    try phone.send(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{ .{ .symbol = "queue" }, .{ .bytes = "Hot Knife" } },
        .answer = 42,
    } });
    _ = try phone.step();
    {
        const frame = phone.takeOutbound().?;
        try speaker.feedInbound(frame);
    }
    _ = try speaker.step();
    {
        var deliver_event = speaker.pollEvent().?;
        defer deliver_event.deinit();
        std.debug.print("speaker received: {s}\n", .{@tagName(deliver_event.kind())});
    }

    // The speaker hands back a receipt: a fresh local export (id 5).
    try speaker.session_state.registerExport(5);
    try speaker.send(.{ .resolve = .{
        .answer = 42,
        .resolution = .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(5) } } },
    } });
    _ = try speaker.step(); // encode the resolve (V1.0 resolver-callback)
    {
        const frame = speaker.takeOutbound().?;
        try phone.feedInbound(frame);
    }
    _ = try phone.step();

    var resolved = phone.pollEvent().?;
    defer resolved.deinit();
    const view = try resolved.view();
    // The speaker sent Near(5) (its export); the phone sees Far(5) (its import).
    std.debug.print(
        "phone resolved answer={d} -> import {d}\n",
        .{ view.resolve.answer, view.resolve.resolution.fulfill.reference.far.import_id },
    );
}
```

- [ ] **Step 2: Add the build entry (if not added in Task 5)**

Ensure `build.zig`'s `zig_examples` array contains the `01_…` entry (Task 5 Step 1 shows it).

- [ ] **Step 3: Build and run; fix compiler/runtime errors**

Run: `zig build examples`
Expected: builds and prints the speaker-received + phone-resolved lines. If the compiler rejects a field/shape, correct against the actual `model`/`Event` API (this program uses only verified surfaces: `factories.paired`, `Peer.send/step/takeOutbound/feedInbound/pollEvent`, `Event.view`, `model.FarRef.object`, `model.NearRef.object`). Fix until green.

- [ ] **Step 4: Gate + commit (user)**

Run: `zig build check`
Ask the user to commit: `docs(examples): add chapter 01 (call a remote method)`.

---

### Task 7: Example 02 — Look up a service by name (uses the serving half)

**Files:**
- Create: `examples/zig/02_look_up_by_name.zig`
- Modify: `build.zig` (add the `02_…` entry)

- [ ] **Step 1: Write the program**

```zig
//! 02 — Look up a service by name.
//!
//! A client fetches a capability through the server's bootstrap object using a
//! swiss-number — the spec-shaped alternative to chapter 01's pre-wiring. The
//! server never writes a fetch handler: it registers `(swissnum → cap)` and the
//! runtime serves the inbound `'fetch` automatically (ADR-0006 responder half).

const std = @import("std");
const pancake = @import("pancake");
const model = pancake.model;
const runtime = pancake.runtime;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pair = try runtime.factories.paired(allocator);
    defer pair.deinit();
    const client = &pair.p1;
    const server = &pair.p2;

    // The server publishes a thermostat behind a swiss-number. That's the whole
    // server side — no handler, no dispatch loop.
    const swissnum = "thermostat-swiss";
    const cap_export = try server.registerBootstrapCap(swissnum);
    std.debug.print("server published swissnum -> export {d}\n", .{cap_export});

    // The client prepares a bootstrap fetch and drives the wire loop.
    const prepared = try runtime.fetch.prepareFetchSwissnum(allocator, &client.session_state, swissnum);
    try client.send(prepared.message);
    _ = try client.step();
    {
        const frame = client.takeOutbound().?;
        try server.feedInbound(frame);
    }
    _ = try server.step(); // recognize the fetch, surface the deliver, enqueue the resolve
    {
        var ev = server.pollEvent().?;
        ev.deinit();
    }
    _ = try server.step(); // encode the synthesized settlement
    {
        const frame = server.takeOutbound().?;
        try client.feedInbound(frame);
    }
    _ = try client.step();

    // Match the settlement into an owned outcome.
    var settle = client.pollEvent().?;
    defer settle.deinit();
    const owned = try settle.decodeOwned(allocator);
    var match = try runtime.fetch.tryMatchFetchOutcome(
        allocator,
        prepared.resolver_export,
        prepared.answer_id,
        owned,
    );
    switch (match.settled) {
        .fulfilled => |ref| {
            defer model.freeReference(allocator, ref);
            std.debug.print("client fetched the thermostat as import {d}\n", .{ref.far.import_id});
        },
        .broken => |reason| {
            defer allocator.free(reason);
            std.debug.print("fetch broke: {s}\n", .{reason});
        },
        .malformed => std.debug.print("fetch settlement was malformed\n", .{}),
    }
}
```

- [ ] **Step 2: Add the build entry**

Ensure `build.zig`'s `zig_examples` array contains the `02_…` entry.

- [ ] **Step 3: Build and run; fix errors**

Run: `zig build examples`
Expected: prints the published export and `client fetched the thermostat as import 1`. Fix any compiler/runtime mismatch against the verified APIs.

- [ ] **Step 4: Gate + commit (user)**

Run: `zig build check`
Ask the user to commit: `docs(examples): add chapter 02 (look up by name) over the new serving half`.

---

### Task 8: Update README "Not Implemented" + planning status

**Files:**
- Modify: `README.md` (~lines 117–129, "Not Implemented"; ~line 64–68 "Bootstrap fetch (initiator)" bullet; Examples section ~lines 190–196)
- Modify: `docs/planning/examples-and-inbound-fetch-serving.md` (status line)

- [ ] **Step 1: Edit README "Not Implemented"**

Remove "serving an inbound `'fetch`" from the not-implemented list and the sturdyref-enliven-serving sentence. Update the "Bootstrap fetch (initiator)" bullet to note the responder ships too. Add chapters 01–02 to the Examples section list.

- [ ] **Step 2: Edit the planning doc status**

Change `Status: planned.` to `Status: in flight — Phase 1 (serving half + examples 01–02) landed; examples 03–08 pending.`

- [ ] **Step 3: Gate + commit (user)**

Run: `zig build check`
Ask the user to commit: `docs: README + planning reflect inbound-fetch serving`.

---

## Phase 2 — Examples 03–08 (separate iteration)

These consume runtime modules not yet read line-by-line; each task must first read
the cited module, then follow the Task 6/7 pattern (write program → `zig build
examples` → fix → gate). They are independent and additive; ch 08 reuses the
Task 3 serving half.

- **03 — Pass a reference along:** an `Argument.reference` inside a `deliver`. Read: `src/model/mod.zig` (`Argument.reference`). No new runtime surface.
- **04 — Skip the round-trip:** pipeline a call against an unresolved answer. Read: `src/runtime/pipeline.zig`, `Session` inbound-answer/queue APIs.
- **05 — Do three things at once:** multi-hop pipeline decomposition. Read: `src/runtime/pipeline.zig` (`decomposeOutboundDeliver`), `model.PipelineOp`/`PipelinePath`.
- **06 — Poke me when it's ready:** `op:listen` + listener fire on resolve. Read: `maybeInstallInboundListener`, `fireListenersOnResolve`, `model.Listen`.
- **07 — Speak Goblins:** pin V1.0 / inspect `wire_profile`. Read: `runtime.factories.pairedWithOffers`, `model.WireProfile`, `negotiation`.
- **08 — Enliven a sturdyref:** initiator `runtime.sturdyref` + the Task 3 responder. Read: `src/runtime/sturdyref.zig` (`checkEnlivenPreconditions`, `prepareEnliven`, `recordEnlivenment`), `model.SturdyRef`.

Each: add its `examples/zig/NN_*.zig`, append to `build.zig`'s `zig_examples`, add a row to `examples/README.md`, gate, commit.

---

## Self-Review

- **Spec coverage:** ADR gate (done pre-plan); `BootstrapTable` (T1); recognizer/synthesizer (T2); dispatch hook + `registerBootstrapCap` (T3); conformance + de-manualize (T4); examples form/harness (T5); chapters 01/02 now + 03–08 staged (T6/7, Phase 2); README/planning (T8). Error handling (unknown swissnum → break; malformed → ordinary deliver) is in T2's `pendingBootstrapRequest`/`resolveForSwissnum`. No-cap rationale lives in the spec/ADR.
- **Type consistency:** `Request{ swissnum, answer }`, `resolveForSwissnum(*const Session, Request) model.Message`, `pendingBootstrapRequest(DeliverView) !?Request`, `Peer.registerBootstrapCap([]const u8) !u64`, `Session.registerBootstrapCap`/`bootstrapLookup` — used identically across T1–T7.
- **Placeholders:** the one soft spot is T4 Step 2/3 and Phase 2 (read-then-write), kept explicit because the exact `parity_test.zig` harness and the 03–08 modules must be read before their code is honest — flagged, not hidden.
