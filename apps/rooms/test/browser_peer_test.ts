// The rooms browser-peer proof in a REAL browser. A headless Chromium loads
// a page that bundles `@pancake/web`
// (`browser_peer_probe.ts`) and drives the room directory through serve.ts's
// `/relay` byte pipe — the full path the shipped page takes: browser wasm Host,
// the linear-memory FFI adapter, a WebSocket channel through the relay, and a
// real capability call, none of it dlopen.
//
// This is the browser half of the mechanism that `web_relay_peer_test.ts`
// proves in Deno. Both are their own process; here the browser is a separate
// runtime entirely.
//
// The page and the relay share one origin, because that is what the shipped page
// does: serve.ts serves the page, and the page dials `/relay` on the host it came
// from. serve.ts refuses a relay dial whose Origin names a different host, so a
// page somewhere else cannot use a reader's local relay to reach whatever it
// likes; `relayOriginAllowed` in web_test.ts holds that rule. So the probe is
// grafted onto a document serve.ts really served, and the wasm module, the relay,
// and the room are all the real ones.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's children are native), and a Playwright Chromium
// (the devcontainer image ships one). Run
// it directly: `deno run --allow-all apps/rooms/test/browser_peer_test.ts`.
//
// The runtime now bundles for a browser: `internal/ffi/runtime.ts` and
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
// The document the probe is grafted onto. It has to be a real response from
// serve.ts and not one the test invents: a page the browser was handed without a
// request going out has no address behind it, so Chromium files it under the
// public address space and blocks everything it then asks of a local one. Of the
// handful of things serve.ts serves, this is the one small inert document — the
// room's own address, which is exactly what the probe is about to dial. Every
// other path answers with the rooms page, which would run a second peer beside
// the one under test.
const PROBE_DOCUMENT = "/locator";

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

// Wait for the room's address, not merely for something to answer: the probe
// dials the room, and it is grafted onto this very response. A 503 here is
// serve.ts saying the room is not up yet.
async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 200; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			await res.body?.cancel();
			if (res.status === 200) return;
		} catch {
			// not up yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("serve.ts never published a room locator");
}

const BUNDLE_CONFIG = new URL("../../../bindings/ts/web/browser-bundle.json", import.meta.url).pathname;

// Bundle the probe for the browser through the web binding's browser-bundle
// config, which stubs the runtime's non-browser FFI adapters (node:net, bun:ffi)
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

// serve.ts: the room server + the /relay byte pipe.
const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-write",
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

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);

	const probeJs = await bundleProbe();

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("console", (m) => console.error("  [browser]", m.text()));
	tab.on("pageerror", (e) => console.error("  [browser error]", e.message));

	// No `relay` parameter: the probe defaults to the host it was loaded from,
	// which is the whole point.
	await tab.goto(
		`http://127.0.0.1:${httpPort}${PROBE_DOCUMENT}?roomHost=127.0.0.1&roomPort=${roomPort}`,
	);
	// The shell the probe reports through, and then the probe. Everything it asks
	// for from here — the wasm module, the relay socket — is a same-origin request
	// to serve.ts, from the page's point of view and from serve.ts's.
	await tab.evaluate(() => {
		const status = document.createElement("pre");
		status.id = "status";
		status.textContent = "connecting…";
		document.body.append(status);
	});
	await tab.addScriptTag({ content: probeJs, type: "module" });

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
			"through /relay on the origin it was served from, and listed the directory " +
			"as a capability call",
	);
} finally {
	clearTimeout(deadline);
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
