/**
 * How a peer is called and what it is known to run.
 *
 * Display labels and implementation are knowledge facts, not wire facts:
 * a nick is never an identity, and a profile is stated rather than deduced.
 * This class owns the pending-name table (claims that arrived before their
 * session opened) and the one rule for when a label or profile change is
 * an event. The ledger still owns who is on which wire. Naming looks that
 * up, then writes the peer row.
 */

import { type PeerProfile, UNNAMED_PROFILE } from "../../schema/topology.ts";
import type { TimelineEvent } from "../timeline.ts";
import { type LivePeer, type LiveWire, sideOf } from "./types.ts";

/** How many names claimed for sessions that have not opened the
 * ledger holds at once. A producer states a session's partner name
 * around the time the session opens, so a handful are ever in
 * flight. The bound is what keeps a producer that names sessions it
 * never opens from growing this map for the feed's life. Oldest
 * claim out first. */
const MAX_PENDING_NAMES = 64;

export class LedgerNames {
	/** Names claimed for sessions the ledger has not seen open yet,
	 * by scoped session id. A producer that replays its state to a
	 * connecting viewer can state the name before the open, and the
	 * peer that name belongs to does not exist until the open, so
	 * the claim waits here and lands as the peer joins. */
	#pending = new Map<string, string | null>();

	constructor(
		private readonly peers: Map<string, LivePeer>,
		private readonly wires: Map<string, LiveWire>,
		private readonly wireOfSession: Map<string, string>,
		private readonly nextId: () => string,
	) {}

	drop(sessionId: string): void {
		this.#pending.delete(sessionId);
	}

	clear(): void {
		this.#pending.clear();
	}

	/** Apply a name an application claims for a session's partner, or
	 * withdraw the claim with `null`.
	 *
	 * Emits a rename only when the shown name actually changes. A
	 * producer states the name at every moment it knows it, the rooms
	 * server annotates a session when a member subscribes to a room AND
	 * again when it registers for direct messages, both with the same
	 * nick, and restating a name is not a rename. Withdrawing reveals
	 * the name underneath rather than freezing the last claim, which is
	 * how a member leaving a room stops being called by the nick that
	 * membership gave it.
	 *
	 * A claim for a session the ledger has not seen open waits (a
	 * producer replaying its state can send them in either order) and
	 * lands as that session opens. */
	nameSessionPartner(
		sessionId: string,
		label: string | null,
		t: number,
		out: TimelineEvent[],
	): void {
		const wireKey = this.wireOfSession.get(sessionId);
		const row = wireKey === undefined ? undefined : this.wires.get(wireKey);
		const obs = row?.observers.get(sessionId);
		if (row === undefined || obs === undefined) {
			this.#holdName(sessionId, label);
			return;
		}
		// An end nobody can name yet has no peer to wear the nick, and the claim
		// is about whoever turns out to be there rather than about nobody. It
		// waits on the end itself and transfers when the end attaches; a
		// withdrawal while it is still waiting simply takes it back.
		if (obs.otherStage === undefined) {
			const side = sideOf(row, obs.otherKey);
			if (label === null) row.looseClaims.delete(side);
			else row.looseClaims.set(side, label);
			return;
		}
		this.setClaimLabel(obs.otherKey, label, t, out);
	}

