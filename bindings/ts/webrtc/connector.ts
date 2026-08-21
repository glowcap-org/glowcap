import { Connector, Session, SignalingSendOwner, TRANSPORT_WEBRTC } from "@pancake/runtime";
import { abortable } from "@pancake/runtime/transport";
import { RtcPeer } from "./peer.ts";
import { assertSignalBytes } from "./signal.ts";

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
	await peer.addRemoteCandidate(JSON.parse(assertSignalBytes("signaling message", ice)));
}

/** How a connector reaches a peer it cannot address directly. */
export interface ConnectorOptions {
	/** ICE servers (STUN/TURN) this side offers candidates through. Omitted or
	 * empty gathers host candidates only, which reach a peer on the same network
	 * and no other. A source is asked once per connection so short-lived TURN
	 * credentials are never frozen at connector construction. The answering side
	 * must be given the same kind of reach, or only one of the two can describe
	 * itself in terms the other can dial. */
	iceServers?: RTCIceServer[] | (() => Promise<RTCIceServer[]>);
}

/** Configure an explicit WebRTC connector over caller-owned signaling. */
export function connector(signaling: SignalingAuthority, options: ConnectorOptions = {}): Connector {
	return new Connector([TRANSPORT_WEBRTC], async (host, locator, request) => {
		const configuredIce = typeof options.iceServers === "function"
			? await options.iceServers()
			: options.iceServers;
		const peer = new RtcPeer({ offerer: true, iceServers: configuredIce });
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
		const retainLate = (operation: string) => (error: unknown) =>
			host.recordCallerlessBindingFailure(operation, error);
		try {
			disposeCandidates = signaling.onCandidate(locator.designator, (ice) => {
				void acceptRemoteCandidate(peer, ice).catch((error) => bringup.abort(error));
			});
			peer.onLocalCandidate((candidate) =>
				candidateSends.admit(() => signaling.candidate(locator.designator, JSON.stringify(candidate)))
			);
			const offer = await abortable(
				peer.createOffer(),
				bringup.signal,
				retainLate("webrtc.offer.cancel.late-settlement"),
			);
			const answer = await abortable(
				signaling.offer(locator.designator, offer),
				bringup.signal,
				retainLate("webrtc.signaling.cancel.late-settlement"),
			);
			await abortable(
				peer.setRemoteAnswer(answer),
				bringup.signal,
				retainLate("webrtc.remote-answer.cancel.late-settlement"),
			);
			await abortable(
				peer.waitOpen(),
				bringup.signal,
				retainLate("webrtc.open.cancel.late-settlement"),
			);
			session = await abortable(
				Session.establishDialedLocator(
					host,
					locator,
					peer.channel(),
					request.handshakeTimeoutMs,
				),
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
