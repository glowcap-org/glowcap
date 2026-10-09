/// <reference lib="dom" />

// One browser peer for the WebRTC browser-to-browser proof (ADR-0089 phase 6).
// Two browser tabs run this, one as `?role=offerer` and one as `?role=answerer`.
// Each bundles `@glowcap/web` (the wasm Host); the answerer drives
// `@glowcap/webrtc` (`RtcPeer`) directly, while the offerer opens a managed
// Runtime with the WebRTC connector and dials the bare
// `ocapn://<key>.webrtc` locator, so the dial executor owns the whole bring-up
// — offer, answer, trickled candidates, channel adoption, keyed handshake. The signaling relay only
// moves opaque strings between the two tabs; the keyed session and its DTLS
// run end to end over the DataChannel, so the relay is out of the byte path.
// Two browsers speak directly, the signaling host blind to what they say.
//
// The signaling relay stands in for the room capability a deployment uses (a
// room hosts the same offer/answer/candidate exchange, proven over CapTP by
// `webrtc-signaling-captp`); here it is a plain byte relay so the proof is
// deno-only and needs no room.

import { init } from "@glowcap/web";
import { connector, locator, RtcPeer } from "@glowcap/webrtc";
import { DESIGNATOR_SCHEME_KEY } from "@glowcap/abi";

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
	const stack = await init({ wasm: fetch("/glowcap_host.wasm") });

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

	if (offerer) {
		// The dial executor drives the bring-up, so this side holds no RtcPeer.
		// The WebSocket becomes the connector's signaling authority: the offer rides
		// out and resolves with the answer, candidates trickle both ways, and the
		// answerer's identity pins the keyed dial.
		let resolveAnswer!: (sdp: string) => void;
		const answerSdp = new Promise<string>((res) => (resolveAnswer = res));
		let remoteCandidates: ((ice: string) => void) | null = null;
		ws.onmessage = (ev: MessageEvent) => {
			const m = JSON.parse(ev.data as string) as Signal;
			if (m.type === "identity" && m.designator) resolveRemoteId(m.designator);
			else if (m.type === "answer" && m.sdp) resolveAnswer(m.sdp);
			else if (m.type === "candidate" && m.candidate) {
				remoteCandidates?.(JSON.stringify(m.candidate));
			}
		};
		const runtime = await stack.openRuntime({
			connectors: [
				connector({
					offer(_to, sdp) {
						send({ type: "offer", sdp });
						return answerSdp;
					},
					candidate(_to, ice) {
						send({
							type: "candidate",
							candidate: JSON.parse(ice) as RTCIceCandidateInit,
						});
					},
					onCandidate(_to, sink) {
						remoteCandidates = sink;
						return () => {
							remoteCandidates = null;
						};
					},
				}),
			],
		});

		// Wait for the answerer's key before dialing, so its identity is pinned
		// for the keyed dial and the offer never races an absent answerer.
		const designator = await remoteId;
		const session = await runtime.connect(locator(designator));
		status("channel open");
		session.serve().catch(() => {});
		try {
			const greeter = await session.fetch("greeter");
			const reply = await session.send(greeter, "greet", []);
			resolveVerdict({ ok: reply === GREETING, reason: String(reply) });
		} finally {
			session.close();
			await runtime.close();
		}
	} else {
		// The answerer announces its keyed identity and publishes the greeter, then
		// accepts the keyed session over the DataChannel and serves.
		const host = stack.host;
		const myDesignator = host.designator();
		const peer = new RtcPeer({ offerer: false });
		peer.onLocalCandidate((candidate) => send({ type: "candidate", candidate }));
		ws.onmessage = async (ev: MessageEvent) => {
			const m = JSON.parse(ev.data as string) as Signal;
			if (m.type === "offer" && m.sdp) {
				await peer.setRemoteOffer(m.sdp);
				send({ type: "answer", sdp: await peer.createAnswer() });
			} else if (m.type === "candidate" && m.candidate) {
				try {
					await peer.addRemoteCandidate(m.candidate);
				} catch {
					// A late or duplicate candidate is harmless.
				}
			}
		};
		host.publish("greeter", (verb) => (verb === "greet" ? GREETING : null));
		send({ type: "identity", designator: myDesignator });
		await peer.waitOpen();
		status("channel open");

		const session = await stack.Session.establishAccepted(
			host,
			{
				transport: "webrtc",
				designatorScheme: DESIGNATOR_SCHEME_KEY,
				serverDesignator: myDesignator,
				channel: peer.channel(),
			},
		);
		resolveVerdict({ ok: true, reason: "accepted" });
		await session.serve();
	}
}

main().catch((e) => resolveVerdict({ ok: false, reason: e?.message ?? String(e) }));
