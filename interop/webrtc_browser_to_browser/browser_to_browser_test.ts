// The WebRTC browser-to-browser proof (ADR-0035). Two real headless Chromium
// contexts each run `@glowcap/web` (the wasm Host) and `@glowcap/webrtc`. The
// offerer dials the answerer's key through the WebRTC connector, the answerer
// accepts through the WebRTC listener, and the two hold a keyed OCapN session
// over a direct DataChannel. The answerer checks that the session names the
// offerer's key. The signaling relay here forwards opaque strings between the
// tabs and stays out of the byte path. It stands in for the room a deployment
// signals through (`webrtc-signaling-captp` proves that over CapTP), so the
// proof needs no room and no cargo.
//
// Needs deno, the wasm module (`zig build wasm-driver`), and a Playwright
// Chromium (the devcontainer image ships one; elsewhere
// `tools/check/playwright-preflight.sh` names the pinned version and how to get
// it). Run directly:
// `deno run --allow-all interop/webrtc_browser_to_browser/browser_to_browser_test.ts`.

import { type Browser, chromium } from "playwright";
import { bundleProbe, fail, freePort } from "../../bindings/ts/web/test/support.ts";

const PROBE = new URL("./probe.ts", import.meta.url).pathname;
const WASM = new URL("../../zig-out/wasm/glowcap_host.wasm", import.meta.url);
// A byte-transparent signaling relay for exactly two peers: it forwards every
// message from one role to the other, buffering for a role that has not yet status-allow: pending state or quoted runtime label
// connected so no early identity or offer is lost. It never parses a payload.
class SignalRelay {
	#sockets: Record<string, WebSocket | null> = { offerer: null, answerer: null };
	#pending: Record<string, string[]> = { offerer: [], answerer: [] };

	join(role: string, socket: WebSocket): void {
		const other = role === "offerer" ? "answerer" : "offerer";
		this.#sockets[role] = socket;
		socket.onmessage = (ev) => this.#forward(other, ev.data as string);
		socket.onclose = () => {
			if (this.#sockets[role] === socket) this.#sockets[role] = null;
		};
		for (const line of this.#pending[role].splice(0)) socket.send(line);
	}

	#forward(to: string, line: string): void {
		const target = this.#sockets[to];
		if (target && target.readyState === WebSocket.OPEN) target.send(line);
		else this.#pending[to].push(line);
	}
}

const deadline = setTimeout(() => fail("browser-to-browser scenario timed out after 90s"), 90_000);

const assetServer = new AbortController();
let browser: Browser | null = null;
try {
	const probeJs = await bundleProbe(PROBE);
	const wasmBytes = await Deno.readFile(WASM);
	const page = `<!doctype html><meta charset=utf-8><title>webrtc browser-to-browser probe</title>` +
		`<pre id=status>connecting…</pre><script type=module>${probeJs}</script>`;

	const relay = new SignalRelay();
	const pagePort = freePort();
	Deno.serve({ port: pagePort, signal: assetServer.signal }, (req) => {
		const url = new URL(req.url);
		if (url.pathname === "/signal") {
			const role = url.searchParams.get("role") ?? "offerer";
			const { socket, response } = Deno.upgradeWebSocket(req);
			socket.onopen = () => relay.join(role, socket);
			return response;
		}
		if (url.pathname === "/glowcap_host.wasm") {
			return new Response(wasmBytes, { headers: { "content-type": "application/wasm" } });
		}
		return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
	});

	browser = await chromium.launch({
		args: [
			"--no-sandbox",
			// Force raw host-IP candidates instead of Chromium's privacy mDNS names,
			// so the two contexts pair on loopback.
			"--disable-features=WebRtcHideLocalIpsWithMdns",
		],
	});

	const openTab = async (role: string) => {
		const context = await browser!.newContext();
		const tab = await context.newPage();
		tab.on("console", (m) => console.error(`  [${role}]`, m.text()));
		tab.on("pageerror", (e) => console.error(`  [${role} error]`, e.message));
		await tab.goto(`http://127.0.0.1:${pagePort}/?role=${role}`);
		return tab;
	};

	// The answerer opens first so it registers its identity and publishes the
	// greeter before the offerer's offer arrives (the relay buffers regardless).
	const answerer = await openTab("answerer");
	const offerer = await openTab("offerer");

	// Each tab settles its own verdict. Watch both, so a failure on either side
	// is reported as soon as it happens instead of as the other side's timeout.
	type Verdict = { ok: boolean; reason?: string };
	const verdictOf = (tab: typeof offerer) =>
		tab.evaluate(() => (globalThis as { __verdict: Promise<Verdict> }).__verdict) as Promise<Verdict>;
	const answered = verdictOf(answerer).then((v) => {
		if (!v.ok) fail(`the answerer browser did not accept the keyed session: ${v.reason ?? "(none)"}`);
		return v;
	});
	const greeted = await verdictOf(offerer);
	if (!greeted.ok) fail(`the offerer browser did not greet the answerer browser: ${greeted.reason ?? "(none)"}`);
	// Confirm the answerer accepted, so both directions of the keyed session are
	// proven, not just the offerer's receive.
	await answered;

	console.log(
		"PASS: two real headless Chromium peers brought up a direct WebRTC DataChannel, " +
			"the signaling host out of the byte path, and held a keyed OCapN session over it " +
			"(the answerer's listener accepted the offerer by its key, and the offerer dialed and greeted)",
	);
} finally {
	clearTimeout(deadline);
	assetServer.abort();
	if (browser) await browser.close().catch(() => {});
}
Deno.exit(0);
