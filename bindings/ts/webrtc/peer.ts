/// <reference lib="dom" />

// A browser WebRTC peer: an RTCPeerConnection and its single reliable, ordered
// `ocapn` DataChannel, the browser sibling of the native sidecar's `Peer`
// (ADR-0089). It drives the signaling exchange (offer, answer, ICE) and, once
// the channel opens, presents it as an opaque packet channel. Signaling itself
// is carried by an OCapN capability (a room), not this module; the `RtcPeer`
// only produces and consumes the SDP and candidate strings, mirroring the
// native sidecar's signaling surface.

import type { Channel } from "@pancake/runtime";
import {
	WEBRTC_MAX_ICE_CANDIDATE_BYTES,
	WEBRTC_MAX_PENDING_ICE_CANDIDATES,
	WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES,
} from "@pancake/abi";
import { rtcChannel } from "./channel.ts";
import { assertSignalBytes, utf8ByteLengthUpTo } from "./signal.ts";

const CHANNEL_LABEL = "ocapn";
const MAX_PENDING_ICE_CANDIDATES = WEBRTC_MAX_PENDING_ICE_CANDIDATES;
const MAX_ICE_CANDIDATE_BYTES = WEBRTC_MAX_ICE_CANDIDATE_BYTES;
const MAX_PENDING_ICE_CANDIDATE_BYTES = WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES;

export interface RtcPeerInit {
	/** The offerer creates the data channel and the SDP offer; the answerer
	 * receives the channel and produces the answer. */
	offerer: boolean;
	/** ICE servers (STUN/TURN). Empty (the default) gathers host candidates only:
	 * loopback and LAN reach each other with no infrastructure (ADR-0089). */
	iceServers?: RTCIceServer[];
}

type RemoteDescriptionState = "pending" | "installing" | "installed" | "failed" | "closed";

interface IceCandidateSnapshot {
	readonly candidate: RTCIceCandidateInit;
	readonly textBytes: number;
}

interface PendingRemoteCandidate extends IceCandidateSnapshot {
	readonly resolve: () => void;
	readonly reject: (reason?: unknown) => void;
}

function snapshotCandidate(value: unknown): IceCandidateSnapshot {
	if (value == null || typeof value !== "object") {
		throw new TypeError("webrtc: ICE candidate must be an object");
	}
	const snapshot: RTCIceCandidateInit = {};
	let textBytes = 0;
	for (const field of ["candidate", "sdpMid", "usernameFragment"] as const) {
		const text: unknown = Reflect.get(value, field);
		if (text == null) continue;
		if (typeof text !== "string") {
			throw new TypeError(`webrtc: ICE candidate ${field} must be a string or null`);
		}
		textBytes += utf8ByteLengthUpTo(text, MAX_ICE_CANDIDATE_BYTES - textBytes);
		if (textBytes > MAX_ICE_CANDIDATE_BYTES) {
			throw new Error("webrtc: ICE candidate is too large");
		}
		snapshot[field] = text;
	}
	const line: unknown = Reflect.get(value, "sdpMLineIndex");
	if (line != null) {
		if (typeof line !== "number" || !Number.isInteger(line) || line < 0 || line > 0xffff) {
			throw new TypeError(
				"webrtc: ICE candidate sdpMLineIndex must be an unsigned short or null",
			);
		}
		snapshot.sdpMLineIndex = line;
	}
	return { candidate: snapshot, textBytes };
}

export class RtcPeer {
	readonly #pc: RTCPeerConnection;
	#dc: RTCDataChannel | null = null;
	#channel: Channel | null = null;
	readonly #open: Promise<void>;
	#markOpen!: () => void;
	#markOpenFailed!: (reason: unknown) => void;
	#openSettled = false;
	readonly #pendingLocal: RTCIceCandidateInit[] = [];
	#pendingLocalBytes = 0;
	#candidateSink: ((candidate: RTCIceCandidateInit) => void) | null = null;
	#remoteDescriptionState: RemoteDescriptionState = "pending";
	#remoteDescriptionFailure: unknown = null;
	readonly #pendingRemote: PendingRemoteCandidate[] = [];
	#remoteCandidateCount = 0;
	#remoteCandidateBytes = 0;
	#remoteCandidateTail: Promise<void> = Promise.resolve();

