// The ADR-0034 proof, run by `zig build web-peer-test`: a browser-
// shaped glowcap peer holds a real keyed OCapN session over WebSocket.
//
// Two processes so the two runtime adapters never share a module graph: the
// child (`serve_ws_host.ts`) is an FFI dlopen host accepting WebSocket; this
// process loads the runtime through `@glowcap/web` (the wasm module, the
// linear-memory FFI adapter, the WebSocket channel) with no `Deno.dlopen`
// anywhere in its path. The proof: the keyed handshake terminates inside the
// wasm peer, a fetch and a call settle, and the host calls back into an object
// the wasm peer itself hosts (the behavior trampoline crossing the wasm
// boundary inbound).
//
// Everything here is browser-shaped API (WebAssembly, WebSocket, fetch-style
// bytes); Deno supplies the same globals, so the check is in-tree and
// socket-real at once.

import * as tcp from "@glowcap/tcp";
import { init } from "@glowcap/web";
import { proveChromiumNoiseRelay } from "./browser_noise_relay_proof.ts";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

// A hang is a bug, never a slow test (the cli rule's posture): bound the whole
// scenario.
const deadline = setTimeout(() => fail("web peer scenario timed out after 90s"), 90_000);

// 1. Start the accepting host and wait for its READY line.
const child = new Deno.Command(Deno.execPath(), {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-net",
		"--allow-env",
		import.meta.dirname + "/serve_ws_host.ts",
	],
	stdout: "piped",
	stderr: "inherit",
}).spawn();

const readyLine = await (async () => {
	const reader = child.stdout.getReader();
	const decoder = new TextDecoder();
	let buffered = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) fail("host exited before READY");
		buffered += decoder.decode(value);
		const newline = buffered.indexOf("\n");
		if (newline !== -1) {
			reader.releaseLock();
			return buffered.slice(0, newline);
		}
	}
})();
const ready = JSON.parse(readyLine) as {
	port: number;
	designator: string;
	capnpPort: number;
	capnpDesignator: string;
};

try {
	// 2. Load the runtime over the wasm peer. The wsUrl map says how a dialed
	//    host:port reaches its bytes; here the host accepts WebSocket on the
	//    dialed port itself.
	const wasmBytes = await Deno.readFile(
		new URL("../../../../zig-out/wasm/glowcap_host.wasm", import.meta.url),
	);
	// `init` installs the Wasm adapter before it asks the shared Runtime to
	// mint its Host. Refuse there once, then retry: a failed construction must
	// withdraw that provisional registration or this second call reports an
	// adapter conflict instead of opening the corrected runtime.
	let badInit: unknown = null;
	try {
		await init({ wasm: wasmBytes, seed: new Uint8Array(1) });
	} catch (error) {
		badInit = error;
	}
	if (!(badInit instanceof Error) || !badInit.message.includes("seed must be 32 bytes")) {
		fail(`invalid Host seed did not fail after adapter installation: ${String(badInit)}`);
	}
	const runtime = await init({
		wasm: wasmBytes,
		wsUrl: (host, port) => `ws://${host}:${port}/`,
	});

	// 3. Dial the keyed locator. The handshake verifies the host's key inside
	//    the wasm session; a squatter would refuse here.
	const session = await runtime.connect(
		tcp.keyed.locator(ready.designator, "127.0.0.1", ready.port),
	);
	const sessionServing = session.serve();

	// 4. Fetch and call, and host an object of our own for the callback leg.
	let resolveNotify!: (value: string) => void;
	const notifiedValue = new Promise<string>((r) => {
		resolveNotify = r;
	});
	const collector = session.spawn((verb, args) => {
		if (verb === "notify") resolveNotify(args[0] as string);
		return null;
	});

	const greeter = await session.fetch("greeter");
	const reply = await session.send(greeter, "greet", ["web", collector]);
	if (reply !== "hello web") fail(`unexpected greet reply: ${JSON.stringify(reply)}`);

	const seen = await notifiedValue;
	if (seen !== "saw web") fail(`unexpected callback payload: ${JSON.stringify(seen)}`);

	const proveShapes = async (s: typeof session) => {
		const shape = await s.fetch("shape");
		for (const selector of [null, "", "call"]) {
			for (const payload of [[], ["payload"]]) {
				const got = await s.send(shape, selector, payload);
				if (JSON.stringify(got) !== JSON.stringify([selector, payload])) {
					fail(`wasm lost invocation shape ${JSON.stringify([selector, payload])}: ${JSON.stringify(got)}`);
				}
			}
		}
		const callback = s.spawn((selector) => selector === null ? "direct" : selector === "" ? "empty" : selector);
		const got = await s.send(shape, "callbacks", [callback]);
		if (JSON.stringify(got) !== '["direct","empty","call"]') {
			fail(`wasm callback lost selector presence: ${JSON.stringify(got)}`);
		}
	};
	await proveShapes(session);
	await Promise.all([session.close(), sessionServing]);

	// 5. The second grammar: a fresh dial negotiates Cap'n Proto against the
	//    capnp host, so both codecs run inside the wasm peer on this proof.
	const capnpRuntime = await runtime.openRuntime({ codec: "capnp" });
	const capnpSession = await capnpRuntime.connect(
		tcp.keyed.locator(ready.capnpDesignator, "127.0.0.1", ready.capnpPort),
	);
	const capnpServing = capnpSession.serve();
	const capnpGreeter = await capnpSession.fetch("greeter");
	await proveShapes(capnpSession);
	const capnpReply = await capnpSession.send(capnpGreeter, "greet", ["capnp web"]);
	if (capnpReply !== "hello capnp web") {
		fail(`unexpected capnp greet reply: ${JSON.stringify(capnpReply)}`);
	}
	await Promise.all([capnpSession.close(), capnpServing]);
	await capnpRuntime.close();

	// 6. A real Chromium page becomes the non-listening side of a sealed relay
	// rendezvous, then the installed glowcap CLI cold-dials and calls it.
	await runtime.close();
	await proveChromiumNoiseRelay();

	console.log(
		"PASS: a wasm browser peer held keyed and Noise-relay OCapN sessions " +
			"(fetch, call, a host callback, both codecs, CLI cold-dial, Chromium)",
	);
} finally {
	clearTimeout(deadline);
	try {
		child.kill();
	} catch {
		// already gone
	}
	await child.status;
}
