import { Connector, Session, SignalingSendOwner, TRANSPORT_WEBRTC } from "@pancake/runtime";
import { abortable } from "@pancake/runtime/transport";
import { RtcPeer } from "./peer.ts";

/** Signaling authority used to establish one WebRTC DataChannel. */
export interface SignalingAuthority {
	offer(designator: string, sdp: string): Promise<string>;
	candidate(designator: string, ice: string): void | Promise<void>;
	onCandidate(designator: string, sink: (ice: string) => void): () => void;
}

/** Deliver one remote ICE candidate. The signaling owner decides whether a
 * late refusal is terminal; this plumbing seam never suppresses it. */
export async function acceptRemoteCandidate(
	peer: { addRemoteCandidate(candidate: RTCIceCandidateInit): Promise<void> },
	ice: string,
): Promise<void> {
	await peer.addRemoteCandidate(JSON.parse(ice));
}

/** Configure an explicit WebRTC byte connector over caller-owned signaling. */
export function connector(signaling: SignalingAuthority): Connector {
	return new Connector([TRANSPORT_WEBRTC], async (host, locator, request) => {
		const peer = new RtcPeer({ offerer: true });
		const bringup = new AbortController();
		const forwardAbort = (): void => {
			if (!bringup.signal.aborted) bringup.abort();
		};
		if (request.signal?.aborted) forwardAbort();
		else request.signal?.addEventListener("abort", forwardAbort, { once: true });
		let disposeCandidates: (() => void) | null = null;
		let candidatesStopped = false;
		const stopCandidates = (): void => {
			if (candidatesStopped) return;
			candidatesStopped = true;
			disposeCandidates?.();
		};
		const candidateSends = new SignalingSendOwner(
			"webrtc dial",
			(error) => bringup.abort(error),
		);
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
		try {
			disposeCandidates = signaling.onCandidate(locator.designator, (ice) => {
				void acceptRemoteCandidate(peer, ice).catch((error) => bringup.abort(error));
			});
			peer.onLocalCandidate((candidate) =>
				candidateSends.admit(() => signaling.candidate(locator.designator, JSON.stringify(candidate)))
			);
			const offer = await abortable(peer.createOffer(), bringup.signal);
			const answer = await abortable(
				signaling.offer(locator.designator, offer),
				bringup.signal,
			);
			await abortable(peer.setRemoteAnswer(answer), bringup.signal);
			await abortable(peer.waitOpen(), bringup.signal);
			session = await abortable(
				Session.establishDialedLocator(
					host,
					locator,
					peer.channel(),
					request.handshakeTimeoutMs,
				),
				bringup.signal,
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
					request.signal?.removeEventListener("abort", forwardAbort);
				}
			}
		}
		if (candidateSends.failure != null) {
			session?.closeTransport();
			throw candidateSends.failure;
		}
		return session!;
	});
}
