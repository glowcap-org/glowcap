// What a browser WebRTC dial and accept share: the signaling contract, the
// exchange ids, and the bring-up that runs one `RtcPeer` from its first
// candidate to a keyed session.

import { type Channel, type Host, type Session, SignalingSendOwner } from "@glowcap/runtime";
import { abortable } from "@glowcap/runtime/transport";
import { RtcPeer } from "./peer.ts";
import { assertSignalBytes } from "./signal.ts";

/** The peer one exchange is with. `introducer` is the designator of the
 * session that handed over the reference a dial follows, so the application
 * can carry signaling through the party that knows the peer. It is `null` for
 * an accept, for a dial the application started itself, and for one whose
 * introducing session signed no designator. */
export interface SignalingTarget {
	readonly designator: string;
	readonly introducer: string | null;
}

/** How the application carries signaling to the peer a `SignalingTarget`
 * names. The library calls these from its own steps, so none may block. The
 * same authority serves a browser connector and listener and the Deno driver.
 *
 * Every call names its exchange by id, an unsigned 64-bit number that is
 * unique among the exchanges the authority serves. The calls that open an
 * exchange's route (`offer`, `answer`, and `onCandidate`) also name its
 * target. `candidate` takes only the id.
 *
 * For one dial, `onCandidate` is called first, then `offer`, then `candidate`
 * for each local candidate, all with the same exchange. For one accept,
 * `answer` carries the SDP answer to the offerer whose offer the listener
 * took, and `onCandidate` and `candidate` run as for a dial. A dial never
 * calls `answer`, and an accept never calls `offer`, so an authority that
 * only dials or only answers leaves the other out.
 *
 * A thrown error or a rejected promise from `answer` or `candidate` ends that
 * exchange. The far peer may trickle candidates before `onCandidate`
 * subscribes, so the authority buffers what arrives for an exchange until its
 * sink exists.
 *
 * Candidates route by exchange id, so a dial to a peer and that peer's own
 * offer run side by side as two exchanges. CapTP's crossed-hellos rule keeps
 * one session. */
export interface SignalingAuthority {
	offer(exchange: bigint, target: SignalingTarget, sdp: string): Promise<string>;
	answer(exchange: bigint, target: SignalingTarget, sdp: string): void | Promise<void>;
	candidate(exchange: bigint, ice: string): void | Promise<void>;
	onCandidate(exchange: bigint, target: SignalingTarget, sink: (ice: string) => void): () => void;
}

/** How a browser peer gathers candidates. */
export interface PeerOptions {
	/** ICE servers (STUN/TURN) this side offers candidates through. Omitted or
	 * empty gathers host candidates only, which reach a peer on the same network
	 * and no other. A source is asked once per connection so short-lived TURN
	 * credentials are never frozen when the connector or listener is made. The
	 * far side must be given the same kind of reach, or only one of the two can
	 * describe itself in terms the other can dial. */
	iceServers?: RTCIceServer[] | (() => Promise<RTCIceServer[]>);
}

/** Deliver one remote ICE candidate. The signaling owner decides whether a
 * late refusal is terminal, and this never suppresses it. */
export async function acceptRemoteCandidate(
	peer: { addRemoteCandidate(candidate: RTCIceCandidateInit): Promise<void> },
	ice: string,
): Promise<void> {
	await peer.addRemoteCandidate(JSON.parse(assertSignalBytes("signaling message", ice)));
}

// The next exchange id. One counter serves every connector and listener in the
// module, so ids are unique across all that share an authority.
let nextExchange = 1n;

/** Mint an id for one browser exchange. The Deno driver takes its ids from the
 * C library instead. */
export function mintExchange(): bigint {
	return nextExchange++;
}

/** The steps that differ between a dial and an accept. */
export interface Negotiation {
	/** Which side creates the channel and the offer. */
	readonly offerer: boolean;
	/** Exchange descriptions with the far peer. Wrap each awaited step in
	 * `step`, which cancels with the bring-up and names the step for a late
	 * settlement. */
	negotiate(peer: RtcPeer, step: <T>(work: Promise<T>, name: string) => Promise<T>): Promise<void>;
	/** Called once the DataChannel opens, before the handshake starts. */
	opened?(): void;
	/** Run the keyed handshake over the open channel. */
	establish(channel: Channel): Promise<Session>;
}

/** Run one exchange from subscription to keyed session. Candidates flow both
 * ways through `signaling` under `exchange` while `negotiation` trades the
 * descriptions. Aborting `signal` cancels the bring-up and closes the peer,
 * and any failure closes it too. A late settlement of a cancelled step is
 * kept as a callerless failure on `host`. */
export async function bringUp(
	host: Host,
	signaling: Pick<SignalingAuthority, "candidate" | "onCandidate">,
	exchange: bigint,
	target: SignalingTarget,
	options: PeerOptions,
	signal: AbortSignal | undefined,
	label: string,
	negotiation: Negotiation,
): Promise<Session> {
	const iceServers = typeof options.iceServers === "function" ? await options.iceServers() : options.iceServers;
	const peer = new RtcPeer({ offerer: negotiation.offerer, iceServers });
	const bringup = new AbortController();
	const forwardAbort = (): void => {
		if (!bringup.signal.aborted) bringup.abort();
	};
	if (signal?.aborted) forwardAbort();
	else signal?.addEventListener("abort", forwardAbort, { once: true });
	let disposeCandidates: (() => void) | null = null;
	let candidatesStopped = false;
	const stopCandidates = (): void => {
		if (candidatesStopped) return;
		candidatesStopped = true;
		disposeCandidates?.();
	};
	const candidateSends = new SignalingSendOwner(label, (error) => bringup.abort(error));
	let peerClosed = false;
	let session: Session | null = null;
	const closePeer = (): void => {
		if (peerClosed) return;
		peerClosed = true;
		peer.close();
	};
	const cancel = (): void => {
		candidateSends.stopAdmission();
		stopCandidates();
		closePeer();
	};
	bringup.signal.addEventListener("abort", cancel, { once: true });
	if (bringup.signal.aborted) cancel();
	const step = <T>(work: Promise<T>, name: string): Promise<T> =>
		abortable(
			work,
			bringup.signal,
			(error) => host.recordCallerlessBindingFailure(`webrtc.${name}.cancel.late-settlement`, error),
		);
	try {
		disposeCandidates = signaling.onCandidate(exchange, target, (ice) => {
			void acceptRemoteCandidate(peer, ice).catch((error) => bringup.abort(error));
		});
		peer.onLocalCandidate((candidate) =>
			candidateSends.admit(() => signaling.candidate(exchange, JSON.stringify(candidate)))
		);
		await negotiation.negotiate(peer, step);
		await step(peer.waitOpen(), "open");
		negotiation.opened?.();
		session = await abortable(
			negotiation.establish(peer.channel()),
			bringup.signal,
			(error) => host.recordCallerlessBindingFailure("webrtc.session.cancel.cleanup", error),
			(opened) => opened.closeTransport(),
		);
	} catch (error) {
		closePeer();
		throw error;
	} finally {
		candidateSends.stopAdmission();
		try {
			stopCandidates();
		} finally {
			if (bringup.signal.aborted) closePeer();
			try {
				await candidateSends.join();
			} finally {
				bringup.signal.removeEventListener("abort", cancel);
				signal?.removeEventListener("abort", forwardAbort);
			}
		}
	}
	if (candidateSends.failure != null) {
		session?.closeTransport();
		throw candidateSends.failure;
	}
	return session!;
}
