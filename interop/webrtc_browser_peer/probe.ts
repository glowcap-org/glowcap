/// <reference lib="dom" />

// The browser offerer for the WebRTC browser-peer proof (ADR-0089 phase 6). A
// real headless Chromium bundles this: `@pancake/web`'s wasm Host plus
// `@pancake/webrtc`'s `RtcPeer`. It brings up a DataChannel to the native
// answerer (`interop/webrtc_browser_peer/answerer.zig`) through the harness's
// stdio signaling ferry, then runs a full keyed OCapN session over that channel
// — fetch the answerer's `greeter`, call `greet`, and check the reply. This is
// the browser twin of `webrtc-interop` (two native peers): here one end is a
// browser tab driving the protocol core in wasm, with the DataChannel standing
// in for the WebSocket the relay path uses.
//
// Signaling rides two harness seams: `window.harnessSignal(json)` carries a line
// out to the answerer's stdin, and the harness feeds inbound lines to
// `window.applySignal(json)`. The answerer announces its key designator first
// (`identity`), which this peer pins for the keyed dial, so the handshake proves
// the answerer's identity end to end.

import { init } from "@pancake/web";
import { RtcPeer } from "@pancake/webrtc";

const GREETING = "hello over webrtc";

interface Signal {
	type: string;
	sdp?: string;
	designator?: string;
	candidate?: RTCIceCandidateInit;
}

declare global {
	interface Window {
		harnessSignal: (line: string) => void;
		applySignal: (line: string) => Promise<void>;
		__verdict: Promise<{ ok: boolean; reason?: string }>;
	}
}

const status = (s: string): void => {
	const el = document.getElementById("status");
	if (el) el.textContent = s;
};

let resolveVerdict!: (v: { ok: boolean; reason?: string }) => void;
window.__verdict = new Promise((res) => (resolveVerdict = res));

let resolveIdentity!: (designator: string) => void;
const identity = new Promise<string>((res) => (resolveIdentity = res));

// Register a buffering `applySignal` synchronously, before `init` resolves: the
// answerer announces its identity first, so a line delivered before the peer is
// wired queues here rather than being lost, and `main` drains it.
const buffered: string[] = [];
let deliver: (line: string) => void = (line) => buffered.push(line);
window.applySignal = (line: string): Promise<void> => {
	deliver(line);
	return Promise.resolve();
};

async function main(): Promise<void> {
	const stack = await init({ wasm: fetch("/pancake_driver.wasm") });
	const peer = new RtcPeer({ offerer: true });

	// Inbound signaling from the answerer, fed in by the harness.
	const apply = async (line: string): Promise<void> => {
		const m = JSON.parse(line) as Signal;
		if (m.type === "identity" && m.designator) {
			resolveIdentity(m.designator);
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
	deliver = (line) => void apply(line);
	for (const line of buffered.splice(0)) deliver(line);

	peer.onLocalCandidate((candidate) =>
		window.harnessSignal(JSON.stringify({ type: "candidate", candidate }))
	);

	const offer = await peer.createOffer();
	window.harnessSignal(JSON.stringify({ type: "offer", sdp: offer }));
	status("offer sent");

	const designator = await identity;
	await peer.waitOpen();
	status("channel open");

	// The keyed OCapN session runs over the DataChannel exactly as it would over
	// the relay's WebSocket: the transport is `webrtc`, the pinned key is the
	// answerer's designator, and the byte channel is the open DataChannel.
	const channel = peer.channel();
	const session = await stack.Session.establishDialedLocator(
		new stack.Host(),
		"webrtc",
		designator,
		channel,
	);
	session.serve().catch(() => {});
	try {
		const greeter = await session.fetch("greeter");
		const reply = await session.send(greeter, "greet", []);
		resolveVerdict({ ok: reply === GREETING, reason: String(reply) });
	} finally {
		session.close();
	}
}

main().catch((e) => resolveVerdict({ ok: false, reason: e?.message ?? String(e) }));
