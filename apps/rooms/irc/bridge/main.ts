// Serve one IRC channel as a Rooms directory, read-only unless two-way mode
// supplies a registered nick's SASL credentials over TLS.
//
//   deno run --allow-ffi --allow-read --allow-net main.ts \
//     --network=libera --channel=#ocapn --irc-host=irc.libera.chat

import type { Session } from "@pancake/runtime";
import { roomsHost, roomsListen } from "../../lib/locator.ts";
import { IrcBridgeRoom } from "./room.ts";
import { connectIrc, ircChannelProjection, runIrcSession } from "./client.ts";
import { IRC_BRIDGE_USAGE, parseIrcBridgeConfig } from "./config.ts";
import { IrcChannelRelay } from "./outbound.ts";

if (Deno.args.includes("--help")) {
	console.log(IRC_BRIDGE_USAGE);
	Deno.exit(0);
}
const { network, channel, ircHost, ircPort, ircNick, mode, bind, announceHost, port, tls, sasl } = parseIrcBridgeConfig(
	Deno.args,
	(name) => Deno.env.get(name),
);

const relay = new IrcChannelRelay(channel, ircNick, { writable: mode === "two-way" });
const room = new IrcBridgeRoom(network, channel, relay);
const server = await roomsListen(bind, port, roomsHost(), announceHost);
console.log(`ROOMS-IRC-BRIDGE-LISTENING ${server.port} ${room.roomName}`);

void (async () => {
	let delay = 1_000;
	while (true) {
		let conn: Deno.Conn | null = null;
		let registeredAt: number | null = null;
		try {
			conn = await connectIrc({ hostname: ircHost, port: ircPort, tls, nick: ircNick });
			await runIrcSession(conn, ircChannelProjection(room, relay), {
				nick: ircNick,
				sasl,
				onRegistered: () => {
					registeredAt = performance.now();
				},
			});
		} catch (error) {
			console.error(`[rooms-irc] ${error instanceof Error ? error.message : String(error)}; reconnecting`);
		} finally {
			if (registeredAt !== null && performance.now() - registeredAt >= 30_000) delay = 1_000;
			try {
				conn?.close();
			} catch { /* already closed */ }
		}
		await new Promise((resolve) => setTimeout(resolve, delay));
		delay = Math.min(delay * 2, 30_000);
	}
})().catch((error) => console.error("[rooms-irc] reconnect loop ended:", error));

function serve(session: Session): void {
	let retired = false;
	const retire = () => {
		if (retired) return;
		retired = true;
		room.retire(session);
		void session.close().catch(() => {});
	};
	session.onClose(retire);
	room.publish(session);
	void session.serve().then(retire, retire);
}

for await (const session of server) serve(session);