	/** Land a name claimed before its session opened, at the open's `t`:
	 * the peer arrives already answering to it, which is what an early
	 * claim means. */
	applyPendingName(sessionId: string, t: number, out: TimelineEvent[]): void {
		if (!this.#pending.has(sessionId)) return;
		const pending = this.#pending.get(sessionId) ?? null;
		this.#pending.delete(sessionId);
		this.nameSessionPartner(sessionId, pending, t, out);
	}

	/** A partner's application claim about this peer. */
	setClaimLabel(
		key: string,
		label: string | null,
		t: number,
		out: TimelineEvent[],
	): void {
		const live = this.peers.get(key);
		if (live === undefined) return;
		live.claimLabel = label ?? undefined;
		this.showLabel(live, t, out);
	}

	/** What a producer would like its own endpoint called. */
	setSelfLabel(
		live: LivePeer,
		label: string,
		t: number,
		out: TimelineEvent[],
	): void {
		live.selfLabel = label;
		this.showLabel(live, t, out);
	}

	/** State the implementation a peer turns out to run, from this moment on.
	 *
	 * Two things reach this verdict, both read at a session's hello, and only
	 * the second is something the viewer works out for itself:
	 *
	 * - **What the producer states.** A producer says what it runs beside the
	 *   designator it calls itself by (`a_profile` on the record), and that
	 *   statement is the whole of what names its own end. The `ocapn.*` kinds
	 *   are a schema, not a glowcap credential: the Goblins conformance peer
	 *   publishes the very same records, so a record ARRIVING says that
	 *   something is reporting and nothing whatever about what that something
	 *   is. A producer that states nothing leaves its own end unknown, and
	 *   that holds for glowcap's own producers too, to be named here, you
	 *   have to speak.
	 * - **The far end of a `next` session.** `glowcap-next` is a
	 *   glowcap-private CapTP profile (ADR-0003), so a session that
	 *   negotiated it has a glowcap host at each end. This is the one fact
	 *   the viewer reads without being told it. The converse proves nothing
	 *   and is not read: two glowcap peers meeting on the OCapN
	 *   v1.0 interop floor speak `v1_0`, exactly as a Goblins vat does, so a
	 *   `v1_0` session leaves its far end where it was.
	 *
	 * Nothing else is inferred, from a record's existence or from anything
	 * else. `goblins` in particular is only ever STATED: no observation here
	 * concludes it, and concluding it from the ABSENCE of a glowcap marker is
	 * the overreach this whole property exists to refuse.
	 *
	 * The move is one-way, from unknown to named, and the guard below holds
	 * it rather than the callers: a second observation restating what is
	 * already shown is not a change, and a peer nobody could speak for stays
	 * unknown rather than being told so. Learning that a peer runs something
	 * ELSE is not a case this can reach, because what a peer runs does not
	 * change while it lives, a different implementation is a different
	 * peer, so a caller offering one is a caller with a bug, and taking it
	 * would report a wire fact nothing observed. */
	learnProfile(
		live: LivePeer,
		profile: PeerProfile,
		t: number,
		out: TimelineEvent[],
	): void {
		if (profile === UNNAMED_PROFILE || live.profile !== UNNAMED_PROFILE) {
			return;
		}
		live.profile = profile;
		out.push({
			id: this.nextId(),
			t,
			kind: "peer-updated",
			peerId: live.stageId,
			profile,
		});
	}

	/** Put the most specific name this peer has on screen, emitting a
	 * rename only when it differs from what is already there. Display
	 * only, in both directions: it reads a ledger key and writes none,
	 * so a label can neither merge two peers nor split one. Every naming
	 * path lands here, so there is one rule for when a name change is an
	 * event. */
	showLabel(live: LivePeer, t: number, out: TimelineEvent[]): void {
		const next = live.claimLabel ?? live.selfLabel ?? live.joinName;
		if (next === live.shown) return;
		live.shown = next;
		out.push({
			id: this.nextId(),
			t,
			kind: "peer-updated",
			peerId: live.stageId,
			label: next,
		});
	}

	/** Hold a name claimed for a session that has not opened. Only the
	 * newest claim per session survives, and the oldest claim overall
	 * is dropped once the map is full. */
	#holdName(sessionId: string, label: string | null): void {
		this.#pending.delete(sessionId);
		this.#pending.set(sessionId, label);
		while (this.#pending.size > MAX_PENDING_NAMES) {
			const oldest = this.#pending.keys().next();
			if (oldest.done === true) break;
			this.#pending.delete(oldest.value);
		}
	}
}
