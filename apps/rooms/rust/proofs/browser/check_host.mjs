import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { once } from "node:events";
import { chromium } from "playwright";
import { checkChannels } from "./check_channels.mjs";
import { checkStorage } from "./check_storage.mjs";
import { checkSessionForeign, checkSessionGraph } from "./check_session_graph.mjs";
import { checkSessionForeignReload } from "./check_foreign_reload.mjs";
import { checkSessionExecutor } from "./check_session_executor.mjs";
import { iceFixtures } from "./check_ice.mjs";
import { snippet } from "./assets.mjs";
import { storageWithLostAcknowledgment } from "./graph_outcome.mjs";

const graphOnly = Deno.args.includes("--session-graph");
const reloadOnly = Deno.args.includes("--session-foreign-reload");
const foreignOnly = Deno.args.includes("--session-foreign");
const executorGroups = Deno.args.filter((argument) => /^--session-executor-group=[0-3]$/.test(argument));
assert(executorGroups.length <= 1, "select one executor group");
const executorGroup = executorGroups.length === 0 ? null : Number(executorGroups[0].at(-1));
const executorOnly = Deno.args.includes("--session-executor-storage") || executorGroup !== null;
const sharingOnly = Deno.args.includes("--managed-sharing");
const roomsOnly = Deno.args.includes("--managed-rooms");
assert(
	Deno.args.every((argument) =>
		[
			"--session-graph",
			"--session-foreign-reload",
			"--session-foreign",
			"--session-executor-storage",
			"--managed-sharing",
			"--managed-rooms",
		]
			.includes(argument) ||
		/^--session-executor-group=[0-3]$/.test(argument)
	),
	"unknown proof selection",
);
assert(
	!(executorGroup !== null && Deno.args.includes("--session-executor-storage")),
	"select executor scenarios or startup/storage checks",
);
assert(
	[graphOnly, reloadOnly, foreignOnly, executorOnly, sharingOnly, roomsOnly].filter(Boolean).length <= 1,
	"select one focused proof",
);
const focused = graphOnly || reloadOnly || foreignOnly || executorOnly || sharingOnly || roomsOnly;

const applicationOnly = sharingOnly || roomsOnly;
const moduleName = applicationOnly ? "rooms_browser" : "rooms_contract_proofs";
const root = new URL(
	applicationOnly ? "../../target/browser-app-proof/pkg/" : "../../target/browser-host/pkg/",
	import.meta.url,
);
const wasm = await readFile(new URL(`${moduleName}_bg.wasm`, root));
const script = await readFile(new URL(`${moduleName}.js`, root));
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
const { initSync, rooms_browser_host_contract } = await import(new URL(`${moduleName}.js`, root));
initSync({ module });
let deadline;
try {
	if (!focused) {
		await Promise.race([
			rooms_browser_host_contract(),
			new Promise((_, reject) => {
				deadline = setTimeout(() => reject(new Error("Deno Host contract timed out")), 30_000);
			}),
		]);
	}
} finally {
	clearTimeout(deadline);
}

const ice = iceFixtures();
const server = createServer(async (request, response) => {
	if (ice.serve(request, response)) return;
	const path = new URL(request.url, "http://localhost").pathname;
	if (path.startsWith("/snippets/")) {
		try {
			const bytes = path.endsWith("/storage.js") && !new URL(request.url, "http://localhost").search
				? storageWithLostAcknowledgment(path)
				: await snippet(root, path);
			response.writeHead(200, { "Content-Type": "text/javascript" });
			response.end(bytes);
		} catch {
			response.writeHead(404);
			response.end();
		}
		return;
	}
	const asset = request.url === `/${moduleName}.js`
		? ["text/javascript", script]
		: request.url === `/${moduleName}_bg.wasm`
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
	const url = `http://127.0.0.1:${server.address().port}/`;
	await page.goto(url);
	if (!focused) {
		await page.evaluate(async () => {
			const binding = await import("/rooms_contract_proofs.js");
			await binding.default();
			let deadline;
			try {
				await Promise.race([
					(async () => {
						await binding.rooms_browser_host_contract();
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
	}
	if (!focused) await checkStorage(page);
	if (!focused || graphOnly) await checkSessionGraph(page);
	if (reloadOnly) await checkSessionForeignReload(browser, page, url);
	if (!focused || foreignOnly) await checkSessionForeign(page);
	if (executorOnly) await checkSessionExecutor(page, executorGroup);
	if (sharingOnly || roomsOnly) {
		await checkChannels(page, { script, wasm, root, moduleName }, "tcp", roomsOnly ? "rooms" : "sharing");
	}
	if (!focused) {
		await ice.check(page);
		await checkChannels(page, { script, wasm, root });
		await checkChannels(page, { script, wasm, root }, "iroh");
	}
	console.log(
		roomsOnly
			? "Managed browser registration, room subscription, chat and exact-source file reads passed through the production Rooms server."
			: sharingOnly
			? "Exact managed use and control sharing, attenuation, pause, resume and revocation passed through the production Noise relay."
			: executorOnly
			? executorGroup === null
				? "Managed session metadata and startup durability passed in Chromium."
				: `Managed session executor group ${executorGroup} passed in Chromium.`
			: foreignOnly
			? "Maximum foreign fields preserved without an exporter and restored exactly in Chromium."
			: reloadOnly
			? "Maximum foreign fields restored after full source-page reload against a surviving exporter."
			: graphOnly
			? "Session graph commit, rollback, unknown outcomes and cold reload passed in Chromium."
			: `Rust async Host passed in Deno and Chromium; shared archive execution and revocable shares, IndexedDB contract/retention/rollback/eviction, Chromium session commands, host TCP/iroh forwarding, keyed/Noise relay, RTCDataChannel, signaling and ICE fetch passed; ${wasm.length} linked Wasm bytes.`,
	);
} finally {
	await browser?.close();
	await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}
