/**
 * What the world holds at a moment is a function of the document alone, and
 * how the materializer reaches each range (once per session, derived for its
 * messages) is not part of that answer. The document exercises every way a
 * range depends on another: a session clamped by a peer that leaves, an end
 * that stays loose until it is attributed, a session that closes, a session
 * with no end, a session that opens and closes at one moment, and a message
 * whose session is clamped, zero-length, or undeclared. The expected picture
 * is computed from the resolvers that answer one entity at a time.
 */

import { assert, assertEquals } from "@std/assert";
import { attachedEndpoint, sessionEndpoint } from "../../schema/session-end.ts";
import { projectFromObservations } from "../temporal/project-from-observations.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { containsTime } from "../temporal/range.ts";
import { messageEffective, peerEffective, sessionEffective } from "../temporal/doc-resolver.ts";
import { createWorld } from "../world.ts";
import { materializeWorldAt } from "./world-materializer.ts";

function fixture(): TimelineDocument {
	const events: TimelineEvent[] = [
		{ id: "e1", kind: "peer-joined", t: 0, peerId: "alice", profile: "glowcap", label: "alice" },
		{ id: "e2", kind: "peer-joined", t: 10, peerId: "bob", profile: "glowcap", label: "bob" },
		{ id: "e3", kind: "peer-joined", t: 20, peerId: "carol", profile: "glowcap", label: "carol" },
		{ id: "e4", kind: "peer-left", t: 50, peerId: "carol" },
		{
			id: "e5",
			kind: "session-opened",
			t: 15,
			sessionId: "ab",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			codec: "syrup",
			captpVersion: "v1_0",
		},
		{ id: "e6", kind: "session-closed", t: 70, sessionId: "ab" },
		{
			id: "e7",
			kind: "session-opened",
			t: 25,
			sessionId: "ac",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("carol"),
			codec: "syrup",
			captpVersion: "v1_0",
		},
		{
			id: "e8",
			kind: "session-opened",
			t: 30,
			sessionId: "loose",
			a: attachedEndpoint("bob"),
			b: sessionEndpoint({ designator: "alice" }),
			codec: "syrup",
			captpVersion: "v1_0",
		},
		{
			id: "e9",
			kind: "session-endpoint-attributed",
			t: 60,
			sessionId: "loose",
			side: "b",
			peerId: "alice",
			attributedBy: "verified-handoff",
		},
		{
			id: "m1",
			kind: "message-sent",
			t: 16,
			messageId: "m1",
			sessionId: "ab",
			from: "alice",
			to: "bob",
			arrivalT: 40,
		},
		{
			id: "m2",
			kind: "message-sent",
			t: 45,
			messageId: "m2",
			sessionId: "ac",
			from: "alice",
			to: "carol",
			arrivalT: 90,
		},
		{
			id: "m3",
			kind: "message-sent",
			t: 65,
			messageId: "m3",
			sessionId: "ab",
			from: "bob",
			to: "alice",
			arrivalT: 100,
		},
		{
			id: "m4",
			kind: "message-sent",
			t: 35,
			messageId: "m4",
			sessionId: "loose",
			from: "bob",
			to: "alice",
			arrivalT: 80,
		},
		{
			id: "z1",
			kind: "session-opened",
			t: 55,
			sessionId: "zero",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			codec: "syrup",
			captpVersion: "v1_0",
		},
		{ id: "z2", kind: "session-closed", t: 55, sessionId: "zero" },
		{
			id: "m6",
			kind: "message-sent",
			t: 55,
			messageId: "m6",
			sessionId: "zero",
			from: "alice",
			to: "bob",
			arrivalT: 58,
		},
		{
			id: "m5",
			kind: "message-sent",
			t: 40,
			messageId: "m5",
			sessionId: "nowhere",
			from: "bob",
			to: "alice",
			arrivalT: 55,
		},
	];
	return projectFromObservations({
		id: "ranges",
		duration: 120,
		rowOrder: {},
		rowHidden: {},
		rowLabelHidden: {},
		rowBodyHidden: {},
		entities: {},
		recording: { sources: [{ id: "fixture", meta: { kind: "fixture" }, observations: events }] },
	});
}

/** One line per thing on stage, in a stable order. */
function picture(doc: TimelineDocument, t: number, world = createWorld()): string[] {
	materializeWorldAt(world, doc, t);
	const lines: string[] = [];
	for (const e of world.with("peer")) lines.push(`peer ${e.peer.id}`);
	for (const e of world.with("endpoint")) lines.push(`end ${e.endpoint.id}`);
	for (const e of world.with("session", "endpoints")) {
		lines.push(`session ${e.session.id} ${e.session.state} ${e.endpoints.a}>${e.endpoints.b}`);
	}
	for (const e of world.with("messageInFlight")) {
		const m = e.messageInFlight;
		lines.push(`message ${m.id} ${m.sentT}-${m.arrivalT}`);
	}
	return lines.sort();
}

const TIMES = [0, 12, 18, 22, 28, 32, 42, 48, 52, 55, 57, 62, 68, 75, 95, 120];

Deno.test("the world at a moment is the same arriving fresh or by reconciling", () => {
	const doc = fixture();
	const held = createWorld();
	for (const t of TIMES) {
		assertEquals(picture(doc, t, held), picture(doc, t), `t=${t}`);
	}
	for (const t of [...TIMES].reverse()) {
		assertEquals(picture(doc, t, held), picture(doc, t), `t=${t} backwards`);
	}
});

/** The picture the per-entity resolvers give: a peer, session, or message is
 *  on stage when its own effective range holds `t`. */
function expectedAt(doc: TimelineDocument, t: number): string[] {
	const lines: string[] = [];
	for (const id of Object.keys(doc.entities?.peers ?? {})) {
		if (containsTime(peerEffective(doc, id), t)) lines.push(`peer ${id}`);
	}
	for (const id of Object.keys(doc.entities?.sessions ?? {})) {
		if (containsTime(sessionEffective(doc, id), t)) lines.push(`session ${id}`);
	}
	for (const id of Object.keys(doc.entities?.messages ?? {})) {
		const eff = messageEffective(doc, id);
		if (containsTime(eff, t)) lines.push(`message ${id} ${eff.start}-${eff.end}`);
	}
	return lines.sort();
}

/** What the world holds of those three kinds, in the same words. */
function heldAt(doc: TimelineDocument, t: number): string[] {
	return picture(doc, t)
		.filter((line) => /^(peer|session|message) /.test(line))
		.map((line) => line.startsWith("session ") ? line.split(" ").slice(0, 2).join(" ") : line)
		.sort();
}

Deno.test("the world at a moment holds what each entity's own range says it holds", () => {
	const doc = fixture();
	let sessionsSeen = 0;
	let messagesSeen = 0;
	for (const t of TIMES) {
		const expected = expectedAt(doc, t);
		assertEquals(heldAt(doc, t), expected, `t=${t}`);
		sessionsSeen += expected.filter((line) => line.startsWith("session ")).length;
		messagesSeen += expected.filter((line) => line.startsWith("message ")).length;
	}
	// Both arms ran: the comparison was not between two empty pictures.
	assert(sessionsSeen > 0 && messagesSeen > 0);
});
