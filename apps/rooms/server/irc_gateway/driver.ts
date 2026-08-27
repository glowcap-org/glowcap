// Reconnecting IRC feed lifecycle for one bridged channel.

import { IrcBridgeRoom } from "../../irc/bridge.ts";
import { connectIrc, runIrcSession } from "../../irc/client.ts";
import { IrcChannelRelay } from "../../irc/outbound.ts";
import type { SaslPlainCredentials } from "../../irc/registration.ts";
import { noteTrouble } from "../journal.ts";

export interface DrivenIrcBridge {
	readonly roomName: string;
	readonly host: string;
	readonly port: number;
	readonly tls: boolean;
	readonly nick: string;
	readonly sasl?: SaslPlainCredentials;
	readonly room: IrcBridgeRoom;
	status: "connecting" | "up" | "backoff";
	stopped: boolean;
	conn: Deno.Conn | null;
}

/** Reconnect quickly after stable service and back off repeated failures until
 * the gateway owner parts the bridge. */
export async function driveIrcBridge(held: DrivenIrcBridge, relay: IrcChannelRelay): Promise<void> {
	let delay = 1_000;
	while (!held.stopped) {
		let registeredAt: number | null = null;
		try {
			held.status = "connecting";
			const conn = await connectIrc({
				hostname: held.host,
				port: held.port,
				tls: held.tls,
				nick: held.nick,
			});
			held.conn = conn;
			if (held.stopped) {
				conn.close();
				return;
			}
			await runIrcSession(conn, held.room, relay, {
				nick: held.nick,
				sasl: held.sasl,
				onRegistered: () => {
					registeredAt = performance.now();
					held.status = "up";
				},
			});
		} catch (error) {
			if (!held.stopped) noteTrouble(`the ${held.roomName} bridge lost its IRC connection`, error);
		} finally {
			held.conn = null;
			held.room.disconnected();
		}
		if (held.stopped) return;
		held.status = "backoff";
		if (registeredAt != null && performance.now() - registeredAt >= 30_000) delay = 1_000;
		await new Promise((resolve) => setTimeout(resolve, delay));
		delay = Math.min(delay * 2, 30_000);
	}
}
