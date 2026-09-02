// The WebRTC browser-peer proof in a REAL browser (ADR-0089 phase 6). A headless
// Chromium is the offerer: it bundles `@glowcap/web` (the wasm protocol core) and
// `@glowcap/webrtc` (`RtcPeer` over RTCPeerConnection), brings up a DataChannel to
// the native answerer (`answerer.zig`, over the `glowcap_webrtc_*` sidecar), and
// runs a full keyed OCapN session over that channel: fetch the answerer's
// `greeter`, call `greet`, and check the reply.
//
// This is the browser twin of `webrtc-interop` (two native peers). There the
// signaling is ferried in-process between two Zig peers; here it crosses a real
// process and runtime boundary. This harness ferries it out of band over the
// answerer's stdio, one JSON line each way — the stand-in for the OCapN
// signaling capability ADR-0089 phase 5 carries — while session authority stays
// end to end over the DataChannel's DTLS, keyed to the answerer's announced
// designator.
//
// Signaling is relay-less: no STUN, no TURN. Both peers gather loopback/host
// candidates on the same host and connect directly. The answerer includes its
// loopback candidate; Chromium runs with mDNS host-candidate obfuscation
// disabled so its host candidates are raw IPs the native peer can reach.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the sidecar-linked
// answerer (`zig build webrtc-answerer`, needs cargo), and a Playwright Chromium
// (the devcontainer image ships one; elsewhere
// `tools/check/playwright-preflight.sh` names the pinned version and how to get
// it). Run directly:
// `deno run --allow-all interop/webrtc_browser_peer/browser_peer_test.ts`.

import { chromium } from "playwright";
import { bundleProbe, fail, freePort } from "../../bindings/ts/web/test/support.ts";

const ROOT = new URL("../../", import.meta.url).pathname;
const ANSWERER = `${ROOT}zig-out/bin/glowcap-webrtc-answerer`;
const WASM = new URL("../../zig-out/wasm/glowcap_host.wasm", import.meta.url);
const PROBE = new URL("./probe.ts", import.meta.url).pathname;
const deadline = setTimeout(() => fail("browser-peer scenario timed out after 60s"), 60_000);

// The native answerer: the sidecar-linked keyed server. Piped stdio carries
// signaling.
const answerer = new Deno.Command(ANSWERER, {
	stdin: "piped",
	stdout: "piped",
	stderr: "inherit",
}).spawn();
const answererIn = answerer.stdin.getWriter();
const enc = new TextEncoder();
async function toAnswerer(line: string): Promise<void> {
	await answererIn.write(enc.encode(line + "\n"));
}

const assetServer = new AbortController();
let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	const probeJs = await bundleProbe(PROBE);
	const wasmBytes = await Deno.readFile(WASM);
	const page = `<!doctype html><meta charset=utf-8><title>webrtc browser peer probe</title>` +
		`<pre id=status>connecting…</pre><script type=module>${probeJs}</script>`;

	const pagePort = freePort();
	Deno.serve({ port: pagePort, signal: assetServer.signal }, (req) => {
		const url = new URL(req.url);
		if (url.pathname === "/glowcap_host.wasm") {
			return new Response(wasmBytes, { headers: { "content-type": "application/wasm" } });
		}
		return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
	});

	browser = await chromium.launch({
		args: [
			"--no-sandbox",
			// Force raw host-IP candidates instead of Chromium's privacy mDNS
			// (.local) names the native crate cannot resolve on loopback.
			"--disable-features=WebRtcHideLocalIpsWithMdns",
		],
	});
	const tab = await browser.newPage();
	tab.on("console", (m) => console.error("  [browser]", m.text()));
	tab.on("pageerror", (e) => console.error("  [browser error]", e.message));

	// Browser → answerer signaling.
	await tab.exposeFunction("harnessSignal", (line: string) => {
		toAnswerer(line).catch(() => {});
	});

	await tab.goto(`http://127.0.0.1:${pagePort}/`);

	// Only now pump the answerer's stdout into the page: the OS pipe buffered its
	// early `identity` line, and the page's `applySignal` is registered, so no
	// signaling is lost. Route answer/candidate/identity lines to the browser.
	(async () => {
		const dec = new TextDecoder();
		let buf = "";
		for await (const chunk of answerer.stdout) {
			buf += dec.decode(chunk, { stream: true });
			let nl: number;
			while ((nl = buf.indexOf("\n")) >= 0) {
				const line = buf.slice(0, nl).trim();
				buf = buf.slice(nl + 1);
				if (!line) continue;
				await tab.evaluate(
					(l) => (globalThis as { applySignal: (s: string) => void }).applySignal(l),
					line,
				)
					.catch(() => {});
			}
		}
	})();

	const verdict = await tab.evaluate(
		() => (globalThis as { __verdict: Promise<{ ok: boolean; reason?: string }> }).__verdict,
	) as { ok: boolean; reason?: string };

	if (!verdict.ok) {
		fail(`browser peer did not greet the answerer: ${verdict.reason ?? "(none)"}`);
	}

	console.log(
		"PASS: a real headless Chromium ran @glowcap/web + @glowcap/webrtc, brought up a " +
			"DataChannel to the native answerer, and greeted it over a keyed OCapN session",
	);
} finally {
	clearTimeout(deadline);
	assetServer.abort();
	if (browser) await browser.close().catch(() => {});
	try {
		await answererIn.close();
	} catch {
		// already closed
	}
	try {
		answerer.kill();
	} catch {
		// already gone
	}
	await answerer.status;
}
Deno.exit(0);
