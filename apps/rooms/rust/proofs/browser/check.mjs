import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { once } from "node:events";
import { chromium } from "playwright";

const wasm = await readFile(
	new URL("../../target/wasm32-unknown-unknown/release/rooms_contract_proofs.wasm", import.meta.url),
);
const module = await WebAssembly.compile(wasm);
assert.deepEqual(WebAssembly.Module.imports(module), [], "application/Host calls must stay inside the linked module");
assert.deepEqual(WebAssembly.Module.exports(module).filter((item) => item.kind === "memory").map((item) => item.name), [
	"memory",
]);
const instance = await WebAssembly.instantiate(module, {});
const initialBytes = instance.exports.memory.buffer.byteLength;
assert.equal(instance.exports.rooms_contract_proof(), 1);
assert(instance.exports.memory.buffer.byteLength > initialBytes, "exercise shared memory growth");

const server = createServer((request, response) => {
	if (request.url === "/rooms.wasm") {
		response.writeHead(200, { "Content-Type": "application/wasm" });
		response.end(wasm);
	} else if (request.url === "/") {
		response.writeHead(200, { "Content-Type": "text/html" });
		response.end("<!doctype html><title>Rooms Rust application contract</title>");
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
	page.setDefaultTimeout(30_000);
	await page.goto(`http://127.0.0.1:${server.address().port}/`);
	const result = await page.evaluate(async () => {
		const module = await WebAssembly.compileStreaming(fetch("/rooms.wasm"));
		const instance = await WebAssembly.instantiate(module, {});
		const before = instance.exports.memory.buffer.byteLength;
		const result = instance.exports.rooms_contract_proof();
		return {
			imports: WebAssembly.Module.imports(module),
			result,
			grew: instance.exports.memory.buffer.byteLength > before,
		};
	});
	assert.deepEqual(result, { imports: [], result: 1, grew: true });
	console.log(`Rooms application contracts passed in Deno and Chromium; linked Wasm: ${wasm.length} bytes.`);
} finally {
	await browser?.close();
	await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}
