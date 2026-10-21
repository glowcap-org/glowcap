/**
 * Live wire record. One JSON object on the trace feed, and the field
 * readers that prove a value is a string, a finite number, or a codec
 * word. `feed.ts` owns the epoch/replay envelope,
 * `apply.ts` owns one record's effect on the stage.
 */

import { type Codec, UNKNOWN_CODEC } from "../../schema/topology.ts";

/**
 * One timeline event from the wire, generic base or any extension.
 * Fields that vary by `kind` are kept loose. The converter narrows.
 */
export type BaseTimelineEvent = {
	v: unknown;
	sim_t_ns: unknown;
	kind: unknown;
	/** Producer-stamped monotone sequence number. A producer that
	 * replays a ring of recent events to a (re)connecting viewer
	 * stamps every line, so the client drops what it already
	 * applied instead of duplicating entities on reconnect. Absent
	 * on producers without replay. */
	seq?: unknown;
	/** Producer process instance. A restarted producer starts a new
	 * epoch: its `seq` resets (so the seq dedup window resets with
	 * it) and its session ids may collide with the dead process's.
	 * The converter closes every entity of the previous epoch when
	 * the epoch changes. The old process's topology is gone. status-allow: replacement state identity
	 * Absent on producers without replay/restart concerns. */
	epoch?: unknown;
	/** `trace.producer-left` only: the departed producer's scope. Endpoint-authored,
	 * `trace.` marks a fact about the stream rather than about the protocol. */
	scope?: unknown;
	/** True on lines a producer replayed to a (re)connecting viewer.
	 * Replay is STATE, not events: replayed session opens/closes
	 * materialize the topology this viewer needs, while replayed
	 * messages are the past. They happened before this viewer
	 * watched, so they stay out of its capture.
	 *
	 * A replayed line waits in the converter until the endpoint marks
	 * the end of the batch (`trace.replay-end`), because the batch is
	 * one picture rather than a sequence of moments: both ends of a
	 * wire are in it before anything is drawn, so the viewer never had
	 * to learn who was on either. */
	replay?: boolean;
	a?: unknown;
	b?: unknown;
	src?: unknown;
	dst?: unknown;
	/** `ocapn.message-decoded`: departure time of the message in
	 * nanoseconds, present when the producer could observe both ends of
	 * the link. The renderer animates the message traveling from
	 * `depart_ns` to `sim_t_ns`. */
	depart_ns?: unknown;
	arrive_ns?: unknown;
	delivered_ns?: unknown;
	bytes_b64?: unknown;
	summary?: { len?: unknown; head_b64?: unknown };
	// OCapN extractor extension fields:
	/** The producer's own handle for the session, scoped by the endpoint to
	 * the producer that sent it. Not the OCapN Session ID: that is
	 * `session_id` below, which both ends of one session derive alike and
	 * which is therefore the only one that can merge two producers' views. */
	session?: unknown;
	/** `ocapn.session-opened`: the negotiated codec word. The feed is JSON, so
	 * this reaches the reader as unknown until the reader proves it is a string. */
	codec?: unknown;
	op?: unknown;
	len?: unknown;
	/** `ocapn.message-decoded` from a live host tap: which side of the session
	 * sent it. The producer names only its session. This converter resolves
	 * src/dst from the `ocapn.session-opened` it already saw. */
	outbound?: boolean;
	/** `ocapn.session-opened`: what proved `b`'s durable name, in the words
	 * `DurableProvenance` lists. Three answers rather than a yes/no: a partner
	 * that claimed no durable name and one whose claim nothing on its path could
	 * prove are different facts, and only the second is a gap.
	 *
	 * A string rather than that type because this is the wire, where a producer
	 * may send anything, `attributionForProvenance` is the one place a verdict
	 * is read. */
	provenance?: unknown;
	/** `ocapn.session-opened`: the OCapN Transport of `b`'s locator, the
	 * netlayer symbol this session runs over. A designator does not name a
	 * location on its own. The spec requires the transport beside it, so
	 * every `ocapn.session-opened` carries one. */
	transport?: unknown;
	/** `ocapn.session-opened`: the OCapN **Session ID**, 64 lowercase hex
	 * digits. Both peers of one session derive the same value from their two
	 * public identifiers, with the pair sorted, so it is the same string in
	 * both ends' reports and neither had to be told it. It is what tells one
	 * conversation watched twice from two unrelated ones, and so it is the
	 * name this converter builds its edges on. Absent when the partner sent
	 * no session key. */
	session_id?: unknown;
	/** `ocapn.session-opened`: what the reporting host would like itself
	 * called on screen. A chat server saying "rooms" rather than showing its
	 * 64-digit key designator. Display only: `a` remains the identity every
	 * merge decision is made on, and this text, which the producer chose,
	 * reaches none of them. */
	a_label?: unknown;
	/** `ocapn.session-opened`: what the reporting host says it RUNS, in the
	 * words `PROFILE_OPTIONS` lists. A statement about the producer, standing
	 * beside `a` (the name it calls itself by) and `a_label` (what it would
	 * like to be called), and the only thing that names its own end.
	 *
	 * The `ocapn.*` kinds are a schema rather than one implementation's mark:
	 * the Goblins conformance peer publishes them too. So a producer that
	 * states nothing leaves its end unknown instead of being taken for
	 * something. Open-ended, like the `PeerProfile` it becomes, OCapN is
	 * implementation-plural, so a producer may name an implementation this
	 * build has never heard of and the stage draws it under that name. */
	a_profile?: unknown;
	/** `ocapn.session-opened`: the negotiated CapTP profile, spelled the way
	 * the handshake spells it (`"1.0"` / `"glowcap-next"`), because a trace
	 * reports on the wire. The feed is JSON, so this reaches the reader as
	 * unknown until the reader proves it is a string. Required on every
	 * `ocapn.session-opened`. */
	captp_version?: unknown;
	/** `ocapn.message-decoded`: a tag over the frame's own bytes, which
	 * both ends of the wire derive alike. Two producers watching one
	 * session each report every message, and this is what folds their
	 * two sightings into one on stage. */
	digest?: unknown;
	/** `ocapn.session-meta`: an application annotation about the
	 * session. A claim by the producing application, never protocol
	 * identity. `label` names the session's partner in the
	 * application's own vocabulary (a chat nick), `null` WITHDRAWS the
	 * claim, so the peer answers again to the name underneath. */
	meta?: { label?: unknown };
};

export function codecFromWire(codec: unknown): Codec {
	if (typeof codec !== "string") return UNKNOWN_CODEC;
	return codec.length > 0 ? codec : UNKNOWN_CODEC;
}

export function stringFromWire(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

export function nonEmptyStringFromWire(value: unknown): string | undefined {
	const text = stringFromWire(value);
	return text != null && text.length > 0 ? text : undefined;
}

/** Finite numbers from a wire field. Missing, non-numeric, and non-finite
 *  values are absence. */
export function numberFromWire(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
