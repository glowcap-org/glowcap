// Stage ledger: incarnations, refcounted leaves, and epochs.

import { assertEquals } from "@std/assert";
import { makeBaseEventConverter } from "../feed.ts";
import { closeSession, expectKind, openSession } from "./harness.ts";

Deno.test("session-closed retires the partner but keeps the reporting host", () => {
	const convert = makeBaseEventConverter();
	openSession(convert, "s1", "bob", 0);
	const out = closeSession(convert, "s1", 10_000_000);
	assertEquals(out.length, 2);
	expectKind(out[0], "session-closed");
	const left = expectKind(out[1], "peer-left");
	assertEquals(left.peerId, "bob");
	// The reporting host (`a`) outlives its sessions: no leave for it.
});

Deno.test("a peer with two live sessions survives one closing", () => {
	// Reconnect overlap: the same identity opens a second session
	// before the first one's close lands. The old close must not status-allow: replacement state identity
	// retire the peer while the new session still references it.
	const convert = makeBaseEventConverter();
	openSession(convert, "s1", "bob", 0);
	openSession(convert, "s2", "bob", 1_000_000);
	const firstClose = closeSession(convert, "s1", 2_000_000);
	assertEquals(firstClose.length, 1); // session-closed only, no peer-left
	expectKind(firstClose[0], "session-closed");
	const lastClose = closeSession(convert, "s2", 3_000_000);
	assertEquals(lastClose.length, 2);
	expectKind(lastClose[0], "session-closed");
	assertEquals(expectKind(lastClose[1], "peer-left").peerId, "bob");
});

Deno.test("a returning peer gets a fresh incarnation id, same label", () => {
	// The timeline's entity model gives each id ONE lifetime, so a
	// wire name that returns after leaving renders as a new stage
	// entity. The label stays the wire name.
	const convert = makeBaseEventConverter();
	openSession(convert, "s1", "bob", 0);
	closeSession(convert, "s1", 10_000_000);
	const again = openSession(convert, "s2", "bob", 20_000_000);
	const rejoined = expectKind(again[0], "peer-joined");
	assertEquals(rejoined.peerId, "bob#2");
	assertEquals(rejoined.label, "bob");
	const session = expectKind(again[1], "session-opened");
	assertEquals(session.b.peer, "bob#2");
});

Deno.test("a reused wire session id gets a fresh stage session id", () => {
	const convert = makeBaseEventConverter();
	openSession(convert, "s1", "bob", 0);
	closeSession(convert, "s1", 10_000_000);
	const again = openSession(convert, "s1", "carol", 20_000_000);
	const session = expectKind(again[1], "session-opened");
	assertEquals(session.sessionId, "s1#2");
});

Deno.test("messages route to the current session incarnation", () => {
	const convert = makeBaseEventConverter();
	openSession(convert, "s1", "bob", 0);
	closeSession(convert, "s1", 10_000_000);
	openSession(convert, "s1", "carol", 20_000_000);
	const out = convert({
		v: 1,
		sim_t_ns: 21_000_000,
		kind: "ocapn.message-decoded",
		session: "s1",
		outbound: true,
		op: "op:deliver",
	});
	assertEquals(out.length, 1);
	const msg = expectKind(out[0], "message-sent");
	assertEquals(msg.sessionId, "s1#2");
	assertEquals(msg.from, "rooms");
	assertEquals(msg.to, "carol"); // first incarnation keeps the bare name
});

Deno.test("an epoch change retires the dead process's topology", () => {
	// A restarted producer restarts its seq and may reuse session
	// ids. Its old topology goes out of view; the converter ends
	// everything from the previous epoch, then the new process's
	// events build fresh incarnations.
	//
	// Out of VIEW, not closed. Some of what the dead process was
	// showing died with it and some did not, two browser tabs talking
	// directly kept going, and from here those are indistinguishable.
	// So the timeline says the one thing true of both.
	const convert = makeBaseEventConverter();
	convert({
		v: 1,
		sim_t_ns: 0,
		epoch: 111,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "s1",
		a: "rooms",
		b: "bob",
		codec: "syrup",
	});
	const out = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		epoch: 222,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "s1",
		a: "rooms",
		b: "bob",
		codec: "syrup",
	});
	// Old epoch retired: the session and both peers go out of view,
	// then the new epoch's joins + open with fresh incarnations.
	const kinds = out.map((e) => e.kind);
	assertEquals(kinds, [
		"session-unobserved",
		"peer-unobserved",
		"peer-unobserved",
		"peer-joined",
		"peer-joined",
		"session-opened",
	]);
	// And nothing claimed the network did anything.
	assertEquals(
		out.filter((e) => e.kind === "session-closed" || e.kind === "peer-left")
			.length,
		0,
		"a feed restarting is not a teardown anyone observed",
	);
	const session = expectKind(out[5], "session-opened");
	assertEquals(session.sessionId, "s1#2");
	assertEquals(session.a.peer, "rooms#2");
	assertEquals(session.b.peer, "bob#2");
});

Deno.test("session-opened arrives on stage already open", () => {
	// The trace reports a session only after its handshake, so the
	// stage must not show "negotiating" for its whole life.
	const convert = makeBaseEventConverter();
	const out = openSession(convert, "s1", "bob", 0);
	const session = expectKind(out[2], "session-opened");
	assertEquals(session.initialState, "open");
});
