/**
 * How a live row ends: a wire closing, a producer leaving, a viewer
 * losing sight, or a whole epoch going dark.
 *
 * Ending is its own subject because the timeline has to say *why*.
 * `closed` is a protocol fact, `unobserved` is a fact about this
 * viewer. Mixing them invents a teardown out of a dropped socket.
 * The ledger still owns who is on stage. This class owns the refcount
 * and the events that fire when the last reference goes.
 */

import type { TimelineEvent } from "../timeline.ts";
import type { LedgerNames } from "./names.ts";
import type { EndingReason, LivePeer, LiveWire } from "./types.ts";

export class LedgerLifetime {
	constructor(
		private readonly peers: Map<string, LivePeer>,
		private readonly wires: Map<string, LiveWire>,
		private readonly wireOfSession: Map<string, string>,
		private readonly names: LedgerNames,
		private readonly nextId: () => string,
	) {}

	/** Drop one wire reference. The peer's row ends when its last one
	 * goes (unless it is a live producer's own reporting host). `why`
	 * carries the reason the wire went, because it is the peer's reason
	 * too: a peer whose last conversation the viewer merely stopped
	 * WATCHING did not depart. */
	#releasePeer(
		key: string,
		t: number,
		out: TimelineEvent[],
		why: EndingReason,
	): void {
		const live = this.peers.get(key);
		if (live === undefined) return;
		live.liveWires = Math.max(0, live.liveWires - 1);
		this.#retireIfIdle(key, live, t, out, why);
	}

	#retireIfIdle(
		key: string,
		live: LivePeer,
		t: number,
		out: TimelineEvent[],
		why: EndingReason,
	): void {
		if (live.liveWires > 0 || live.eternal) return;
		this.peers.delete(key);
		out.push({
			id: this.nextId(),
			t,
			kind: why === "closed" ? "peer-left" : "peer-unobserved",
			peerId: live.stageId,
		});
	}

	/** One producer's observation of a session ended. An explicit CapTP
	 * close is a fact about the shared wire, so either endpoint retires
	 * the whole row. Losing telemetry is only a fact about that observer.
	 * The row then ends when its last observer disappears.
	 *
	 * `why` says which of those the caller is reporting, and it is the
	 * difference between a claim about the network and a claim about
	 * this viewer. `closed` means a producer observed CapTP tear the
	 * session down. `unobserved` means the viewer lost sight of it and
	 * knows nothing about the conversation itself. */
	closeSession(
		sessionId: string,
		t: number,
		out: TimelineEvent[],
		why: EndingReason = "closed",
	): string[] {
		// An ending ends this session's current life, so a name claimed for it
		// and never applied is moot. Dropping it here is what stops it from
		// naming the NEXT session to take the same id.
		this.names.drop(sessionId);
		const wireKey = this.wireOfSession.get(sessionId);
		if (wireKey === undefined) return [];
		this.wireOfSession.delete(sessionId);
		const row = this.wires.get(wireKey);
		if (row === undefined) return [];
		row.observers.delete(sessionId);
		if (why === "unobserved" && row.observers.size > 0) return [];
		const retiredObservers = [...row.observers.keys()];
		for (const observerSessionId of row.observers.keys()) {
			this.wireOfSession.delete(observerSessionId);
			this.names.drop(observerSessionId);
		}
		row.observers.clear();
		this.wires.delete(wireKey);
		out.push({
			id: this.nextId(),
			t,
			kind: why === "closed" ? "session-closed" : "session-unobserved",
			sessionId: row.stageId,
		});
		this.#releasePeer(row.aKey, t, out, why);
		this.#releasePeer(row.bKey, t, out, why);
		return retiredObservers;
	}

	/** A producer left the feed, so the node it reported as its own
	 * stops being a reporting host. It does not vanish while another
	 * producer still shows a session to it. That peer is on stage
	 * because someone is talking to it, and only the last of those
	 * conversations ending takes it off.
	 *
	 * Its row ends as a loss of sight, not a departure. What actually
	 * happened is that a PUBLISHING SOCKET closed. A peer that turned
	 * tracing off looks exactly like one that went away, and picking
	 * the second is the inference this vocabulary exists to refuse. */
	producerLeft(key: string, t: number, out: TimelineEvent[]): void {
		const live = this.peers.get(key);
		if (live === undefined) return;
		live.eternal = false;
		this.#retireIfIdle(key, live, t, out, "unobserved");
	}

	/** An explicitly lifecycle-managed leave (generic sims own their
	 * hosts' lifetimes. Refcounting does not apply). */
	forceLeavePeer(key: string, t: number, out: TimelineEvent[]): void {
		const live = this.peers.get(key);
		if (live === undefined) return;
		this.peers.delete(key);
		out.push({
			id: this.nextId(),
			t,
			kind: "peer-left",
			peerId: live.stageId,
		});
	}

	/** The telemetry endpoint restarted, so everything it was showing
	 * goes out of view at once. Incarnation counters survive, so stage
	 * ids stay unique across epochs.
	 *
	 * Every row ends `unobserved`, and none ends closed. Some of these
	 * conversations really did die with the process, its own sessions
	 * did, but a conversation it was merely REPORTING, two browser
	 * tabs talking directly, did not, and the reconnecting producers
	 * will draw it again. From here the two are indistinguishable, so
	 * the timeline says the one thing that is true of both: the viewer
	 * stopped being able to see them. */
	closeEpoch(t: number, out: TimelineEvent[]): void {
		for (const row of this.wires.values()) {
			out.push({
				id: this.nextId(),
				t,
				kind: "session-unobserved",
				sessionId: row.stageId,
			});
		}
		this.wires.clear();
		this.wireOfSession.clear();
		// A dead process's claims name sessions that will never open.
		this.names.clear();
		for (const live of this.peers.values()) {
			out.push({
				id: this.nextId(),
				t,
				kind: "peer-unobserved",
				peerId: live.stageId,
			});
		}
		this.peers.clear();
	}
}
