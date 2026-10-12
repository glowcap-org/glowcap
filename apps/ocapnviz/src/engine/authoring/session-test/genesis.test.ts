/**
 * The endpoint a session is born with, and the open that can draw an
 * end nothing has attributed, including a host that dials itself.
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../../engine.ts";
import { attachedEndpoint, sessionEndpoint } from "../../../schema/session-end.ts";
import { buildDoc, engineTest, looseDoc, observations, sessionOf } from "./harness.ts";

// ── the endpoint a session is born with ───────────────────────────

engineTest("open-session can draw an end nothing has attributed", () => {
	const e = new Engine(buildDoc());
	const sid = e.dispatch({
		kind: "open-session",
		a: attachedEndpoint("a"),
		b: sessionEndpoint({ designator: "127.0.0.1:9000" }),
	});
	assert(sid !== undefined, "the session was not drawn");
	const def = sessionOf(e, sid);
	assertEquals(def.a.peer, "a");
	assertEquals(def.b.peer, undefined, "the end came out attached");
	assertEquals(def.b.designator, "127.0.0.1:9000");
});

engineTest("detaching an end takes its attribution with it", () => {
	// Nothing can attribute an end to nobody, so the invariant is held
	// in both directions: a detach clears what attributed the end
	// rather than leaving a claim of proof behind with no peer.
	const e = new Engine(looseDoc());
	e.updateSessionEndpoint("s1", "a", { peer: null });
	const end = sessionOf(e).a;
	assertEquals(end.peer, undefined);
	assertEquals(end.attributedBy, undefined);
});

engineTest("attaching a loose end names the peer", () => {
	const e = new Engine(looseDoc());
	e.updateSessionEndpoint("s1", "b", { peer: "b" });
	assertEquals(sessionOf(e).b.peer, "b");
	// The claim is what the end SAID; attaching it does not rewrite
	// that, because the two are different facts.
	assertEquals(sessionOf(e).b.designator, "127.0.0.1:9000");
});

engineTest("an end cannot be attached to a peer the document lacks", () => {
	const e = new Engine(looseDoc());
	e.updateSessionEndpoint("s1", "b", { peer: "nobody" });
	assertEquals(sessionOf(e).b.peer, undefined);
});

engineTest("nothing can attribute an end to nobody", () => {
	const e = new Engine(looseDoc());
	e.updateSessionEndpoint("s1", "b", {
		attributedBy: "authenticated-transport",
	});
	assertEquals(
		sessionOf(e).b.attributedBy,
		undefined,
		"a loose end was given something that attributed it",
	);
});

engineTest("attributing an attached end records what backed it", () => {
	const e = new Engine(looseDoc());
	e.updateSessionEndpoint("s1", "b", { peer: "b" });
	e.updateSessionEndpoint("s1", "b", {
		attributedBy: "verified-handoff",
	});
	assertEquals(sessionOf(e).b.attributedBy, "verified-handoff");
});

engineTest("an end's claim is editable, and an empty claim is none", () => {
	const e = new Engine(looseDoc());
	e.updateSessionEndpoint("s1", "b", { designator: "10.0.0.2:7" });
	assertEquals(sessionOf(e).b.designator, "10.0.0.2:7");
	e.updateSessionEndpoint("s1", "b", { designator: "" });
	assertEquals(sessionOf(e).b.designator, undefined);
});

engineTest("an endpoint edit mirrors onto the opening observation", () => {
	// The definition is the authority, and the recording says what the
	// definition says. The same pairing a peer's identity edit keeps
	// with its join.
	const e = new Engine(looseDoc());
	e.updateSessionEndpoint("s1", "b", { peer: "b" });
	const opened = observations(e).find((ev) => ev.kind === "session-opened");
	assert(opened !== undefined && opened.kind === "session-opened");
	assertEquals(opened.b.peer, "b");
});

engineTest("dispatch routes update-session-endpoint, and guards it", () => {
	const e = new Engine(looseDoc());
	e.dispatch({
		kind: "update-session-endpoint",
		sessionId: "s1",
		side: "b",
		patch: { peer: "b" },
	});
	assertEquals(sessionOf(e).b.peer, "b");
	const v0 = e.version;
	e.dispatch({
		kind: "update-session-endpoint",
		sessionId: "s1",
		side: "b",
		patch: { peer: "b" },
	});
	assertEquals(e.version, v0, "an unchanged endpoint edit still dispatched");
	// Clearing a field that is already absent is equally a no-op.
	e.dispatch({
		kind: "update-session-endpoint",
		sessionId: "s1",
		side: "b",
		patch: { attributedBy: null },
	});
	assertEquals(e.version, v0);
});

engineTest("a session may have one peer on both of its ends", () => {
	const e = new Engine(buildDoc());
	// A host that dials itself reports exactly this, and
	// `updateSessionEndpoint` writes it after the fact. So the creation
	// door refusing it, in silence, was the one place the answer differed.
	const sessionId = e.dispatch({
		kind: "open-session",
		a: attachedEndpoint("a"),
		b: attachedEndpoint("a"),
	});
	assert(
		typeof sessionId === "string",
		"open-session refused a peer on both ends",
	);
	const def = sessionOf(e, sessionId);
	assertEquals(def.a.peer, "a");
	assertEquals(def.b.peer, "a");
});
