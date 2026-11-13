// Reading the timeline events ocapnviz's converter produces, and the property
// a stretch of them keeps.

import { fail } from "../support/fail.ts";

/** One event the converter produces. An open record: nothing here states its
 * structure, and it is read only through the accessors below, against
 * ocapnviz's own schema. */
export type StageEvent = Record<string, unknown>;

/** A string field of a converted event, or undefined when it carries none. */
export function str(ev: StageEvent, field: string): string | undefined {
	const value = ev[field];
	return typeof value === "string" ? value : undefined;
}

/** The peer one end of a `session-opened` attached to, or null when that end is
 * loose: a claim nothing has backed yet, drawn as a session end with no peer.
 * An accepting side reports a session before anything proves who dialed, so
 * this is the ordinary state of a fresh end rather than an error. */
export function endpointPeer(ev: StageEvent, side: "a" | "b"): string | null {
	const end = ev[side];
	if (typeof end === "string") return end;
	if (end !== null && typeof end === "object" && "peer" in end && typeof end.peer === "string") return end.peer;
	return null;
}

/** The property the lifecycle proof rests on: a stretch of timeline may not
 * state a departure or a close the protocol never produced.
 *
 * A viewer learns who is on the far end of a wire AFTER it has drawn the wire,
 * a browser tab dials with no address to prove, so the accepting end reports
 * the session before anyone can say whose it is. Learning that is a fact about
 * the viewer. Reporting it as `session-closed` and `peer-left` makes it a claim
 * about the network, and the network did no such thing: one session opened and
 * stayed open.
 *
 * So: of everything that opened while this slice was recorded, nothing closed
 * inside it, and nobody who appeared on one of those sessions left inside it. */
export function statesOnlyWhatHappened(since: StageEvent[], what: string): void {
	const opened = new Set<string>();
	const appeared = new Set<string>();
	for (const ev of since) {
		if (str(ev, "kind") !== "session-opened") continue;
		opened.add(str(ev, "sessionId") ?? "");
		for (const side of ["a", "b"] as const) {
			const peer = endpointPeer(ev, side);
			if (peer !== null) appeared.add(peer);
		}
	}
	// An end attributed inside this slice is a peer that appeared on one of
	// these sessions just as surely as one named at the open, and it must not
	// then be reported as having left.
	for (const ev of since) {
		if (str(ev, "kind") !== "session-endpoint-attributed") continue;
		if (!opened.has(str(ev, "sessionId") ?? "")) continue;
		appeared.add(str(ev, "peerId") ?? "");
	}
	const closed = since
		.filter((e) =>
			(str(e, "kind") === "session-closed" || str(e, "kind") === "session-unobserved") &&
			opened.has(str(e, "sessionId") ?? "")
		)
		.map((e) => str(e, "sessionId"));
	if (closed.length > 0) {
		fail(
			`${what}, but the timeline closed ${closed.join(", ")} — a session that opened and never ended`,
		);
	}
	const left = since
		.filter((e) =>
			(str(e, "kind") === "peer-left" || str(e, "kind") === "peer-unobserved") &&
			appeared.has(str(e, "peerId") ?? "")
		)
		.map((e) => str(e, "peerId"));
	if (left.length > 0) {
		fail(`${what}, but the timeline said ${left.join(", ")} left — a peer that never departed`);
	}
}
