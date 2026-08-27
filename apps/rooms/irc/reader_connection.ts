// One reader's own IRC presence: their nick on the network, joined to one
// channel, speaking only when they do.
//
// The gateway's shared connection is the read feed; this is the outbound
// half of a member's citizenship. It registers, joins, answers PING, and
// says the member's lines as the member, nothing else: channel state,
// rosters, and inbound traffic stay with the shared feed, which is what
// keeps this driver small enough to reason about. No automatic reconnect: a
// dropped reader connection settles `down` with its reason, the gateway
// clears the seat, and the member's next post opens a fresh one — a lazy
// retry a person can see, instead of a background loop they cannot.

import { ctcpAction, readIrcLines } from "./protocol.ts";
import { IrcSocketWriter } from "./socket_writer.ts";
import { connectIrc, type IrcEndpoint, sendSaslPlain } from "./client.ts";
import type { SaslPlainCredentials } from "./registration.ts";

/** A live reader connection: say lines as the reader, and close when the
 * seat retires. `down` settles with the reason the connection ended, once,
 * however it ends. */
export interface ReaderLink {
	say(text: string): Promise<void>;
	/** Say a `/me`: the same line as a CTCP ACTION, which is what it is. */
	action(text: string): Promise<void>;
	/** Step away, or back with an empty reason. */
	away(reason: string): Promise<void>;
	close(reason?: string): void;
	readonly down: Promise<string>;
}

/** How long registration and the join may take before the attempt fails. */
const READER_REGISTRATION_MS = 20_000;

/** Open one reader connection: register as `nick`, join `channel`, and hand
 * back the link. Throws when the network refuses the nick or channel. */
export function openReaderConnection(
	endpoint: IrcEndpoint,
	nick: string,
	channel: string,
	sasl?: SaslPlainCredentials,
	/** The server renamed this connection (services enforcing a registered
	 * nick is the common cause). The caller decides whether an automatic
	 * projection may follow it or an explicitly chosen identity must fail. */
	onNick?: (nick: string) => void,
): Promise<ReaderLink> {
	return new Promise((resolve, reject) => {
		let settledUp = false;
		let settleDown!: (reason: string) => void;
		const down = new Promise<string>((res) => {
			settleDown = res;
		});
		void (async () => {
			let conn: Deno.Conn;
			try {
				conn = await connectIrc({ ...endpoint, nick });
			} catch (error) {
				reject(error instanceof Error ? error : new Error(String(error)));
				return;
			}
			let ended = "the IRC server ended the connection";
			let retainedEnd: string | null = null;
			const cancelled = () => {
				ended = "IRC registration was superseded";
				try {
					conn.close();
				} catch { /* the connection already ended */ }
			};
			endpoint.signal?.addEventListener("abort", cancelled, { once: true });
			if (endpoint.signal?.aborted) cancelled();
			const writer = new IrcSocketWriter(conn, (error) => {
				if (retainedEnd == null) ended = error.message;
				try {
					conn.close();
				} catch { /* the peer closed first */ }
			});
			const link: ReaderLink = {
				say: (text) => writer.send("PRIVMSG", [channel, text]),
				action: (text) => writer.send("PRIVMSG", [channel, ctcpAction(text)]),
				away: (reason) => writer.send("AWAY", reason === "" ? [] : [reason]),
				close: (reason) => {
					if (reason != null) ended = retainedEnd = reason;
					// Best-effort courtesy for an ordinary departure. A diagnosed
					// failure closes directly so a refused QUIT cannot replace its cause.
					else void writer.send("QUIT", ["leaving the room"]).catch(() => {});
					try {
						conn.close();
					} catch { /* already down */ }
				},
				down,
			};
			const deadline = setTimeout(() => {
				ended = "IRC registration timed out";
				try {
					conn.close();
				} catch { /* already down */ }
			}, READER_REGISTRATION_MS);
			try {
				// The reader's own registered account, when they handed one over:
				// the same CAP/AUTHENTICATE PLAIN walk the shared feed speaks,
				// with `sendSaslPlain` owning the payload chunking for both.
				if (sasl !== undefined) await writer.send("CAP", ["LS", "302"]);
				await writer.send("NICK", [nick]);
				await writer.send("USER", [nick, "0", "*", "pancake rooms reader"]);
				let joined = false;
				let current = nick;
				let authenticated = sasl === undefined;
				for await (const message of readIrcLines(conn.readable)) {
					if (message.command === "PING") {
						await writer.send("PONG", message.params);
						continue;
					}
					if (
						message.command === "NICK" && message.params[0] !== undefined &&
						message.prefix?.toLowerCase().startsWith(current.toLowerCase() + "!")
					) {
						current = message.params[0];
						if (joined) onNick?.(current);
						continue;
					}
					if (message.command === "CAP" && sasl !== undefined) {
						const subcommand = message.params[1]?.toUpperCase();
						if (subcommand === "LS") {
							const offered = message.params.at(-1)?.split(/\s+/) ?? [];
							if (!offered.some((capability) => capability.split("=")[0] === "sasl")) {
								throw new Error("IRC server does not advertise SASL");
							}
							await writer.send("CAP", ["REQ", "sasl"]);
							continue;
						}
						if (subcommand === "ACK") {
							await writer.send("AUTHENTICATE", ["PLAIN"]);
							continue;
						}
						if (subcommand === "NAK") throw new Error("IRC server refused the SASL capability");
					}
					if (message.command === "AUTHENTICATE" && sasl !== undefined && message.params[0] === "+") {
						await sendSaslPlain(writer, sasl);
						continue;
					}
					if (message.command === "903" && sasl !== undefined) {
						authenticated = true;
						await writer.send("CAP", ["END"]);
						continue;
					}
					if (["902", "904", "905", "906", "907"].includes(message.command)) {
						throw new Error(`IRC SASL authentication failed (${message.command})`);
					}
					if (message.command === "433") {
						throw new Error(`IRC nickname "${nick}" is already in use`);
					}
					if (message.command === "ERROR") {
						throw new Error(`IRC server closed: ${message.params.at(-1) ?? "unknown reason"}`);
					}
					if (message.command === "001") {
						if (!authenticated) throw new Error("IRC registered before SASL authentication completed");
						// Some servers assign the final nick in the welcome itself.
						const granted = message.params[0];
						if (granted !== undefined && granted !== "*" && granted !== current) current = granted;
						await writer.send("JOIN", [channel]);
						continue;
					}
					if (["403", "405", "471", "473", "474", "475", "476", "477"].includes(message.command)) {
						throw new Error(`IRC server refused ${channel}: ${message.params.at(-1) ?? message.command}`);
					}
					if (
						!joined && message.command === "JOIN" &&
						message.prefix?.toLowerCase().startsWith(current.toLowerCase() + "!")
					) {
						joined = true;
						clearTimeout(deadline);
						settledUp = true;
						if (current !== nick) onNick?.(current);
						resolve(link);
					}
				}
			} catch (error) {
				if (retainedEnd == null) ended = error instanceof Error ? error.message : String(error);
			} finally {
				clearTimeout(deadline);
				endpoint.signal?.removeEventListener("abort", cancelled);
				try {
					conn.close();
				} catch { /* already down */ }
				settleDown(ended);
				if (!settledUp) reject(new Error(ended));
			}
		})();
	});
}
