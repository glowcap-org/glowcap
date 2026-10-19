/// <reference lib="dom" />

// One browser peer for the WebRTC browser-to-browser proof (ADR-0035).
// Two browser tabs run this, one as `?role=offerer` and one as
// `?role=answerer`. Each bundles `@glowcap/web` (the wasm Host). The offerer
// opens a Runtime with the WebRTC connector and dials the answerer's bare
// `ocapn://<key>.webrtc` locator. The answerer runs the WebRTC listener, hands
// it the offer with the offerer's key, and serves the session it accepts. The
// library drives both sides: offer, answer, trickled candidates, and the keyed
// handshake over the DataChannel. The signaling relay moves opaque strings
// between the tabs and stays out of the byte path.
//
// The relay stands in for the room a deployment signals through (the room
// carries the same exchange over CapTP in `webrtc-signaling-captp`), so this
// proof needs only deno.

import { init } from "@glowcap/web";
import { connector, listener, locator } from "@glowcap/webrtc";

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
		// The Runtime runs its own Host, and the offer names that Host's key.
		let ownKey = "";
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
					offer(_exchange, _to, sdp) {
						send({ type: "offer", sdp, designator: ownKey });
						return answerSdp;
					},
					candidate(_exchange, ice) {
						send({
							type: "candidate",
							candidate: JSON.parse(ice) as RTCIceCandidateInit,
						});
					},
					onCandidate(_exchange, _to, sink) {
						remoteCandidates = sink;
						return () => {
							remoteCandidates = null;
						};
					},
				}),
			],
		});
		ownKey = runtime.host.designator();

		// Wait for the answerer's key before dialing, so its identity is pinned
		// for the keyed dial and the offer never races an absent answerer.
		const designator = await remoteId;
		const session = await runtime.connect(locator(designator));
		status("channel open");
		// tolerant: serve rejects when the partner hangs up, which ends the probe's session normally, and the probe's own calls report real failures.
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
		// The answerer announces its key and publishes the greeter. The listener
		// answers the offer it is handed and yields the session once the channel
		// opens, pinned to the key the offer named.
		const host = stack.host;
		let remoteCandidates: ((ice: string) => void) | null = null;
		const answering = listener(host, {
			answer(_exchange, _to, sdp) {
				send({ type: "answer", sdp });
			},
			candidate(_exchange, ice) {
				send({ type: "candidate", candidate: JSON.parse(ice) as RTCIceCandidateInit });
			},
			onCandidate(_exchange, _to, sink) {
				remoteCandidates = sink;
				return () => {
					remoteCandidates = null;
				};
			},
		});
		let offererKey = "";
		ws.onmessage = (ev: MessageEvent) => {
			const m = JSON.parse(ev.data as string) as Signal;
			if (m.type === "offer" && m.sdp && m.designator) {
				offererKey = m.designator;
				answering.provideOffer(m.designator, m.sdp);
			} else if (m.type === "candidate" && m.candidate) {
				remoteCandidates?.(JSON.stringify(m.candidate));
			}
		};
		host.publish("greeter", (verb) => (verb === "greet" ? GREETING : null));
		send({ type: "identity", designator: answering.designator });

		const { value: session, done } = await answering[Symbol.asyncIterator]().next();
		if (done) throw new Error("the listener closed before a session arrived");
		status("channel open");
		const partner = session.partnerIdentity();
		if (partner.designator !== offererKey || partner.provenance !== "authenticated-transport") {
			throw new Error(
				`the accepted session names ${partner.designator} (${partner.provenance}), not the offerer ${offererKey}`,
			);
		}
		resolveVerdict({ ok: true, reason: "accepted" });
		await session.serve();
	}
}

main().catch((e) => resolveVerdict({ ok: false, reason: e?.message ?? String(e) }));