	constructor(init: RtcPeerInit) {
		this.#pc = new RTCPeerConnection({ iceServers: init.iceServers ?? [] });
		this.#open = new Promise((resolve, reject) => {
			this.#markOpen = () => {
				if (this.#openSettled) return;
				this.#openSettled = true;
				resolve();
			};
			this.#markOpenFailed = (reason) => {
				if (this.#openSettled) return;
				this.#openSettled = true;
				reject(reason);
			};
		});
		void this.#open.catch(() => {});
		this.#pc.onicecandidate = (event) => {
			if (!event.candidate) return;
			let queued: IceCandidateSnapshot;
			try {
				queued = snapshotCandidate(event.candidate.toJSON());
			} catch (error) {
				this.#closeWithError(error);
				return;
			}
			if (this.#candidateSink) {
				this.#candidateSink(queued.candidate);
				return;
			}
			if (
				this.#pendingLocal.length >= MAX_PENDING_ICE_CANDIDATES ||
				this.#pendingLocalBytes + queued.textBytes > MAX_PENDING_ICE_CANDIDATE_BYTES
			) {
				this.#closeWithError(new Error("webrtc: too many pending local ICE candidates"));
				return;
			}
			this.#pendingLocal.push(queued.candidate);
			this.#pendingLocalBytes += queued.textBytes;
		};
		// The ICE agent's terminal verdict. Without this, two peers with no
		// route to each other (no reachable STUN or TURN, different networks)
		// never open a channel and never fail one either: `waitOpen` simply
		// hangs, and every caller above it hangs with it. "failed" is the one
		// state that cannot recover, so it closes the peer with a reason a
		// person can act on; "disconnected" can still repair itself and is
		// deliberately not treated as an ending.
		this.#pc.onconnectionstatechange = () => {
			if (this.#pc.connectionState !== "failed") return;
			this.#closeWithError(
				new Error(
					"webrtc: the peers found no route to each other (ICE failed); " +
						"without a reachable STUN or TURN server, only peers on the same network can connect",
				),
			);
		};
		if (init.offerer) {
			this.#wireChannel(this.#pc.createDataChannel(CHANNEL_LABEL, { ordered: true }));
		} else {
			this.#pc.ondatachannel = (event) => this.#wireChannel(event.channel);
		}
	}

	#wireChannel(dc: RTCDataChannel): void {
		const unreliable = dc.maxPacketLifeTime != null || dc.maxRetransmits != null;
		if (dc.label !== CHANNEL_LABEL || this.#dc != null || !dc.ordered || unreliable) {
			dc.close();
			this.#closeWithError(new Error("webrtc: expected exactly one reliable ordered ocapn data channel"));
			return;
		}
		this.#dc = dc;
		this.#channel = rtcChannel(dc);
		if (dc.readyState === "open") this.#markOpen();
		else dc.addEventListener("open", () => this.#markOpen(), { once: true });
		dc.addEventListener(
			"close",
			() => this.#markOpenFailed(new Error("webrtc: data channel closed before opening")),
			{ once: true },
		);
		dc.addEventListener(
			"error",
			() => this.#markOpenFailed(new Error("webrtc: data channel failed before opening")),
			{ once: true },
		);
	}

	/** Produce the SDP offer and set it as the local description. Offerer only. */
	async createOffer(): Promise<string> {
		const offer = await this.#pc.createOffer();
		const sdp = assertSignalBytes("SDP", offer.sdp ?? "");
		await this.#pc.setLocalDescription(offer);
		return sdp;
	}

	/** Produce the SDP answer and set it as the local description. Answerer only,
	 * after `setRemoteOffer`. */
	async createAnswer(): Promise<string> {
		const answer = await this.#pc.createAnswer();
		const sdp = assertSignalBytes("SDP", answer.sdp ?? "");
		await this.#pc.setLocalDescription(answer);
		return sdp;
	}

	/** Set the far offerer's SDP offer as the remote description. Answerer side. */
	setRemoteOffer(sdp: string): Promise<void> {
		return this.#setRemoteDescription({ type: "offer", sdp: assertSignalBytes("SDP", sdp) });
	}

	/** Set the far answerer's SDP answer as the remote description. Offerer side. */
	setRemoteAnswer(sdp: string): Promise<void> {
		return this.#setRemoteDescription({ type: "answer", sdp: assertSignalBytes("SDP", sdp) });
	}

	/** Add one ICE candidate the far peer gathered. Candidates that arrive before
	 * remote SDP are retained and applied in arrival order after installation. */
	addRemoteCandidate(candidate: unknown): Promise<void> {
		if (
			this.#remoteDescriptionState === "failed" ||
			this.#remoteDescriptionState === "closed"
		) {
			return Promise.reject(this.#remoteDescriptionFailure);
		}
		let queued: IceCandidateSnapshot;
		try {
			queued = this.#reserveRemoteCandidate(candidate);
		} catch (error) {
			return Promise.reject(error);
		}
		if (this.#remoteDescriptionState === "installed") {
			return this.#enqueueRemoteCandidate(queued);
		}
		return new Promise((resolve, reject) => {
			this.#pendingRemote.push({ ...queued, resolve, reject });
		});
	}

	#reserveRemoteCandidate(candidate: unknown): IceCandidateSnapshot {
		const queued = snapshotCandidate(candidate);
		if (
			this.#remoteCandidateCount >= MAX_PENDING_ICE_CANDIDATES ||
			this.#remoteCandidateBytes + queued.textBytes > MAX_PENDING_ICE_CANDIDATE_BYTES
		) {
			throw new Error("webrtc: too many pending ICE candidates");
		}
		this.#remoteCandidateCount++;
		this.#remoteCandidateBytes += queued.textBytes;
		return queued;
	}

	#releaseRemoteCandidate(candidate: IceCandidateSnapshot): void {
		this.#remoteCandidateCount--;
		this.#remoteCandidateBytes -= candidate.textBytes;
	}

	async #setRemoteDescription(description: RTCSessionDescriptionInit): Promise<void> {
		if (this.#remoteDescriptionState !== "pending") {
			throw new Error("webrtc: remote description already started");
		}
		this.#remoteDescriptionState = "installing";
		try {
			await this.#pc.setRemoteDescription(description);
		} catch (error) {
			this.#failRemoteDescription(error);
			throw error;
		}
		if (this.#remoteDescriptionState !== "installing") {
			throw this.#remoteDescriptionFailure;
		}

		this.#remoteDescriptionState = "installed";
		const flushes = this.#pendingRemote.splice(0).map((pending) => {
			const applied = this.#enqueueRemoteCandidate(pending);
			applied.then(pending.resolve, pending.reject);
			return applied;
		});
		const results = await Promise.allSettled(flushes);
		const failed = results.find(
			(result): result is PromiseRejectedResult => result.status === "rejected",
		);
		if (failed != null) throw failed.reason;
	}

	#enqueueRemoteCandidate(candidate: IceCandidateSnapshot): Promise<void> {
		const applied = this.#remoteCandidateTail.then(() => this.#pc.addIceCandidate(candidate.candidate));
		const completed = applied.finally(() => this.#releaseRemoteCandidate(candidate));
		// A rejected candidate is reported to its own caller but does not strand
		// later candidates that are independently valid.
		this.#remoteCandidateTail = completed.catch(() => {});
		return completed;
	}

	#failRemoteDescription(error: unknown): void {
		this.#remoteDescriptionState = "failed";
		this.#remoteDescriptionFailure = error;
		for (const pending of this.#pendingRemote.splice(0)) {
			this.#releaseRemoteCandidate(pending);
			pending.reject(error);
		}
	}

	/** Register a sink for locally gathered ICE candidates, flushing any already
	 * gathered. The caller ferries each to the far peer through signaling. */
	onLocalCandidate(sink: (candidate: RTCIceCandidateInit) => void): void {
		this.#candidateSink = sink;
		const pending = this.#pendingLocal.splice(0);
		this.#pendingLocalBytes = 0;
		for (const candidate of pending) sink(candidate);
	}

	/** Resolves when the data channel opens. */
	waitOpen(): Promise<void> {
		return this.#open;
	}

	/** The open channel a keyed session runs over. Call after `waitOpen`
	 * reports the DataChannel open. */
	channel(): Channel {
		if (!this.#channel) throw new Error("webrtc: data channel not established");
		return this.#channel;
	}

	/** Close the peer connection and its channel. Idempotent. */
	close(): void {
		this.#closeWithError(new Error("webrtc: peer closed"));
	}

	#closeWithError(closed: unknown): void {
		if (this.#remoteDescriptionState === "closed") return;
		if (
			this.#remoteDescriptionState === "pending" ||
			this.#remoteDescriptionState === "installing"
		) {
			this.#failRemoteDescription(closed);
		} else {
			this.#remoteDescriptionFailure = closed;
		}
		this.#remoteDescriptionState = "closed";
		this.#pendingLocal.length = 0;
		this.#pendingLocalBytes = 0;
		this.#candidateSink = null;
		this.#markOpenFailed(closed);
		this.#pc.close();
	}
}
