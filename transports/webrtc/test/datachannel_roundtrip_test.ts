// Phase-1 de-risk proof for the WebRTC DataChannel netlayer (ADR-0089).
//
// A real headless Chromium is the browser peer (the offerer). It creates a
// reliable, ordered RTCDataChannel to the native Rust peer
// (`pancake-webrtc-datachannel-probe`, the answerer over the `webrtc` crate),
// and this harness ferries the signaling — the SDP offer/answer and trickled
// ICE candidates — between the two out of band, over the probe's stdio. That
// out-of-band exchange stands in for the OCapN signaling capability that ADR-0089
// phase 5 will carry; here it exists only to bring the channel up so the byte
// path itself can be proven.
//
// Once the DataChannel opens, the browser sends bytes and the native peer
// replies. The proof asserts BOTH directions: the native peer reports it
// received the browser's bytes (its `native_recv`/`result` line), and the
// browser reports it received the native peer's reply (its resolved verdict).
// This de-risks the whole transport in this environment — the `webrtc` crate,
// the browser RTCDataChannel API, ICE on loopback in a headless container, and
// the DTLS channel — before any Zig, C ABI, or engine integration exists.
//
// Signaling is relay-less: no STUN, no TURN. Both peers gather loopback/host
// candidates on the same host and connect directly. The native peer includes
// its loopback candidate (`set_include_loopback_candidate(true)`); Chromium is
// launched with mDNS host-candidate obfuscation disabled so its host candidates
// are raw IPs the native peer can reach.
//
// Needs deno, the probe binary (`zig build webrtc-lib`, or `cargo build
// --release` in transports/webrtc), and a Playwright Chromium
// (`npx playwright install chromium && sudo npx playwright install-deps`). Run
// directly: `deno run --allow-all transports/webrtc/test/datachannel_roundtrip_test.ts`.

import { chromium } from "npm:playwright@1.61.1";

const ROOT = new URL("../../../", import.meta.url).pathname;
const PROBE = `${ROOT}transports/webrtc/target/release/pancake-webrtc-datachannel-probe`;

const PING = "ping-from-browser";
const EXPECTED_REPLY = `pong-from-native:${PING}`;

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

function freePort(): number {
	const l = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (l.addr as Deno.NetAddr).port;
	l.close();
	return port;
}

// The browser peer, served same-origin over http://127.0.0.1 (localhost is a
// secure context, so RTCPeerConnection is available). It defines the offerer but
// does not run until the harness has wired signaling and calls startProbe().
const PAGE = `<!doctype html><meta charset=utf-8><title>webrtc datachannel probe</title>
<pre id=status>idle</pre>
<script>
const PING = ${JSON.stringify(PING)};
const EXPECTED_REPLY = ${JSON.stringify(EXPECTED_REPLY)};
let resolveVerdict;
window.__verdict = new Promise((res) => { resolveVerdict = res; });
const status = (s) => { document.getElementById("status").textContent = s; };

window.startProbe = async () => {
	const pc = new RTCPeerConnection({ iceServers: [] });
	const dc = pc.createDataChannel("captp", { ordered: true });
	dc.binaryType = "arraybuffer";

	pc.onicecandidate = (e) => {
		if (e.candidate) {
			window.harnessSignal(JSON.stringify({ type: "candidate", candidate: e.candidate.toJSON() }));
		}
	};
	pc.onconnectionstatechange = () => {
		status("pc:" + pc.connectionState);
		if (pc.connectionState === "failed") {
			resolveVerdict({ ok: false, reason: "connection failed" });
		}
	};

	// Signaling from the native peer, fed in by the harness.
	window.applySignal = async (line) => {
		const m = JSON.parse(line);
		if (m.type === "answer") {
			await pc.setRemoteDescription({ type: "answer", sdp: m.sdp });
		} else if (m.type === "candidate") {
			try {
				await pc.addIceCandidate(m.candidate);
			} catch (_e) {
				// A late or duplicate candidate is harmless.
			}
		}
	};

	dc.onopen = () => {
		status("channel open");
		dc.send(new TextEncoder().encode(PING));
	};
	dc.onmessage = (e) => {
		const text = new TextDecoder().decode(new Uint8Array(e.data));
		resolveVerdict({ ok: text === EXPECTED_REPLY, reason: text });
	};

	const offer = await pc.createOffer();
	await pc.setLocalDescription(offer);
	window.harnessSignal(JSON.stringify({ type: "offer", sdp: offer.sdp }));
	status("offer sent");
};
</script>`;

