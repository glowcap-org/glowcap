// The rooms-web browser-peer proof in a REAL browser. A headless Chromium loads
// a page that bundles `@pancake/web`
// (`browser_peer_probe.ts`) and drives the room directory through serve.ts's
// `/relay` byte pipe — the full path the shipped page takes: browser wasm Host,
// the linear-memory FFI adapter, a WebSocket channel through the relay, and a
// real capability call, none of it dlopen.
//
// This is the browser half of the mechanism that `web_relay_peer_test.ts`
// proves in Deno. Both are their own process; here the browser is a separate
// runtime entirely. serve.ts (room server + relay) and the page assets are served
// from two local origins; only the relay WebSocket crosses between them, which
// is exactly the shipped shape.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's children are native), and a Playwright Chromium
// (`npx playwright install chromium && sudo npx playwright install-deps`). Run
// it directly: `deno run --allow-all apps/rooms/test/browser_peer_test.ts`.
//
// The stack now bundles for a browser: `internal/ffi/runtime.ts` and
// `internal/ffi/load.ts` carry no top-level await (Deno and the injected
// adapter resolve synchronously; Bun loads via `ensureRuntimeReady`; the
// archive cascade's `node:*` built-ins are static imports the browser bundle
// stubs), so `deno bundle`'s single-file flattening has no top-level await to
// deadlock. This is the browser twin of `zig build rooms-web-relay-peer`
// (Deno).

import { chromium } from "playwright";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const PROBE = new URL("./browser_peer_probe.ts", import.meta.url).pathname;
const WASM = new URL("../../../zig-out/wasm/pancake_host.wasm", import.meta.url);

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

async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 200; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			await res.body?.cancel();
			if (res.status === 200 || res.status === 503) return;
		} catch {
			// not up yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("serve.ts did not answer on its HTTP port");
}

const BUNDLE_CONFIG =
	new URL("../../../bindings/ts/web/browser-bundle.json", import.meta.url).pathname;

// Bundle the probe for the browser through the web binding's browser-bundle
// config, which stubs the stack's non-browser FFI adapters (node:net, bun:ffi)
// so the single-file bundle resolves without a runtime the browser lacks.
async function bundleProbe(): Promise<string> {
	const { code, stdout, stderr } = await new Deno.Command("deno", {
		args: [
			"bundle",
			"--platform",
			"browser",
			"--no-lock",
			"--quiet",
			"--config",
			BUNDLE_CONFIG,
			PROBE,
		],
		stdout: "piped",
		stderr: "piped",
	}).output();
	if (code !== 0) {
		fail("deno bundle of the probe failed: " + new TextDecoder().decode(stderr).trim());
	}
	return new TextDecoder().decode(stdout);
}

const deadline = setTimeout(() => fail("browser-peer scenario timed out after 60s"), 60_000);

const httpPort = freePort();
const roomPort = freePort();
const pagePort = freePort();

// serve.ts: the room server + the /relay byte pipe.
const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
}).spawn();

const assetServer = new AbortController();
let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);

	const probeJs = await bundleProbe();
	const wasmBytes = await Deno.readFile(WASM);
	const page = `<!doctype html><meta charset=utf-8><title>rooms browser peer probe</title>` +
		`<pre id=status>connecting…</pre><script type=module>${probeJs}</script>`;

	// Serve the page, the bundle-inlined HTML, and the wasm same-origin; the
	// only cross-origin hop is the relay WebSocket to serve.ts, the shipped shape.
	Deno.serve({ port: pagePort, signal: assetServer.signal }, (req) => {
		const url = new URL(req.url);
		if (url.pathname === "/pancake_host.wasm") {
			return new Response(wasmBytes, {
				headers: { "content-type": "application/wasm" },
			});
		}
		return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
	});

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("console", (m) => console.error("  [browser]", m.text()));
	tab.on("pageerror", (e) => console.error("  [browser error]", e.message));
	const relay = `127.0.0.1:${httpPort}`;
	await tab.goto(
		`http://127.0.0.1:${pagePort}/?relay=${relay}&roomHost=127.0.0.1&roomPort=${roomPort}`,
	);

	// Wait for the probe to settle (dataset.done), then read #status.
	await tab.waitForFunction(
		() => document.getElementById("status")?.dataset.done === "1",
		{ timeout: 45_000 },
	).catch(async () => {
		const seen = await tab.textContent("#status").catch(() => "(no #status)");
		fail(`probe never settled; #status = ${seen}`);
	});
	const status = await tab.textContent("#status");
	if (!status || !status.startsWith("OK:")) {
		fail(`browser peer did not reach the directory: ${status}`);
	}
	const rooms = JSON.parse(status.slice("OK:".length));
	if (!Array.isArray(rooms)) {
		fail(`directory list was not an array in the browser: ${status}`);
	}

	console.log(
		"PASS: a real headless Chromium ran the @pancake/web peer, dialed the room " +
			"through /relay, and listed the directory as a capability call",
	);
} finally {
	clearTimeout(deadline);
	assetServer.abort();
	if (browser) {
		await browser.close().catch(() => {});
	}
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
Deno.exit(0);
