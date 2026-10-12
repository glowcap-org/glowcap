// Invoked by the native executable scenarios. Only the browser Wasm binding
// runs here. The HTTP front and directory are the Rust binaries under test.
import { init } from "@glowcap/web";
import { roomsHostOptions } from "../../lib/profile.ts";
import { DIRECTORY, LIST } from "../../lib/protocol.ts";

const base = Deno.args[0];
const location = await fetch(`${base}/locator`).then((response) => response.text());
const ws = base.replace(/^http/, "ws");
const runtime = await init({
	// This is an independent binding consumer of the relay, not a Rooms web
	// asset. The product serves only its statically linked Rust application.
	wasm: await Deno.readFile(new URL("../../../../zig-out/wasm/glowcap_host.wasm", import.meta.url)),
	wsUrl: (host, port) => `${ws}/relay?target=${encodeURIComponent(`${host}:${port}`)}`,
	relayUrl: (locator) => `${ws}/relay?target=${encodeURIComponent(locator)}`,
	...roomsHostOptions(),
});
try {
	const session = await runtime.connect(runtime.parseLocator(location.trim()));
	const serving = session.serve().catch(() => {});
	try {
		const directory = await session.fetch(DIRECTORY);
		const rooms = await session.send(directory, LIST, []);
		if (!Array.isArray(rooms)) throw new Error("directory list must answer rooms");
	} finally {
		await session.close();
		await serving;
	}
} finally {
	await runtime.close();
}
