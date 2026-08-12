/// <reference lib="dom" />

// The two browser halves of room-carried WebRTC signaling (ADR-0089). The
// directory routes offers, answers, and candidates between members
// (`server/main.ts`); `Directory` carries the verbs; this module is where an
// `RtcPeer` meets them, so it is the one rooms-lib file that touches WebRTC
// and it loads only in a browser.
//
// The dialing half is not here: a member reaches a `webrtc` peer by giving its
// `Host` the `directorySignalingAuthority` below and dialing the bare locator
// — the stack's dial executor owns the bring-up (`Host.setSignaling`).

import {
	Session,
	type SignalingAuthority,
	SignalingSendOwner,
	TRANSPORT_WEBRTC,
} from "@pancake/stack";
import { RtcPeer } from "@pancake/webrtc";
import { DESIGNATOR_SCHEME_KEY } from "@pancake/abi";
import { SIG_CANDIDATE, SIG_OFFER } from "./protocol.ts";
import type { Directory } from "./room_client.ts";

const MAX_PENDING_OFFERS = 32;
const SIGNALING_OPEN_TIMEOUT_MS = 30_000;

export interface WebrtcSignalingServer {
	close(): Promise<void>;
}

/** The dialing host's signaling authority, over the room directory: offers and
 * candidates ride directory verbs, and the answer and far candidates ride the
 * reply capability `Directory.signalOffer` spawns. Give it to
 * `Host.setSignaling`; the `dir` thunk keeps it valid across reconnects. */
export function directorySignalingAuthority(
	dir: () => Directory | null,
): SignalingAuthority {
	const need = (): Directory => {
		const d = dir();
		if (d === null) throw new Error("rooms: no directory session to signal through");
		return d;
	};
	return {
		offer: (designator, sdp) => need().signalOffer(designator, sdp),
		candidate: (designator, ice) => need().signalCandidate(designator, ice),
		onCandidate: (designator, sink) => need().onSignalCandidate(designator, sink),
	};
}

/** Answer inbound WebRTC offers for `host`: mint the signaling inbox, file it
 * with the directory (`offerSignaling`), and for each offer bring the channel
 * up with an answering `RtcPeer`, then accept the keyed session over it and
 * serve `host`'s giftables. Call after this member's registration is granted,
 * and again after a reconnect (the inbox lives on the directory session).
 * Returns the accept loop's sessions through `onError` only when they fail. */
export async function serveWebrtcSignaling(opts: {
	host: import("@pancake/stack").Host;
	dir: () => Directory | null;
	onError?: (err: unknown) => void;
}): Promise<WebrtcSignalingServer> {
	const onError = opts.onError ?? (() => {});
	const d = opts.dir();
	if (d === null) throw new Error("rooms: no directory session to offer signaling on");
	// One answering peer per live exchange, keyed by the directory's exchange id.
	const peers = new Map<string, RtcPeer>();
	const tasks = new Set<Promise<void>>();
	let accepting = true;
	let closePromise: Promise<void> | null = null;

	const waitOpen = async (peer: RtcPeer): Promise<void> => {
		let timer: ReturnType<typeof setTimeout> | null = null;
		const timeout = new Promise<never>((_resolve, reject) => {
			timer = setTimeout(
				() => reject(new Error("rooms: WebRTC signaling timed out")),
				SIGNALING_OPEN_TIMEOUT_MS,
			);
		});
		try {
			await Promise.race([peer.waitOpen(), timeout]);
		} finally {
			if (timer != null) clearTimeout(timer);
		}
	};

	const answerOffer = async (id: string, sdp: string): Promise<void> => {
		const peer = new RtcPeer({ offerer: false });
		const candidateSends = new SignalingSendOwner("rooms WebRTC answer", () => peer.close());
		peers.set(id, peer);
		try {
			peer.onLocalCandidate((candidate) =>
				candidateSends.admit(() => d.signalCandidate(id, JSON.stringify(candidate)))
			);
			await peer.setRemoteOffer(sdp);
			await d.signalAnswer(id, await peer.createAnswer());
			await waitOpen(peer);
			candidateSends.stopAdmission();
			await candidateSends.join();
			if (candidateSends.failure != null) throw candidateSends.failure;
			const session = await Session.establishAccepted(
				opts.host,
				{
					transport: TRANSPORT_WEBRTC,
					designatorScheme: DESIGNATOR_SCHEME_KEY,
					serverDesignator: opts.host.designator(),
					channel: peer.channel(),
				},
			);
			peers.delete(id);
			void session.serve().catch(onError);
		} catch (err) {
			peers.delete(id);
			peer.close();
			candidateSends.stopAdmission();
			await candidateSends.join();
			onError(err);
		}
	};
	const startOffer = (id: string, sdp: string): void => {
		if (!accepting) return;
		if (id.length === 0 || peers.has(id)) {
			onError(new Error("rooms: invalid or duplicate WebRTC signaling exchange"));
			return;
		}
		if (tasks.size >= MAX_PENDING_OFFERS) {
			onError(new Error("rooms: too many pending WebRTC signaling exchanges"));
			return;
		}
		const task = answerOffer(id, sdp);
		tasks.add(task);
		const retire = (): void => {
			tasks.delete(task);
		};
		task.then(retire, retire);
	};
	const inbox = d.session.spawn((verb, args) => {
		const id = typeof args[0] === "string" ? args[0] : "";
		const payload = typeof args[1] === "string" ? args[1] : "";
		if (verb === SIG_OFFER) {
			startOffer(id, payload);
			return null;
		}
		if (verb === SIG_CANDIDATE) {
			try {
				const candidate: unknown = JSON.parse(payload);
				void peers.get(id)?.addRemoteCandidate(candidate).catch(() => {
					// A late, duplicate, or malformed candidate cannot revive an exchange.
				});
			} catch (error) {
				onError(error);
			}
			return null;
		}
		throw new Error(`signaling inbox has no method ${verb}`);
	});
	await d.offerSignaling(inbox);
	return {
		close(): Promise<void> {
			if (closePromise != null) return closePromise;
			accepting = false;
			for (const peer of peers.values()) peer.close();
			peers.clear();
			closePromise = Promise.allSettled([...tasks]).then(() => {});
			return closePromise;
		},
	};
}
