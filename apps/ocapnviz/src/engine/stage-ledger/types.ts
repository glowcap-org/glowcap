/**
 * Stage-ledger vocabulary: the live peer and wire rows, and the keys
 * that identify them. The ledger class owns the maps; this module owns
 * the shape of an entry and the functions that name a side or a wire.
 */

import { GLOWCAP_PROFILE, type PeerProfile } from "../../schema/topology.ts";
import type { SessionSide } from "../../schema/session-end.ts";

/** A live incarnation of a peer. `stageId` is the timeline entity id
 * this incarnation renders as, and `liveWires` counts the open wires
 * touching it — a peer leaves when the last one closes, unless it is
 * `eternal` (a producer's own reporting host, whose lifetime is its
 * producer's rather than any one session's).
 *
 * What the peer is CALLED is three facts, most specific first: a
 * partner's application annotation (`claimLabel`, a chat nick), the
 * producer's own display name for itself (`selfLabel`), and the name
 * it joined under. Held apart so withdrawing a claim reveals the name
 * underneath instead of freezing the last thing anyone said. */
export type LivePeer = {
	stageId: string;
	liveWires: number;
	eternal: boolean;
	joinName: string;
	selfLabel: string | undefined;
	claimLabel: string | undefined;
	/** What is currently on screen, so a restatement is not a rename. */
	shown: string;
	/** The implementation this peer is currently known by, so a
	 * restatement is not a change. Starts unknown and only ever moves to a
	 * named implementation — see `LedgerNames.learnProfile`. */
	profile: PeerProfile;
};

/** One producer's view of a wire: which side it occupies, so a
 * message's `outbound` flag reads against the right end. */
export type Observer = {
	selfStage: string;
	/** The node the far end sits at, or undefined while it is loose. */
	otherStage: string | undefined;
	/** Ledger keys of the same two sides, for the close refcount. */
	selfKey: string;
	otherKey: string;
};

/** A live incarnation of one wire — one stage session, however many
 * producers report it. */
export type LiveWire = {
	stageId: string;
	/** The two ends. Which POSITION a side holds is fixed when the wire
	 * opens — `a` is the end the first observer reported as its own —
	 * and only the key AT a position ever moves (`#retargetSide`). Every
	 * `session-endpoint-attributed` the timeline holds names a position,
	 * so swapping these would silently retarget keyframes already
	 * recorded. */
	aKey: string;
	bKey: string;
	/** Every producer session watching this wire, by scoped session id. */
	observers: Map<string, Observer>;
	/** Message tags already drawn on this wire. A tag is entered by the
	 * first end to report the message and CONSUMED by the second, so a
	 * peer that genuinely sends the same bytes twice draws two
	 * messages. Bounded, oldest out first. */
	seen: Set<string>;
	/** Names an application claimed for an end nobody could name yet,
	 * by side, held until the end attaches to a peer that can wear
	 * them.
	 *
	 * It lives on the wire because that is what it is about: a claim
	 * names one end of one conversation, and when the conversation goes
	 * the claim has nothing left to be about. Kept in a ledger-wide map
	 * instead it outlived every wire it described and grew for the
	 * feed's life. At most two entries, and they die with the row. */
	looseClaims: Map<SessionSide, string>;
};

/** Message tags held per wire for the fold. One conversation's
 * in-flight window is a handful; this is far past it and still a
 * fixed ceiling per wire. */
export const MAX_SEEN_DIGESTS = 512;

/** Why a row on stage ended.
 *
 * `closed` is a protocol fact somebody observed: CapTP tore the
 * session down, or the peer departed. `unobserved` is a fact about
 * this viewer and nothing else: the telemetry that was showing it
 * went away, and what the conversation did next is unknown here.
 *
 * They are different claims and the timeline says which, because a
 * viewer that reported the second as the first would be inventing a
 * teardown out of a dropped socket. */
export type EndingReason = "closed" | "unobserved";

/** How a wire's far end came to be attached to a peer.
 *
 * The ledger attaches an end for one of exactly two reasons, and they are
 * different claims, so a caller that has to say what backed the end is told
 * which one it got rather than inferring one from what it passed in.
 *
 * `partner-named` means the reporting producer named that end and the caller
 * passed the name as an identity (`openSession`'s `verified`). What backed the
 * name is the caller's own fact — this ledger never sees the evidence.
 * `correlated` means a second producer's own report of this same wire supplied
 * the name: a correlation across two self-reports, which is the viewer's
 * inference and nobody's measurement. */
export type FarEndBacking = "partner-named" | "correlated";

/** The ledger key for a wire side no producer has spoken for. Wire
 * names are 64 hex digits and designators are hex too, so the prefix
 * is what keeps an unattributed side from ever colliding with a real
 * name. */
export function anonKey(wireKey: string): string {
	return `claim@${wireKey}`;
}

/** Which end of a wire a ledger key sits on. */
export function sideOf(row: LiveWire, key: string): SessionSide {
	return row.aKey === key ? "a" : "b";
}

/** What one observation says about its own reporting end: the producer's
 * own statement, and failing that glowcap when the session negotiated the
 * profile only glowcap speaks.
 *
 * The two arms are the two things `LedgerNames.learnProfile` reads, applied
 * to the end the reporting producer occupies. A statement wins over the
 * inference because it is the stronger claim: a producer naming itself
 * something that cannot speak `glowcap-next` is a producer contradicting
 * itself, and the viewer repeats what it was told rather than correcting it. */
export function selfProfileOf(opts?: {
	selfProfile?: PeerProfile;
	glowcapPrivateProfile?: boolean;
}): PeerProfile | undefined {
	if (opts?.selfProfile !== undefined) return opts.selfProfile;
	return opts?.glowcapPrivateProfile === true ? GLOWCAP_PROFILE : undefined;
}

/** The name an observation's edge is keyed on: the wire, which both
 * ends of a session derive and neither had to be told, falling back
 * to the reporting producer's own scoped session id when the partner
 * sent no session key.
 *
 * Exported because the ledger is not the only caller that has to
 * group observations by edge — resolving a replayed batch groups by
 * the same thing before handing anything to `openSession`, and two
 * implementations of "which edge is this" would be two answers the moment
 * one of them changed. */
export function wireKeyFor(
	sessionId: string,
	wire: string | undefined,
): string {
	return wire !== undefined && wire.length > 0 ? wire : sessionId;
}
