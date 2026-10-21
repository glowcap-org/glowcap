/**
 * The shipped recordings are teaching material: a reader learns what the
 * picture means from them, so each one has to be a recording the model
 * could actually have produced. A chapter whose session ends carry no
 * claim and no attribution teaches that a session normally looks like
 * that, and no real trace does.
 *
 * These are the facts a real `session-opened` always carries, held here
 * so a new chapter cannot ship without them.
 */

import { assert, assertEquals } from "@std/assert";
import { scenarios } from "./index.ts";
import {
	EndpointAttribution,
	endpointNodeId,
	endpointStageId,
	SESSION_SIDES,
	type SessionSide,
} from "../schema/session-end.ts";
import { observationsOf } from "../engine/temporal/recording-access.ts";
import type { TimelineEvent } from "../engine/timeline.ts";

/** An Ed25519 public key in canonical hex, how every key netlayer spells a
 *  designator (ADR-0028). */
const KEY_DESIGNATOR = /^[0-9a-f]{64}$/;

/** Every netlayer glowcap ships, with how it spells a designator. A claim that
 *  does not match its netlayer's spelling is a recording nothing could have
 *  produced, and a netlayer missing from this table fails the transport check
 *  below as unknown rather than being checked at all.
 *
 *  Which netlayers exist, and which of them name a peer by key, are Zig's:
 *  `driver_core.vocab.designatorSchemeForTransport` and each resident's own
 *  `designator_scheme` declaration, which `zig build source-check` already holds
 *  against each other. Nothing holds this copy against either, so a netlayer
 *  added there is added here by hand. */
const DESIGNATOR_SHAPE: Record<string, RegExp> = {
	// Address netlayers: the designator says where to dial.
	tcp: /^[0-9.]+:\d+$/,
	// Tor version 3 service id, without the `.onion` suffix.
	onion: /^[a-z2-7]{56}$/,
	// `inproc` dials a switchboard entry rather than a socket, so its
	// designator is the name a listener registered under.
	inproc: /^.+$/,
	// Key netlayers: the designator IS the peer's public key, and the keyed
	// handshake pins the session to it.
	"keyed-tcp": KEY_DESIGNATOR,
	"noise-tcp": KEY_DESIGNATOR,
	iroh: KEY_DESIGNATOR,
	webrtc: KEY_DESIGNATOR,
	"keyed-relay": KEY_DESIGNATOR,
	"noise-relay": KEY_DESIGNATOR,
};

function opensOf(doc: (typeof scenarios)[number]) {
	const out: Extract<TimelineEvent, { kind: "session-opened" }>[] = [];
	for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
		if (ev.kind === "session-opened") out.push(ev);
	}
	return out;
}

Deno.test("every shipped recording names the netlayer each session runs over", () => {
	for (const doc of scenarios) {
		for (const ev of opensOf(doc)) {
			assert(
				ev.transport !== undefined,
				`${doc.id}/${ev.sessionId}: no transport — one session runs over one netlayer, and a trace always knows which`,
			);
			assert(
				ev.transport in DESIGNATOR_SHAPE,
				`${doc.id}/${ev.sessionId}: unknown netlayer ${ev.transport}`,
			);
		}
	}
});

Deno.test("every session end says what it claims and what backed the claim", () => {
	for (const doc of scenarios) {
		for (const ev of opensOf(doc)) {
			const shape = DESIGNATOR_SHAPE[ev.transport!]!;
			for (const side of SESSION_SIDES) {
				const end = ev[side];
				// An end always has a claim: the reporting host either dialed
				// that designator or read it out of the partner's hello.
				assert(
					end.designator !== undefined,
					`${doc.id}/${ev.sessionId} end ${side}: no claim`,
				);
				assert(
					shape.test(end.designator),
					`${doc.id}/${ev.sessionId} end ${side}: ${end.designator} is not a ${ev.transport} designator`,
				);
				// The one-way invariant, on the authored side: an attached end
				// in a recording got attached by something, and the recording
				// says what.
				if (end.peer !== undefined) {
					assert(
						end.attributedBy !== undefined,
						`${doc.id}/${ev.sessionId} end ${side}: attached to ${end.peer} with nothing backing it`,
					);
				} else {
					assertEquals(
						end.attributedBy,
						undefined,
						`${doc.id}/${ev.sessionId} end ${side}: attributed to nobody`,
					);
				}
			}
			// A producer reporting a session is the thing doing the talking,
			// so one of the two ends is always its own report and no session
			// is loose at both ends.
			const selves = SESSION_SIDES.filter((s) => ev[s].attributedBy === "self-reported");
			assertEquals(
				selves.length,
				1,
				`${doc.id}/${ev.sessionId}: exactly one end is the reporting host's own`,
			);
		}
	}
});

Deno.test("an attached end names a peer the recording declares, by the designator it answers to", () => {
	for (const doc of scenarios) {
		const peers = doc.entities?.peers ?? {};
		for (const ev of opensOf(doc)) {
			for (const side of SESSION_SIDES) {
				const end = ev[side];
				if (end.peer === undefined) continue;
				const def = peers[end.peer];
				assert(def !== undefined, `${doc.id}: no peer ${end.peer}`);
				// `indexPeersByDesignator` matches a claim against a peer's
				// DESIGNATOR, never its id, so a peer with none can never be
				// what a claim names, on stage or in the layout.
				assertEquals(
					def.designator,
					end.designator,
					`${doc.id}/${ev.sessionId} end ${side}: the claim and the peer's own designator disagree`,
				);
			}
		}
	}
});

