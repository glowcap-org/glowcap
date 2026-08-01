/// <reference lib="dom" />

// One browser peer for the WebRTC browser-to-browser proof (ADR-0089 phase 6).
// Two browser tabs run this, one as `?role=offerer` and one as `?role=answerer`.
// Each bundles `@pancake/web` (the wasm Host) and `@pancake/webrtc` (`RtcPeer`),
// exchanges signaling through the harness's WebSocket relay, and once the direct
// DataChannel opens holds a keyed OCapN session over it: the answerer publishes a
// greeter and accepts, the offerer dials the answerer's key and greets. The
// signaling relay only moves opaque strings between the two tabs; the keyed
// session and its DTLS run end to end over the DataChannel, so the relay is out
// of the byte path. Two browsers speak directly, the signaling host blind to
// what they say.
//
// The signaling relay stands in for the room capability a deployment uses (a
// room hosts the same offer/answer/candidate exchange, proven over CapTP by
// `webrtc-signaling-captp`); here it is a plain byte relay so the proof is
// deno-only and needs no room.

import { init } from "@pancake/web";
import { RtcPeer } from "@pancake/webrtc";

const GREETING = "hello browser to browser over webrtc";

interface Signal {
	type: string;
	sdp?: string;
	designator?: string;
	candidate?: RTCIceCandidateInit;
}

// Declared as a global rather than on `Window`: this module reaches it through
// `globalThis`, and only a global `var` is visible on that type.
declare global {
	var __verdict: Promise<{ ok: boolean; reason?: string }>;
}

const params = new URLSearchParams(location.search);
const offerer = params.get("role") === "offerer";

const status = (s: string): void => {
	const el = document.getElementById("status");
	if (el) el.textContent = s;
};

let resolveVerdict!: (v: { ok: boolean; reason?: string }) => void;
globalThis.__verdict = new Promise((res) => (resolveVerdict = res));

let resolveRemoteId!: (designator: string) => void;
const remoteId = new Promise<string>((res) => (resolveRemoteId = res));

async function main(): Promise<void> {
	const stack = await init({ wasm: fetch("/pancake_host.wasm") });
	const host = new stack.Host();
	const myDesignator = host.designator();
	const peer = new RtcPeer({ offerer });

	const ws = new WebSocket(
		`ws://${location.host}/signal?role=${offerer ? "offerer" : "answerer"}`,
	);
	const send = (m: Signal): void => ws.send(JSON.stringify(m));
	await new Promise<void>((res, rej) => {
		ws.addEventListener("open", () => res(), { once: true });
		ws.addEventListener("error", () => rej(new Error("signaling WebSocket failed")), {
			once: true,
		});
	});

	peer.onLocalCandidate((candidate) => send({ type: "candidate", candidate }));

	ws.onmessage = async (ev: MessageEvent) => {
		const m = JSON.parse(ev.data as string) as Signal;
		if (m.type === "identity" && m.designator) {
			resolveRemoteId(m.designator);
		} else if (m.type === "offer" && m.sdp) {
			await peer.setRemoteOffer(m.sdp);
			send({ type: "answer", sdp: await peer.createAnswer() });
		} else if (m.type === "answer" && m.sdp) {
			await peer.setRemoteAnswer(m.sdp);
		} else if (m.type === "candidate" && m.candidate) {
			try {
				await peer.addRemoteCandidate(m.candidate);
			} catch {
				// A late or duplicate candidate is harmless.
			}
		}
	};

	if (offerer) {
		// Wait for the answerer's key before offering, so its identity is pinned
		// for the keyed dial and the offer never races an absent answerer.
		const designator = await remoteId;
		send({ type: "offer", sdp: await peer.createOffer() });
		await peer.waitOpen();
		status("channel open");

		const session = await stack.Session.establishDialedLocator(
			host,
			"webrtc",
			designator,
			peer.channel(),
		);
		session.serve().catch(() => {});
		try {
			const greeter = await session.fetch("greeter");
			const reply = await session.send(greeter, "greet", []);
			resolveVerdict({ ok: reply === GREETING, reason: String(reply) });
		} finally {
			session.close();
		}
	} else {
		// The answerer announces its keyed identity and publishes the greeter, then
		// accepts the keyed session over the DataChannel and serves.
		host.publishGiftable("greeter", (verb) => (verb === "greet" ? GREETING : null));
		send({ type: "identity", designator: myDesignator });
		await peer.waitOpen();
		status("channel open");

		const session = await stack.Session.establishAccepted(
			host,
			"webrtc",
			myDesignator,
			peer.channel(),
		);
		resolveVerdict({ ok: true, reason: "accepted" });
		await session.serve();
	}
}

main().catch((e) => resolveVerdict({ ok: false, reason: e?.message ?? String(e) }));
