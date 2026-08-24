// Listen for ordinary IRC clients and project each connection onto one native
// Rooms Directory session. A sibling CapTP listener on the same Host makes the
// registered IRC users reachable through Rooms introductions.

import { listen as listenIroh, Reachability } from "@pancake/iroh";
import * as tcp from "@pancake/tcp";
import { dial, isUriLocator, roomsHost, roomsListen } from "../lib/locator.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";
import { serveIrcFront } from "./front.ts";
import { frontInboxRouter } from "./front/inbox.ts";
import { IRC_FRONT_CLIENT_LIMIT } from "./front/limits.ts";
import { IRC_FRONT_USAGE, parseIrcFrontConfig } from "./front_config.ts";
import { encodeIrcMessage } from "./protocol.ts";

if (Deno.args.includes("--help")) {
	console.log(IRC_FRONT_USAGE);
	Deno.exit(0);
}

const config = parseIrcFrontConfig(Deno.args);
const host = roomsHost();
let dmServer: Awaited<ReturnType<typeof listenIroh>> | Awaited<ReturnType<typeof roomsListen>>;
if (config.dm.transport === "iroh") {
	const iroh = await listenIroh({ reachability: Reachability.Direct }, { host });
	await waitUntil(() => iroh.directAddresses.length > 0, 20_000, "iroh direct-message addresses");
	dmServer = iroh;
} else if (config.dm.transport === "tcp") {
	dmServer = await roomsListen(config.dm.bind, config.dm.port, host, config.dm.announceHost);
} else {
	dmServer = await tcp.noise.listen(config.dm.bind, config.dm.port, {
		host,
		advertisedHost: config.dm.announceHost,
	});
}
await using runtime = await openRoomsRuntime({
	host,
	iroh: isUriLocator(config.directory) || config.dm.transport === "iroh"
		? { reachability: Reachability.Direct }
		: undefined,
});
const inboxRouter = frontInboxRouter(host);
const listener = config.tls === undefined ? Deno.listen({ hostname: config.bind, port: config.port }) : Deno.listenTls({
	hostname: config.bind,
	port: config.port,
	cert: await Deno.readTextFile(config.tls.certPath),
	key: await Deno.readTextFile(config.tls.keyPath),
});

console.log(
	`ROOMS-IRC-FRONT-LISTENING ${(listener.addr as Deno.NetAddr).port} ${config.directory} DM ${dmServer.uri}`,
);

void (async () => {
	for await (const session of dmServer) void session.serve().catch(() => {});
})().catch((error) => console.error("[rooms-irc-front] direct-message listener ended:", error));

const active = new Set<Deno.Conn>();
for await (const conn of listener) {
	if (active.size >= IRC_FRONT_CLIENT_LIMIT) {
		void refuseBusy(conn, config.serverName);
		continue;
	}
	active.add(conn);
	void serveIrcFront(conn, {
		directory: config.directory,
		dial: (locator) => dial(locator, runtime),
		dmLocator: dmServer.uri,
		inboxRouter,
		serverName: config.serverName,
	}).catch((error) => {
		console.error(`[rooms-irc-front] client ended: ${error instanceof Error ? error.message : String(error)}`);
	}).finally(() => active.delete(conn));
}

async function refuseBusy(conn: Deno.Conn, serverName: string): Promise<void> {
	try {
		const bytes = encodeIrcMessage("ERROR", [`Server has ${IRC_FRONT_CLIENT_LIMIT} active clients`], serverName);
		let offset = 0;
		while (offset < bytes.length) {
			const wrote = await conn.write(bytes.subarray(offset));
			if (wrote === 0) break;
			offset += wrote;
		}
	} finally {
		try {
			conn.close();
		} catch { /* peer closed first */ }
	}
}

async function waitUntil(ready: () => boolean, timeoutMs: number, what: string): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!ready()) {
		if (Date.now() >= deadline) throw new Error(`timed out waiting for ${what}`);
		await new Promise((resolve) => setTimeout(resolve, 25));
	}
}
