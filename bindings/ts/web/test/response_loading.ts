// Browser-loading contract, exercised by web-peer-test with the built Host.
// HTTP failures must precede compilation; generic static-server MIME types
// still load, while a malformed streamed module keeps its original failure.
import { init, type WasmSource } from "@glowcap/web";
import { fail } from "../../test/assert.ts";

async function rejection(source: WasmSource): Promise<unknown> {
	try {
		await init({ wasm: source, seed: new Uint8Array(1) });
	} catch (error) {
		return error;
	}
	fail("invalid Wasm response or Host seed unexpectedly initialized");
}

export async function proveResponseLoading(wasmBytes: Uint8Array<ArrayBuffer>): Promise<void> {
	const missing = new Response("not found", { status: 404, statusText: "Not Found" });
	Object.defineProperty(missing, "url", { value: "https://example.invalid/glowcap_host.wasm" });
	const httpError = await rejection(Promise.resolve(missing));
	if (
		!(httpError instanceof Error) ||
		!httpError.message.includes("HTTP 404 Not Found") ||
		!httpError.message.includes(missing.url)
	) {
		fail(`Wasm HTTP failure lost its status or URL: ${String(httpError)}`);
	}
	if (missing.bodyUsed) fail("Wasm HTTP failure consumed its response body");

	const malformed = new Response("invalid Wasm", { headers: { "content-type": "application/wasm" } });
	let bufferedReads = 0;
	const readBytes = malformed.arrayBuffer.bind(malformed);
	malformed.arrayBuffer = () => {
		bufferedReads += 1;
		return readBytes();
	};
	const compileError = await rejection(malformed);
	if (!(compileError instanceof WebAssembly.CompileError)) {
		fail(`malformed Wasm lost its compilation failure: ${String(compileError)}`);
	}
	if (typeof WebAssembly.instantiateStreaming === "function" && bufferedReads !== 0) {
		fail("malformed streamed Wasm retried through a buffered read");
	}

	// Each valid source must reach Host construction, where the invalid seed
	// refuses it. That leaves the one-page adapter slot available to the next
	// source and proves the same recovery path as the final successful init.
	for (
		const source of [
			wasmBytes,
			new Response(wasmBytes, { headers: { "content-type": "application/wasm" } }),
			new Response(wasmBytes),
		]
	) {
		const seedError = await rejection(source);
		if (!(seedError instanceof Error) || !seedError.message.includes("seed must be 32 bytes")) {
			fail(`valid Wasm response did not reach Host construction: ${String(seedError)}`);
		}
	}
}
