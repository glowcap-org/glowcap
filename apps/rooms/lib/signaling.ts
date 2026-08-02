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

import { Session, type SignalingAuthority, TRANSPORT_WEBRTC } from "@pancake/stack";
import { RtcPeer } from "@pancake/webrtc";
import { SIG_CANDIDATE, SIG_OFFER } from "./protocol.ts";
import type { Directory } from "./room_client.ts";

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
}): Promise<void> {
	const onError = opts.onError ?? (() => {});
	const d = opts.dir();
	if (d === null) throw new Error("rooms: no directory session to offer signaling on");
	// One answering peer per live exchange, keyed by the directory's exchange id.
	const peers = new Map<string, RtcPeer>();
	const answerOffer = async (id: string, sdp: string): Promise<void> => {
		const peer = new RtcPeer({ offerer: false });
		peers.set(id, peer);
		try {
			peer.onLocalCandidate((candidate) => {
				d.signalCandidate(id, JSON.stringify(candidate));
			});
			await peer.setRemoteOffer(sdp);
			d.signalAnswer(id, await peer.createAnswer());
			await peer.waitOpen();
			const session = await Session.establishAccepted(
				opts.host,
				TRANSPORT_WEBRTC,
				opts.host.designator(),
				peer.channel(),
			);
			peers.delete(id);
			await session.serve();
		} catch (err) {
			peers.delete(id);
			peer.close();
			onError(err);
		}
	};
	const inbox = d.session.spawn((verb, args) => {
		const id = typeof args[0] === "string" ? args[0] : "";
		const payload = typeof args[1] === "string" ? args[1] : "";
		if (verb === SIG_OFFER) {
			// The bring-up is async and behaviors are sync: kick it off and return.
			void answerOffer(id, payload);
			return null;
		}
		if (verb === SIG_CANDIDATE) {
			void peers.get(id)?.addRemoteCandidate(JSON.parse(payload)).catch(() => {
				// A late or duplicate candidate is harmless.
			});
			return null;
		}
		throw new Error(`signaling inbox has no method ${verb}`);
	});
	await d.offerSignaling(inbox);
}
