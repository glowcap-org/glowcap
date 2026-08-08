// The browser entry the rooms browser peer is built on. A real page loads a
// bundle of this — the `@pancake/web` wasm Host,
// no dlopen — and drives the room directory as a capability, dialing every
// locator through serve.ts's `/relay` by mapping host:port to a WebSocket URL.
// This probe is the smallest such page: it dials, fetches the directory, lists
// the rooms, and writes the result into `#status` for `browser_peer_test.ts` to
// read from a real headless Chromium. The full page's data layer replaces
// `ui/net.ts`'s JSON client with exactly these calls.

import { init } from "@pancake/web";

const params = new URLSearchParams(location.search);
const relay = params.get("relay") ?? location.host; // host:port of serve.ts's /relay
const roomHost = params.get("roomHost") ?? "127.0.0.1";
const roomPort = Number(params.get("roomPort") ?? "0");

async function main(status: HTMLElement): Promise<void> {
	const stack = await init({
		wasm: fetch("/pancake_host.wasm"),
		wsUrl: (host, port) => `ws://${relay}/relay?target=${host}:${port}`,
	});
	const session = await stack.connect(stack.tcpLocator(roomHost, roomPort));
	session.serve().catch(() => {});
	try {
		const directory = await session.fetch("directory");
		const rooms = await session.send(directory, "list", []);
		status.textContent = "OK:" + JSON.stringify(rooms);
	} finally {
		session.close();
	}
}

const status = document.getElementById("status")!;
main(status)
	.catch((e) => {
		status.textContent = "ERR:" + (e?.message ?? String(e));
	})
	.finally(() => {
		status.dataset.done = "1";
	});