Deno.test("a peer is identified by the name it answers to on the wire", () => {
	// What `StageLedger` produces from a live feed, held for the authored
	// recordings too. `ensurePeer` takes the peer's durable wire name as its
	// key and mints the stage id from it, and the converter passes the
	// designator as that key. So in a real recording a peer's id IS its
	// designator, and `label` is display only, the friendly name a producer
	// asked to be shown instead of its key.
	//
	// Worth holding because the readable alternative is so tempting: ids like
	// "phone" and "client" read better in the source and are a shape no trace
	// can produce. A reader learning the picture from these recordings would
	// learn that a peer has a tidy name, and then meet their first real one.
	for (const doc of scenarios) {
		for (const [id, def] of Object.entries(doc.entities?.peers ?? {})) {
			assertEquals(
				id,
				def.designator,
				`${doc.id}: peer "${id}" is not identified by the designator it answers to`,
			);
			assert(
				def.label !== undefined && def.label !== id,
				`${doc.id}: peer "${id}" has no label of its own, so every surface would show its wire name`,
			);
		}
	}
});

Deno.test("a session is identified by its OCapN Session ID", () => {
	// 64 lowercase hex digits, the shape `session_id` carries on the wire and
	// the only name both ends of one session derive alike. It is what the live
	// converter builds its edges on, so an authored recording spells it the
	// same way.
	for (const doc of scenarios) {
		for (const id of Object.keys(doc.entities?.sessions ?? {})) {
			assert(
				KEY_DESIGNATOR.test(id),
				`${doc.id}: session "${id}" is not an OCapN Session ID`,
			);
		}
	}
});

Deno.test("between them the recordings show every attribution the schema declares", () => {
	// The chapters are what a reader learns the vocabulary from, so between them
	// they show all of it rather than one word over and over. Nothing here has
	// to check that each word IS in the schema: an end's `attributedBy` parsed
	// as an `EndpointAttribution` on the way in, so a word the schema does not
	// declare never reached a document.
	//
	// Both places a word can be said count. An end is attributed either at the
	// session's birth or at the moment something backed its claim, and one of status-allow: state at observation
	// the words is only ever said the second way: a handoff is verified partway
	// through a session that opened with a loose end, which is the whole shape
	// it describes.
	const seen = new Set<string>();
	for (const doc of scenarios) {
		for (const ev of opensOf(doc)) {
			for (const side of SESSION_SIDES) {
				const by = ev[side].attributedBy;
				if (by !== undefined) seen.add(by);
			}
		}
		for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
			if (ev.kind !== "session-endpoint-attributed") continue;
			if (ev.attributedBy !== undefined) seen.add(ev.attributedBy);
		}
	}
	assertEquals(
		[...seen].sort(),
		[...EndpointAttribution.options].sort(),
		"the shipped recordings do not show every attribution",
	);
});

Deno.test("no shipped message comes from a peer its session cannot name yet", () => {
	// A message rides one session, so the two things it can have come from are
	// the two ends of that session, and an end nobody has attributed is not a
	// peer. Naming one anyway is the recording claiming to know who sent
	// something at a moment when the wire did not, which is the same overreach
	// the endpoint vocabulary exists to refuse. It also shows: the stage draws
	// the message leaving the unattributed end, because that is where it
	// actually left from, while the Inspector reports the peer the recording
	// named. One picture, two answers.
	//
	// What a message may name is therefore the node each end SITS AT at the
	// moment it flies: the peer, once one is attached, and the end's own id
	// until then.
	for (const doc of scenarios) {
		// Where each side of each session sits, in the order the recording states
		// it: the open, then every attribution that moves an end onto a peer.
		const moves = new Map<string, { t: number; at: string }[]>();
		const note = (
			sessionId: string,
			side: SessionSide,
			t: number,
			at: string,
		) => {
			const key = endpointStageId(sessionId, side);
			const row = moves.get(key) ?? [];
			row.push({ t, at });
			moves.set(key, row);
		};
		for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
			if (ev.kind === "session-opened") {
				for (const side of SESSION_SIDES) {
					note(
						ev.sessionId,
						side,
						ev.t,
						endpointNodeId(ev.sessionId, side, ev[side]),
					);
				}
			} else if (ev.kind === "session-endpoint-attributed") {
				note(ev.sessionId, ev.side, ev.t, ev.peerId);
			}
		}
		const nodeAt = (sessionId: string, side: SessionSide, t: number) => {
			const row = moves.get(endpointStageId(sessionId, side)) ?? [];
			let at: string | undefined;
			for (const m of row) {
				if (m.t > t) break;
				at = m.at;
			}
			return at;
		};
		for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
			if (ev.kind !== "message-sent") continue;
			const ends = SESSION_SIDES.map((side) => nodeAt(ev.sessionId, side, ev.t));
			// A message on a session the recording never opened is a different
			// defect and not this check's business.
			if (ends.every((e) => e === undefined)) continue;
			for (const named of [ev.from, ev.to]) {
				assert(
					ends.includes(named),
					`${doc.id}/${ev.id} at t=${ev.t}: names "${named}", but its ` +
						`session's ends are ${JSON.stringify(ends)} at that moment`,
				);
			}
		}
	}
});
