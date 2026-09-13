import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { once } from "node:events";
import { chromium } from "playwright";

const root = new URL("../../../../../zig-out/wasm/rooms/", import.meta.url);
const wasm = await readFile(new URL("rooms_browser_bg.wasm", root));
const script = await readFile(new URL("rooms_browser.js", root));
const fixtures = JSON.parse(await readFile(new URL("../fixtures/workspaces.json", import.meta.url), "utf8"));
const module = await WebAssembly.compile(wasm);
assert.deepEqual(WebAssembly.Module.exports(module).filter((item) => item.kind === "memory").map((item) => item.name), [
	"memory",
]);
assert(
	WebAssembly.Module.imports(module).every((item) => item.kind === "function" && !item.name.startsWith("glowcap_")),
);

function contract(binding, rows) {
	for (const row of rows) {
		if ((binding.readWorkspace(row.raw) ?? null) !== row.normalized) throw new Error(`workspace: ${row.name}`);
	}
	const exact = rows.find((row) => row.name === "lossless text");
	const literal = exact.raw.replace("\\ud800", "\ud800");
	if (binding.readWorkspace(literal) !== exact.normalized) throw new Error("literal UTF-16 text was changed");
	if (binding.readWorkspace(exact.raw.replace("\\ud800", "\\\ud800")) != null) {
		throw new Error("an invalid escape became valid");
	}
	if (binding.readWorkspace(" ".repeat(512 * 1024 + 1)) != null) throw new Error("oversize document accepted");
	if (binding.directoryAuthority("127.0.0.1:1234") !== "ocapn://127.0.0.1%3A1234.tcp") {
		throw new Error("TCP directory identity");
	}
	if (binding.directoryAuthority("ocapn://directory.iroh") !== "ocapn://directory.id") {
		throw new Error("strong directory identity");
	}
	const tcp = JSON.parse(binding.inspectDirectory("127.0.0.1:1234"));
	if (tcp.address !== "127.0.0.1:1234" || tcp.authority !== "ocapn://127.0.0.1%3A1234.tcp") {
		throw new Error("directory display route");
	}
	const capability = JSON.parse(binding.inspectCapability("ocapn://directory.iroh/s/held"));
	if (capability.authority !== "ocapn://directory.id" || capability.transport !== "iroh") {
		throw new Error("capability route");
	}
	for (const invalid of ["not a locator", "x".repeat(65537), "ocapn://\ud800.iroh/s/held"]) {
		if (binding.inspectCapability(invalid) != null) throw new Error("invalid capability admitted");
	}
	if (globalThis[Symbol.for("glowcap.runtime.adapter")] !== undefined) {
		throw new Error("startup installed a TypeScript runtime");
	}
}

async function lifetime(binding) {
	const trouble = [];
	const reportTrouble = (source, reason) => trouble.push({ source, reason });
	const first = new binding.RoomsBrowserApplication(reportTrouble);
	const sibling = new binding.RoomsBrowserApplication(reportTrouble);
	// Fill admission synchronously, before the worker's first poll. Every
	// refusal gets an observer immediately, including pressure and closure.
	const answers = Array.from({ length: 256 }, () =>
		first.attach("invalid").then(
			() => {
				throw new Error("invalid capability attached");
			},
			(error) => error.message,
		));
	await first.close();
	const results = await Promise.all(answers);
	if (!results.some((error) => error.includes("capacity"))) throw new Error("unbounded application admission");
	let failure;
	try {
		await first.attach("invalid");
	} catch (error) {
		failure = error.message;
	}
	if (!failure?.includes("closed")) throw new Error("closed application admitted work");
	failure = undefined;
	try {
		await sibling.attach("invalid");
	} catch (error) {
		failure = error.message;
	}
	if (failure == null || failure.includes("closed")) throw new Error("closing one application retired its sibling");
	await Promise.all([first.close(), sibling.close()]);
	if (trouble.length !== 0) {
		throw new Error(`normal application retirement reported trouble: ${JSON.stringify(trouble)}`);
	}
	first.free();
	sibling.free();
}

const binding = await import(new URL("rooms_browser.js", root));
binding.initSync({ module });
contract(binding, fixtures);
const sockets = new Set();
const server = createServer((request, response) => {
	const asset = request.url === "/rooms_browser.js"
		? ["text/javascript", script]
		: request.url === "/rooms_browser_bg.wasm"
		? ["application/wasm", wasm]
		: request.url === "/"
		? ["text/html", "<!doctype html><title>Rooms application startup</title>"]
		: null;
	if (asset) {
		response.writeHead(200, { "Content-Type": asset[0] });
		response.end(asset[1]);
	} else {
		response.writeHead(404);
		response.end();
	}
});
// Hold the WebSocket upgrade without answering. Closing the application
// must retire a real transport still opening, rather than wait for timeout.
server.on("upgrade", (_request, socket) => {
	sockets.add(socket);
	socket.on("close", () => sockets.delete(socket));
	socket.on("error", () => {});
	socket.on("end", () => socket.end());
	socket.resume();
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
let browser;
try {
	browser = await chromium.launch({ headless: true });
	const page = await browser.newPage();
	await page.goto(`http://127.0.0.1:${server.address().port}/`);
	await page.evaluate(async ({ source, lifecycle, rows }) => {
		const binding = await import("/rooms_browser.js");
		await binding.default();
		Function(`return (${source})`)()(binding, rows);
		await Function(`return (${lifecycle})`)()(binding);
	}, { source: contract.toString(), lifecycle: lifetime.toString(), rows: fixtures });
	const upgrading = once(server, "upgrade", { signal: AbortSignal.timeout(10_000) });
	await page.evaluate(async () => {
		const binding = await import("/rooms_browser.js");
		globalThis.openingApplication = new binding.RoomsBrowserApplication(() => {});
		globalThis.openingOutcome = globalThis.openingApplication.attach("ocapn://127.0.0.1%3A1234.tcp/s/held").then(
			() => "unexpected attachment",
			(error) => error.message,
		);
	});
	const [, socket] = await upgrading.catch(async (error) => {
		throw new Error(
			`opening did not reach the web relay: ${await page.evaluate(() => globalThis.openingOutcome)}`,
			{ cause: error },
		);
	});
	const retired = once(socket, "close", { signal: AbortSignal.timeout(10_000) }).then(() => null, (error) => error);
	await page.evaluate(async () => {
		// Chromium emits an error event when an opening WebSocket is aborted.
		// The binding retains that terminal transport error; it must not
		// swallow it or mistake it for an unobserved physical close.
		let closeError;
		try {
			await Promise.race([
				globalThis.openingApplication.close(),
				new Promise((_, reject) =>
					setTimeout(() => reject(new Error("application close stalled during WebSocket opening")), 5_000)
				),
			]);
		} catch (error) {
			closeError = error.message;
		}
		if (closeError != null && closeError !== "glowcap error -8: browser channel error") throw new Error(closeError);
		const outcome = await globalThis.openingOutcome;
		if (outcome === "unexpected attachment") throw new Error(outcome);
		globalThis.openingApplication.free();
		delete globalThis.openingApplication;
		delete globalThis.openingOutcome;
	});
	const retirementError = await retired;
	if (retirementError) {
		throw new Error("application close returned before its opening socket retired", { cause: retirementError });
	}
	console.log(
		`Production Rooms startup passed ${fixtures.length} saved-workspace cases in Deno and Chromium; ${wasm.length} Wasm bytes.`,
	);
} finally {
	await browser?.close();
	for (const socket of sockets) socket.destroy();
	await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}