const deadline = setTimeout(() => fail("scenario timed out after 60s"), 60_000);

// The native peer: the webrtc-crate answerer. Piped stdio carries signaling.
const probe = new Deno.Command(PROBE, {
	stdin: "piped",
	stdout: "piped",
	stderr: "inherit",
}).spawn();
const probeIn = probe.stdin.getWriter();
const enc = new TextEncoder();
async function toProbe(line: string): Promise<void> {
	await probeIn.write(enc.encode(line + "\n"));
}

const pagePort = freePort();
const assetServer = new AbortController();
Deno.serve(
	{ port: pagePort, signal: assetServer.signal },
	() => new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } }),
);

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
let nativeReceived = false;
let nativeVerdict: boolean | null = null;

try {
	browser = await chromium.launch({
		args: [
			"--no-sandbox",
			// Force raw host-IP candidates instead of Chromium's privacy mDNS
			// (.local) names the native crate cannot resolve on loopback.
			"--disable-features=WebRtcHideLocalIpsWithMdns",
		],
	});
	const page = await browser.newPage();
	page.on("console", (m) => console.error("  [browser]", m.text()));
	page.on("pageerror", (e) => console.error("  [browser error]", e.message));

	// Pump the native peer's stdout: route signaling into the browser, record
	// the terminal lines.
	let nativeDone: () => void;
	const nativeSettled = new Promise<void>((res) => (nativeDone = res));
	(async () => {
		const dec = new TextDecoder();
		let buf = "";
		for await (const chunk of probe.stdout) {
			buf += dec.decode(chunk, { stream: true });
			let nl: number;
			while ((nl = buf.indexOf("\n")) >= 0) {
				const line = buf.slice(0, nl).trim();
				buf = buf.slice(nl + 1);
				if (!line) continue;
				let m: Record<string, unknown>;
				try {
					m = JSON.parse(line);
				} catch {
					continue;
				}
				if (m.type === "answer" || m.type === "candidate") {
					await page.evaluate((l) => (globalThis as any).applySignal(l), line)
						.catch(() => {});
				} else if (m.type === "native_recv") {
					if (m.text === PING) nativeReceived = true;
				} else if (m.type === "result") {
					nativeVerdict = m.ok === true;
					nativeDone();
				}
			}
		}
		nativeDone!();
	})();

	// Browser → native signaling.
	await page.exposeFunction("harnessSignal", (line: string) => {
		toProbe(line).catch(() => {});
	});

	await page.goto(`http://127.0.0.1:${pagePort}/`);
	await page.evaluate(() => (globalThis as any).startProbe());

	const verdict = await page.evaluate(
		() => (globalThis as any).__verdict as Promise<{ ok: boolean; reason?: string }>,
	) as { ok: boolean; reason?: string };

	if (!verdict.ok) {
		fail(`browser did not receive the expected reply: ${verdict.reason ?? "(none)"}`);
	}

	// Confirm the native side too, so both directions are proven, not just the
	// browser's receive.
	await Promise.race([
		nativeSettled,
		new Promise((res) => setTimeout(res, 5_000)),
	]);
	if (!nativeReceived) fail("native peer never reported receiving the browser's bytes");
	if (nativeVerdict === false) fail("native peer reported an unexpected message");

	console.log(
		"PASS: a headless Chromium RTCDataChannel carried bytes both directions to a native " +
			"webrtc-crate peer on loopback (direct, no STUN/TURN); the keyed session's byte path is proven",
	);
} finally {
	clearTimeout(deadline);
	assetServer.abort();
	if (browser) await browser.close().catch(() => {});
	try {
		await probeIn.close();
	} catch {
		// already closed
	}
	try {
		probe.kill();
	} catch {
		// already gone
	}
	await probe.status;
}
Deno.exit(0);
