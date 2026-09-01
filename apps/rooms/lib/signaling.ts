/// <reference lib="dom" />

// The two browser halves of room-carried WebRTC signaling (ADR-0089). The
// directory routes offers, answers, and candidates between members
// (`server/main.ts`); `Directory` carries the verbs; this module is where an
// `RtcPeer` meets them, so it is the one rooms-lib file that touches WebRTC
// and it loads only in a browser.
//
// The dialing half is not here: a member reaches a `webrtc` peer by installing
// `webrtc.connector` over the `directorySignalingAuthority` below and dialing
// the bare locator — the connector owns the bring-up (`@pancake/webrtc`).

import { retainCleanupFailures, Session, SignalingSendOwner, TRANSPORT_WEBRTC } from "@pancake/runtime";
import { RtcPeer, type SignalingAuthority } from "@pancake/webrtc";
import { DESIGNATOR_SCHEME_KEY } from "@pancake/abi";
import { SIG_CANDIDATE, SIG_OFFER } from "./protocol.ts";
import { relayedSignalFits } from "./limits.ts";
import { type Directory, signalingRoute } from "./room/client.ts";
import { releaseUnclaimedCapabilityArguments } from "./argument_custody.ts";

const MAX_PENDING_OFFERS = 32;
const SIGNALING_OPEN_TIMEOUT_MS = 30_000;

export interface WebrtcSignalingServer {
	close(): Promise<void>;
}

/** The dialing host's signaling authority, over the room directory: offers and
 * candidates ride directory verbs, and the answer and far candidates ride the
 * reply capability `Directory.signalOffer` spawns. Give it to
 * `webrtc.connector`.
 *
 * Each exchange goes to the directory whose redeem raised the dial
 * (`signalingRoute`), because a `webrtc` locator names a designator and nothing
 * else: the connector cannot say which room vouched for the peer, and a tab
 * that joined somebody else's directory has more than one to choose from. The
 * three verbs of one exchange must reach the *same* directory — the row
 * carrying the answer and the far candidates lives on it — so the choice is
 * made when the connector first names a designator and held until it lets go.
 *
 * `alone` is the fallback for a dial raised outside any redeem: the one live
 * directory, or null where there are several and picking one would be a guess.
 * The thunk is read each time, so it survives a reconnect. */
export function directorySignalingAuthority(
	alone: () => Directory | null,
): SignalingAuthority {
	const routes = new Map<string, Directory>();
	const route = (designator: string): Directory => {
		const held = routes.get(designator);
		if (held !== undefined) return held;
		const chosen = signalingRoute() ?? alone();
		if (chosen === null) throw new Error("rooms: no directory session to signal through");
		routes.set(designator, chosen);
		return chosen;
	};
	return {
		offer: (designator, sdp) => route(designator).signalOffer(designator, sdp),
		candidate: (designator, ice) => route(designator).signalCandidate(designator, ice),
		onCandidate: (designator, sink) => {
			const dir = route(designator);
			let stop: () => void;
			try {
				stop = dir.onSignalCandidate(designator, sink);
			} catch (error) {
				// The exchange never started, so this choice must not outlive it: a
				// route left behind would send the next dial to this peer through a
				// directory the reader may have left in the meantime.
				if (routes.get(designator) === dir) routes.delete(designator);
				throw error;
			}
			return () => {
				try {
					stop();
				} finally {
					// The exchange is over, so the next dial to this peer chooses
					// again — they may be reachable through another room by then.
					if (routes.get(designator) === dir) routes.delete(designator);
				}
			};
		},
	};
}

/** Answer inbound WebRTC offers for `host`: mint the signaling inbox, file it
 * with the directory (`offerSignaling`), and for each offer bring the channel
 * up with an answering `RtcPeer`, then accept the keyed session over it and
 * serve `host`'s giftables. Call after this member's registration is granted,
 * and again after a reconnect (the inbox lives on the directory session).
 * Returns the accept loop's sessions through `onError` only when they fail. */
export async function serveWebrtcSignaling(opts: {
	host: import("@pancake/runtime").Host;
	dir: () => Directory | null;
	/** ICE servers this side answers through. It must match the reach the
	 * dialing side was given: a candidate one peer cannot produce is a path
	 * neither can use. */
	iceServers?: RTCIceServer[] | (() => Promise<RTCIceServer[]>);
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
		let configuredIce: RTCIceServer[] | undefined;
		try {
			configuredIce = typeof opts.iceServers === "function" ? await opts.iceServers() : opts.iceServers;
		} catch (err) {
			onError(err);
			return;
		}
		const peer = new RtcPeer({ offerer: false, iceServers: configuredIce });
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
		releaseUnclaimedCapabilityArguments(
			d.session,
			args,
			"the signaling inbox could not return an unexpected capability",
		);
		if (verb !== SIG_OFFER && verb !== SIG_CANDIDATE) {
			throw new Error(`signaling inbox has no method ${verb}`);
		}
		if (args.length !== 2 || typeof args[0] !== "string" || typeof args[1] !== "string") {
			throw new Error(`${verb} needs one exchange id and signaling payload`);
		}
		const [id, payload] = args;
		// A directory holds what it relays to a size, and a directory is whatever
		// answered the address somebody typed — so what arrives is held to the same
		// size here, before an exchange id becomes a key or a candidate is parsed.
		if (!relayedSignalFits(verb === SIG_OFFER ? "description" : "candidate", id, payload)) {
			throw new Error(`${verb} carries an invalid or oversized signaling payload`);
		}
		if (verb === SIG_OFFER) {
			startOffer(id, payload);
			return null;
		}
		try {
			const candidate: unknown = JSON.parse(payload);
			void peers.get(id)?.addRemoteCandidate(candidate).catch(() => {
				// A late, duplicate, or malformed candidate cannot revive an exchange.
			});
		} catch (error) {
			onError(error);
		}
		return null;
	});
	const latest = opts.dir();
	if (latest === null) {
		accepting = false;
		throw await retainCleanupFailures(new Error("rooms: no directory session to offer signaling on"), [
			() => d.session.release(inbox),
		]);
	}
	await latest.offerSignaling(inbox);
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
