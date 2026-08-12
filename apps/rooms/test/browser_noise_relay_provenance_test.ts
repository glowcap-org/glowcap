/// <reference lib="dom" />

// A real Chromium proof that a browser wasm Noise-relay session reports its
// authenticated transport provenance through the public Session API.

import { chromium } from "playwright";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const PROBE = new URL("./browser_noise_relay_provenance_probe.ts", import.meta.url).pathname;
const PROBE_DOCUMENT = "/locator";
const BUNDLE_CONFIG = new URL(
	"../../../bindings/ts/web/browser-bundle.json",
	import.meta.url,
).pathname;

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}

async function waitForHttp(port: number): Promise<void> {
	for (let attempt = 0; attempt < 200; attempt++) {
		try {
			const response = await fetch(`http://127.0.0.1:${port}/locator`);
			await response.body?.cancel();
			if (response.status === 200) return;
		} catch {
			// serve.ts is still starting its room child.
		}
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	fail("serve.ts never published a room locator");
}

async function bundleProbe(): Promise<string> {
	const result = await new Deno.Command("deno", {
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
	if (!result.success) {
		fail(`browser probe bundle failed: ${new TextDecoder().decode(result.stderr).trim()}`);
	}
	return new TextDecoder().decode(result.stdout);
}

async function openProbe(
	page: import("playwright").Page,
	port: number,
	role: "accept" | "dial",
	probeJs: string,
	target?: string,
): Promise<void> {
	const query = new URLSearchParams({ role });
	if (target !== undefined) query.set("target", target);
	await page.goto(`http://127.0.0.1:${port}${PROBE_DOCUMENT}?${query}`);
	await page.evaluate(() => {
		const status = document.createElement("pre");
		status.id = "status";
		status.textContent = "connecting";
		document.body.append(status);
	});
	await page.addScriptTag({ content: probeJs, type: "module" });
}

const deadline = setTimeout(() => fail("browser Noise-relay provenance proof timed out"), 60_000);
const httpPort = freePort();
const roomPort = freePort();
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

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);
	const probeJs = await bundleProbe();
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const acceptor = await browser.newPage();
	const dialer = await browser.newPage();
	for (const [page, name] of [[acceptor, "acceptor"], [dialer, "dialer"]] as const) {
		page.on("console", (message) => console.error(`  [${name}]`, message.text()));
		page.on("pageerror", (error) => console.error(`  [${name} error]`, error.message));
	}

	await openProbe(acceptor, httpPort, "accept", probeJs);
	await acceptor.waitForFunction(
		() => document.getElementById("status")?.textContent?.startsWith("READY:"),
		undefined,
		{ timeout: 15_000 },
	);
	const ready = await acceptor.textContent("#status");
	const designator = ready?.slice("READY:".length) ?? "";
	if (!/^[0-9a-f]{64}$/.test(designator)) fail(`invalid acceptor designator: ${ready}`);

	await openProbe(dialer, httpPort, "dial", probeJs, designator);
	await dialer.waitForFunction(
		() => document.getElementById("status")?.dataset.done === "1",
		undefined,
		{ timeout: 45_000 },
	);
	const result = await dialer.textContent("#status");
	if (result !== 'OK:{"provenance":"authenticated-transport"}') {
		fail(`browser Noise-relay session reported ${result}`);
	}

	console.log(
		"PASS: a real Chromium wasm peer read authenticated-transport provenance " +
			"from a live noise-relay Session.partnerIdentity() before a capability fetch",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
