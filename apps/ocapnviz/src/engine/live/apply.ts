/**
 * One live record's effect on the stage. `feed.ts` owns the
 * envelope, epoch changes and the replay batch, and calls here
 * once a record is ready to draw. The batch flush calls straight
 * in, so a replayed record cannot re-enter the buffer it is being
 * drained from.
 */

import { captpVersionFromWire } from "../../schema/topology.ts";
import { attributionForProvenance, sessionEndpoint } from "../../schema/session-end.ts";
import type { StageLedger } from "../stage-ledger.ts";
import type { TimelineEvent } from "../timeline.ts";
import {
	type BaseTimelineEvent,
	codecFromWire,
	nonEmptyStringFromWire,
	numberFromWire,
	stringFromWire,
} from "./record.ts";

export function applyEvent(
	ev: BaseTimelineEvent,
	state: {
		ledger: StageLedger;
		hostOfScope: Map<string, string>;
		sessionsOfScope: Map<string, Set<string>>;
	},
	out: TimelineEvent[],
	known: {
		partnerOwnName: string | undefined;
		partnerOwnProfile: string | undefined;
	},
): void {
	const { ledger, hostOfScope, sessionsOfScope } = state;
	const simNs = numberFromWire(ev.sim_t_ns);
	if (simNs == null) return;
	const kind = stringFromWire(ev.kind);
	if (kind == null) return;
	const t_ms = simNs / 1_000_000;

	switch (kind) {
		case "ocapn.session-opened": {
			const session = nonEmptyStringFromWire(ev.session);
			const a = nonEmptyStringFromWire(ev.a);
			const b = nonEmptyStringFromWire(ev.b);
			if (session == null || a == null || b == null) return;
			// Which host a producer reports as its own, so its departure can retire
			// exactly that node and no other. The scope prefixes every id this
			// endpoint assigns, so it is readable without a second field.
			const scope = scopeOf(session);
			hostOfScope.set(scope, a);
			const watching = sessionsOfScope.get(scope);
			if (watching === undefined) {
				sessionsOfScope.set(scope, new Set([session]));
			} else watching.add(session);
			// What the producer's verdict proved, if it proved anything. One read of
			// it, so the same answer decides whether the far end may be taken as an
			// identity and what the attached end says backed it.
			const provenance = stringFromWire(ev.provenance);
			const proved = attributionForProvenance(provenance);
			// The negotiated CapTP profile, read once: omitted means an old producer
			// from before the field, while a present unknown word remains unknown.
			// Only the glowcap-private track names both ends as glowcap hosts.
			const captpVersion = captpVersionFromWire(ev.captp_version) ??
				"v1_0";
			const aLabel = stringFromWire(ev.a_label);
			const aProfile = nonEmptyStringFromWire(ev.a_profile);
			const sessionId = nonEmptyStringFromWire(ev.session_id);
			const transport = nonEmptyStringFromWire(ev.transport);
			const row = ledger.openSession(session, a, b, t_ms, out, {
				...(provenance != null && { verified: proved !== undefined }),
				// Display only. `a` is the reporting host's own designator, which is
				// what a partner names it by and therefore the one honest merge key
				// across producers; `a_label` is what a human reads instead of 64 hex
				// digits, and it reaches no key and no merge.
				...(aLabel != null && { aLabel }),
				// What the producer says it runs, which is the only thing that names
				// its own end. An empty string is a producer saying nothing, not an
				// implementation with no name, so it is left unstated the way an
				// empty transport is.
				...(aProfile != null ? { selfProfile: aProfile } : {}),
				// The one name both ends of this session derive. It is what makes
				// this observation and the far end's observation the same edge.
				...(sessionId != null && { wire: sessionId }),
				// Set only when a resolved snapshot already holds the far end's own
				// report of this wire. Live, nothing can supply it.
				...(known.partnerOwnName !== undefined &&
					{ partnerOwnName: known.partnerOwnName }),
				// And what that far end's own report says it runs, which the same
				// resolved snapshot holds. Live, nothing can supply either.
				...(known.partnerOwnProfile !== undefined &&
					{ partnerOwnProfile: known.partnerOwnProfile }),
				// `glowcap-next` is glowcap's own CapTP profile and travels only
				// between glowcap peers (ADR-0001), so a session on it says what
				// both of its ends run. `v1_0` is the OCapN interop floor and says
				// nothing, glowcap speaks it too.
				...(captpVersion === "next" && { glowcapPrivateProfile: true }),
			});
			// Null means another producer already put this wire on stage: an edge
			// watched from both ends is still one edge.
			if (row === null) return;
			out.push({
				id: ledger.nextId(),
				t: t_ms,
				kind: "session-opened",
				sessionId: row.stageId,
				// The reporting host's own end is attributed by its self-report;
				// the far end attaches only when something backed its claim, and
				// otherwise stays loose with the claim on it.
				a: sessionEndpoint({
					peer: row.aStage,
					designator: a,
					attributedBy: "self-reported",
				}),
				// What backed the far end is what the ledger says put it there, never
				// a guess read back off this record. An end the ledger attached by
				// correlating two producers' reports of one session id says exactly
				// that; an end attached because the producer named it carries the
				// producer's own verdict, and carries NOTHING when the producer
				// stated no verdict, because then nothing was measured and the viewer
				// has no attribution to offer. Attached with no attribution is the
				// shape an authored scenario already has: somebody is on this end, and
				// the recording does not say what proved it.
				b: sessionEndpoint(
					row.b === undefined ? { designator: b } : {
						peer: row.b.stage,
						designator: b,
						attributedBy: row.b.backing === "correlated" ? "viewer-correlated" : proved,
					},
				),
				// The netlayer this session runs over, carried straight across.
				// Both ends share it, so it belongs to the session and not to
				// either end. A producer that reports none predates the field.
				...(transport != null ? { transport } : {}),
				codec: codecFromWire(ev.codec),
				// This document's own tag for the profile, read off the handshake
				// word the producer sent (`captpVersionFromWire`). A producer that
				// reports none predates the field, and the only profile that
				// existed then was the floor; a present unknown word stays unknown.
				captpVersion,
				// The trace reports a session only once its handshake
				// completed, so it arrives on stage already open, without
				// this the stage shows "negotiating" forever.
				initialState: "open",
			});
			return;
		}
		case "ocapn.message-decoded": {
			// Replayed messages are history, not part of this viewer's
			// capture, replay materializes topology (state) only.
			if (ev.replay === true) return;
			const session = nonEmptyStringFromWire(ev.session);
			if (session == null) return;
			// A live host tap names only its session and direction; the ledger
			// owns endpoint labeling, and owns folding a second end's sighting of
			// the same message into the first. An extractor that knows src/dst
			// directly still names them itself.
			let from: string | undefined;
			let to: string | undefined;
			let sessionStage: string | undefined;
			const src = nonEmptyStringFromWire(ev.src);
			const dst = nonEmptyStringFromWire(ev.dst);
			if (src != null && dst != null) {
				from = ledger.ensurePeer(src, t_ms, out).stageId;
				to = ledger.ensurePeer(dst, t_ms, out).stageId;
			} else if (ev.outbound !== undefined) {
				const drawn = ledger.messageOn(
					session,
					ev.outbound,
					stringFromWire(ev.digest),
				);
				if (drawn === null) return;
				from = drawn.from;
				to = drawn.to;
				sessionStage = drawn.sessionId;
			}
			if (from === undefined || to === undefined) return;
			// When the producer captured the departure timestamp, anchor
			// the message-sent event at depart and let arrivalT carry the
			// observed flight time. The renderer animates `t → arrivalT`.
			// Without depart_ns (a live host tap observes only arrival),
			// stamp arrivalT EQUAL to t: the projection reads a zero
			// flight as "unobserved" and substitutes its default, so the
			// message flies visibly instead of in a sub-frame flash.
			const departNs = numberFromWire(ev.depart_ns);
			const depart_t_ms = departNs !== undefined ? departNs / 1_000_000 : t_ms;
			// Payload pass-through: whole frame (`bytes_b64`) or the
			// producer-capped head (`summary`); the true length rides
			// beside either. This layer neither decodes nor re-bounds,
			// the producer owns the cap, the Inspector owns the display.
			const bytesB64 = stringFromWire(ev.bytes_b64) ??
				stringFromWire(ev.summary?.head_b64);
			const byteLen = numberFromWire(ev.len) ??
				numberFromWire(ev.summary?.len);
			const label = stringFromWire(ev.op);
			out.push({
				id: ledger.nextId(),
				t: depart_t_ms,
				kind: "message-sent",
				sessionId: sessionStage ?? session,
				messageId: ledger.nextId(),
				from,
				to,
				arrivalT: t_ms,
				...(label != null && { label }),
				...(bytesB64 !== undefined && { bytesB64 }),
				...(byteLen !== undefined && { byteLen }),
			});
			return;
		}
		case "ocapn.session-meta": {
			// An application annotation about the session's PARTNER, the
			// reporting host is `a`, so the name is about `b`. A claim
			// folds into the partner's label only; it never merges or
			// splits peers (the ledger's identity rules are untouched).
			const session = nonEmptyStringFromWire(ev.session);
			if (session == null || ev.meta === undefined) return;
			if (ev.meta.label === undefined) return;
			const label = ev.meta.label === null ? null : stringFromWire(ev.meta.label);
			if (label === undefined) return;
			// The ledger owns what each stage peer is called, so it decides
			// whether this claim is a rename, a withdrawal, a restatement to
			// ignore, or a name to hold until its session opens.
			ledger.nameSessionPartner(session, label, t_ms, out);
			return;
		}
		case "trace.producer-left": {
			// A reporting host outlives its sessions, because a room server is
			// there whether or not anyone is connected. That reasoning ends at the
			// producer's own life: a browser tab that refreshes is gone, and its
			// node would otherwise be one nothing could retire. Only the endpoint
			// knows a producer departed, so it says so and this retires the one
			// host that producer spoke for.
			//
			// Its sessions go too, and they go as UNOBSERVED. The endpoint reports
			// only that the producer left; whether the conversations it was
			// watching are still running is not something anyone observed, and the
			// viewer is the layer that decides what a departure means for its own
			// picture. A wire the departing producer shared with another producer
			// still standing survives, because the ledger only ends a wire when
			// its LAST observer goes.
			const scope = nonEmptyStringFromWire(ev.scope);
			if (scope == null) return;
			const watched = sessionsOfScope.get(scope);
			if (watched !== undefined) {
				sessionsOfScope.delete(scope);
				for (const sessionId of watched) {
					ledger.closeSession(sessionId, t_ms, out, "unobserved");
				}
			}
			const host = hostOfScope.get(scope);
			if (host === undefined) return;
			hostOfScope.delete(scope);
			ledger.producerLeft(host, t_ms, out);
			return;
		}
		case "ocapn.session-closed": {
			const session = nonEmptyStringFromWire(ev.session);
			if (session == null) return;
			// A closed session is no longer one its producer is watching, so
			// it leaves the producer's set here. Without this the set only
			// ever grew, and a producer that opens and closes conversations
			// all day carried every one it had ever reported until it left.
			// The scope's whole row goes when its last session does.
			const scope = scopeOf(session);
			const watching = sessionsOfScope.get(scope);
			if (watching !== undefined) {
				watching.delete(session);
				if (watching.size === 0) sessionsOfScope.delete(scope);
			}
			for (const retired of ledger.closeSession(session, t_ms, out)) {
				const retiredScope = scopeOf(retired);
				const counterpart = sessionsOfScope.get(retiredScope);
				if (counterpart === undefined) continue;
				counterpart.delete(retired);
				if (counterpart.size === 0) {
					sessionsOfScope.delete(retiredScope);
				}
			}
			return;
		}
		default:
			return;
	}
}

/** The producer scope the endpoint prefixed onto a session id (`p3/live-h1-s2`).
 * The endpoint assigns it, so it is the one part of an id no producer chose. */
export function scopeOf(sessionId: string): string {
	const at = sessionId.indexOf("/");
	return at < 0 ? "" : sessionId.slice(0, at);
}
