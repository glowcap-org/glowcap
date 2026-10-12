// Real-browser proof for browser Noise rendezvous. Chromium runs the public
// @glowcap/web bundle over the shipped Wasm Host; the installed native CLI
// cold-dials its advertised locator through the reference relay and calls an
// object hosted in the page. Rooms is absent from this proof.

import { chromium } from "playwright";
import { bundleProbe, fail, freePort } from "./support.ts";

declare global {
	var glowcapNoiseReady: {
		locator: string;
		finish(): Promise<string[]>;
	} | undefined;
}

const ROOT = new URL("../../../../", import.meta.url).pathname;
const PROBE = new URL("./browser_noise_relay_probe.ts", import.meta.url).pathname;
const WASM = new URL("../../../../zig-out/wasm/glowcap_host.wasm", import.meta.url);
const TLS_CERT = new URL("../../../../test/net/fixtures/tls_server.pem", import.meta.url).pathname;
const TLS_KEY = new URL("../../../../test/net/fixtures/tls_server.key", import.meta.url).pathname;
const TLS_ROOT = new URL("../../../../test/net/fixtures/tls_root.pem", import.meta.url).pathname;

interface RelayOutput {
	port: number;
	reader: ReadableStreamDefaultReader<string>;
	buffered: string;
}

async function awaitRelay(child: Deno.ChildProcess): Promise<RelayOutput> {
	const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
	let buffered = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) fail("relay exited before becoming ready");
		buffered += value;
		const match = /DENO-RELAY-READY (\d+)\n/.exec(buffered);
		if (match == null) continue;
		return { port: Number(match[1]), reader, buffered };
	}
}

async function finishRelayOutput(output: RelayOutput): Promise<string> {
	let buffered = output.buffered;
	while (true) {
		const { value, done } = await output.reader.read();
		if (done) return buffered;
		buffered += value;
	}
}

export async function proveChromiumNoiseRelay(): Promise<void> {
	const bundle = await bundleProbe(PROBE);
	const wasm = await Deno.readFile(WASM);
	const pagePort = freePort();
	const assets = new AbortController();
	Deno.serve({ hostname: "127.0.0.1", port: pagePort, signal: assets.signal }, (request) => {
		const path = new URL(request.url).pathname;
		if (path === "/glowcap_host.wasm") {
			return new Response(wasm, { headers: { "content-type": "application/wasm" } });
		}
		if (path === "/probe.js") {
			return new Response(bundle, { headers: { "content-type": "text/javascript; charset=utf-8" } });
		}
		return new Response(
			"<!doctype html><meta charset=utf-8><title>glowcap browser Noise proof</title><script type=module src=/probe.js></script>",
			{ headers: { "content-type": "text/html; charset=utf-8" } },
		);
	});
	const relay = new Deno.Command(Deno.execPath(), {
		args: ["run", "--allow-net", "--allow-ffi", "--allow-env", "--allow-read", "bindings/ts/relay/serve.ts", "0"],
		cwd: ROOT,
		env: {
			GLOWCAP_RELAY_TLS_CERT: TLS_CERT,
			GLOWCAP_RELAY_TLS_KEY: TLS_KEY,
			GLOWCAP_RELAY_PLAINTEXT_CANARY: "GLOWCAP_CAPTP_PLAINTEXT_CANARY",
		},
		stdout: "piped",
		stderr: "piped",
	}).spawn();
	const relayStderr = new Response(relay.stderr).text();
	const state = await Deno.makeTempDir({ prefix: "glowcap-chromium-noise-" });
	let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
	let relayOutput: RelayOutput | null = null;
	let relayStopped = false;
	try {
		relayOutput = await awaitRelay(relay);
		const relayPort = relayOutput.port;
		browser = await chromium.launch({ args: ["--no-sandbox"] });
		const context = await browser.newContext({ ignoreHTTPSErrors: true });
		const tab = await context.newPage();
		const pageErrors: string[] = [];
		tab.on("pageerror", (error: Error) => pageErrors.push(error.message));
		const failedRequests: string[] = [];
		tab.on("requestfailed", (request) => {
			if (failedRequests.length < 8) {
				failedRequests.push(
					`${request.method()} ${request.url()}: ${request.failure()?.errorText ?? "failed"}`,
				);
			}
		});
		const relayUrl = `wss://localhost:${relayPort}/relay`;
		await tab.goto(`http://127.0.0.1:${pagePort}/?relay=${encodeURIComponent(relayUrl)}`);
		try {
			await tab.waitForFunction(() => globalThis.glowcapNoiseReady !== undefined);
		} catch (error) {
			const cause = error instanceof Error ? error.message : String(error);
			const diagnostics = [...pageErrors, ...failedRequests];
			fail(`browser Noise peer did not become ready: ${cause}; diagnostics: ${diagnostics.join("; ") || "none"}`);
		}
		const locator = await tab.evaluate(() => globalThis.glowcapNoiseReady!.locator);
		const client = await new Deno.Command("./zig-out/bin/glowcap", {
			args: ["ocapn", "call", locator, "noise-greeter", "greet", "GLOWCAP_CAPTP_PLAINTEXT_CANARY"],
			cwd: ROOT,
			env: {
				GLOWCAP_STATE: state,
				GLOWCAP_RENDEZVOUS: relayUrl,
				GLOWCAP_RELAY_CA_FILE: TLS_ROOT,
			},
			stdout: "piped",
			stderr: "piped",
		}).output();
		const stdout = new TextDecoder().decode(client.stdout);
		if (!client.success) {
			const diagnostics = await tab.evaluate(() => globalThis.glowcapNoiseReady!.finish());
			fail(
				`native caller exited ${client.code}: ${new TextDecoder().decode(client.stderr)}; ` +
					`browser diagnostics: ${diagnostics.join("; ")}`,
			);
		}
		if (!stdout.includes("hello GLOWCAP_CAPTP_PLAINTEXT_CANARY from Chromium Noise")) {
			fail(`native caller returned ${JSON.stringify(stdout)}`);
		}
		const diagnostics = await tab.evaluate(() => globalThis.glowcapNoiseReady!.finish());
		if (diagnostics.length !== 0) fail(`browser Host diagnostics: ${diagnostics.join("; ")}`);
		if (pageErrors.length !== 0) fail(`browser page errors: ${pageErrors.join("; ")}`);
		relay.kill();
		await relay.status;
		relayStopped = true;
		const relayStdout = await finishRelayOutput(relayOutput);
		const audit = /DENO-RELAY-AUDIT (\d+) (\d+)/.exec(relayStdout);
		if (audit == null || Number(audit[1]) === 0) fail("relay did not observe any binary carrier messages");
		if (Number(audit[2]) !== 0) fail("relay observed the CapTP plaintext canary inside noise-relay");
		const relayErrors = await relayStderr;
		if (relayErrors.length !== 0) fail(`relay reported a successful-session failure: ${relayErrors}`);
	} finally {
		await browser?.close();
		assets.abort();
		if (!relayStopped) {
			try {
				relay.kill();
			} catch { /* already exited */ }
			await relay.status;
			if (relayOutput != null) await finishRelayOutput(relayOutput);
			await relayStderr;
		}
		await Deno.remove(state, { recursive: true });
	}
}
