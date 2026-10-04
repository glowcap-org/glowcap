import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { once } from "node:events";
import { chromium } from "playwright";
import { checkChannels } from "./check_channels.mjs";
import { checkStorage } from "./check_storage.mjs";
import { iceFixtures } from "./check_ice.mjs";
import { snippet } from "./assets.mjs";

const root = new URL("../../target/browser-host/pkg/", import.meta.url);
const wasm = await readFile(new URL("rooms_contract_proofs_bg.wasm", root));
const script = await readFile(new URL("rooms_contract_proofs.js", root));
const module = await WebAssembly.compile(wasm);
assert.deepEqual(
	WebAssembly.Module.exports(module).filter((entry) => entry.kind === "memory").map((entry) => entry.name),
	["memory"],
);
// Imports perform platform effects. CapTP still links directly into this module.
assert(
	WebAssembly.Module.imports(module).every((entry) =>
		entry.kind === "function" && !entry.name.startsWith("glowcap_")
	),
);
const { initSync, rooms_browser_host_contract } = await import(new URL("rooms_contract_proofs.js", root));
initSync({ module });
let deadline;
try {
	await Promise.race([
		rooms_browser_host_contract(),
		new Promise((_, reject) => {
			deadline = setTimeout(() => reject(new Error("Deno Host contract timed out")), 30_000);
		}),
	]);
} finally {
	clearTimeout(deadline);
}

const ice = iceFixtures();
const server = createServer(async (request, response) => {
	if (ice.serve(request, response)) return;
	const path = new URL(request.url, "http://localhost").pathname;
	if (path.startsWith("/snippets/")) {
		try {
			const bytes = await snippet(root, path);
			response.writeHead(200, { "Content-Type": "text/javascript" });
			response.end(bytes);
		} catch {
			response.writeHead(404);
			response.end();
		}
		return;
	}
	const asset = request.url === "/rooms_contract_proofs.js"
		? ["text/javascript", script]
		: request.url === "/rooms_contract_proofs_bg.wasm"
		? ["application/wasm", wasm]
		: request.url === "/"
		? ["text/html", "<!doctype html><title>Rust browser Host contract</title>"]
		: null;
	if (asset) {
		response.writeHead(200, { "Content-Type": asset[0] });
		response.end(asset[1]);
	} else {
		response.writeHead(404);
		response.end();
	}
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
let browser;
try {
	browser = await chromium.launch({ headless: true });
	const page = await browser.newPage();
	page.on("pageerror", (error) => console.error(error));
	page.on("console", (message) => {
		if (message.type() === "error") console.error(message.text());
	});
	await page.goto(`http://127.0.0.1:${server.address().port}/`);
	await page.evaluate(async () => {
		const binding = await import("/rooms_contract_proofs.js");
		await binding.default();
		let deadline;
		try {
			await Promise.race([
				(async () => {
					await binding.rooms_browser_host_contract();
					await binding.rooms_browser_session_contract();
					await binding.rooms_browser_storage_contract();
				})(),
				new Promise((_, reject) => {
					deadline = setTimeout(() => reject(new Error("Chromium Host contract timed out")), 30_000);
				}),
			]);
		} finally {
			clearTimeout(deadline);
		}
	});
	await checkStorage(page);
	await ice.check(page);
	await checkChannels(page, { script, wasm, root });
	await checkChannels(page, { script, wasm, root }, "iroh");
	console.log(
		`Rust async Host passed in Deno and Chromium; shared archive execution and revocable shares, IndexedDB contract/retention/rollback/eviction, Chromium session commands, native TCP/iroh forwarding, keyed/Noise relay, RTCDataChannel, signaling and ICE fetch passed; ${wasm.length} linked Wasm bytes.`,
	);
} finally {
	await browser?.close();
	await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}
