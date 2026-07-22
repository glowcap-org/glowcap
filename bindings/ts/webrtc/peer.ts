/// <reference lib="dom" />

// A browser WebRTC peer: an RTCPeerConnection and its single reliable, ordered
// `ocapn` DataChannel, the browser sibling of the native sidecar's `Peer`
// (ADR-0089). It drives the signaling exchange (offer, answer, ICE) and, once
// the channel opens, presents it as a byte `Channel` a keyed OCapN session runs
// over. Signaling itself is carried by an OCapN capability (a room), not this
// module; the `RtcPeer` only produces and consumes the SDP and candidate
// strings, mirroring the native sidecar's signaling surface.

import type { Channel } from "@pancake/stack";
import { rtcChannel } from "./channel.ts";

const CHANNEL_LABEL = "ocapn";

export interface RtcPeerInit {
	/** The offerer creates the data channel and the SDP offer; the answerer
	 * receives the channel and produces the answer. */
	offerer: boolean;
	/** ICE servers (STUN/TURN). Empty (the default) gathers host candidates only:
	 * loopback and LAN reach each other with no infrastructure (ADR-0089). */
	iceServers?: RTCIceServer[];
}

export class RtcPeer {
	readonly #pc: RTCPeerConnection;
	#dc: RTCDataChannel | null = null;
	readonly #open: Promise<void>;
	#markOpen!: () => void;
	readonly #pendingLocal: RTCIceCandidateInit[] = [];
	#candidateSink: ((candidate: RTCIceCandidateInit) => void) | null = null;

	constructor(init: RtcPeerInit) {
		this.#pc = new RTCPeerConnection({ iceServers: init.iceServers ?? [] });
		this.#open = new Promise((resolve) => (this.#markOpen = resolve));
		this.#pc.onicecandidate = (event) => {
			if (!event.candidate) return;
			const json = event.candidate.toJSON();
			if (this.#candidateSink) this.#candidateSink(json);
			else this.#pendingLocal.push(json);
		};
		if (init.offerer) {
			this.#wireChannel(this.#pc.createDataChannel(CHANNEL_LABEL, { ordered: true }));
		} else {
			this.#pc.ondatachannel = (event) => this.#wireChannel(event.channel);
		}
	}

	#wireChannel(dc: RTCDataChannel): void {
		this.#dc = dc;
		if (dc.readyState === "open") this.#markOpen();
		else dc.onopen = () => this.#markOpen();
	}

	/** Produce the SDP offer and set it as the local description. Offerer only. */
	async createOffer(): Promise<string> {
		const offer = await this.#pc.createOffer();
		await this.#pc.setLocalDescription(offer);
		return offer.sdp ?? "";
	}

	/** Produce the SDP answer and set it as the local description. Answerer only,
	 * after `setRemoteOffer`. */
	async createAnswer(): Promise<string> {
		const answer = await this.#pc.createAnswer();
		await this.#pc.setLocalDescription(answer);
		return answer.sdp ?? "";
	}

	/** Set the far offerer's SDP offer as the remote description. Answerer side. */
	setRemoteOffer(sdp: string): Promise<void> {
		return this.#pc.setRemoteDescription({ type: "offer", sdp });
	}

	/** Set the far answerer's SDP answer as the remote description. Offerer side. */
	setRemoteAnswer(sdp: string): Promise<void> {
		return this.#pc.setRemoteDescription({ type: "answer", sdp });
	}

	/** Add one ICE candidate the far peer gathered. */
	addRemoteCandidate(candidate: RTCIceCandidateInit): Promise<void> {
		return this.#pc.addIceCandidate(candidate);
	}

	/** Register a sink for locally gathered ICE candidates, flushing any already
	 * gathered. The caller ferries each to the far peer through signaling. */
	onLocalCandidate(sink: (candidate: RTCIceCandidateInit) => void): void {
		this.#candidateSink = sink;
		for (const candidate of this.#pendingLocal.splice(0)) sink(candidate);
	}

	/** Resolves when the data channel opens. */
	waitOpen(): Promise<void> {
		return this.#open;
	}

	/** The open channel as a byte `Channel` a keyed session runs over. Call after
	 * `waitOpen` reports the channel open. */
	channel(): Channel {
		if (!this.#dc) throw new Error("webrtc: data channel not established");
		return rtcChannel(this.#dc);
	}

	/** Close the peer connection and its channel. Idempotent. */
	close(): void {
		this.#pc.close();
	}
}
