// One Rooms member's IRC network connection and its channel memberships.
//
// IRC gives a connection one current nick and account across every channel.
// The connection owns registration, SASL, PING, AWAY, and nickname changes;
// a channel membership owns only JOIN, targeted messages, PART, and its own
// failure. Closing one membership cannot close its siblings.

import { ctcpAction, ircFold, readIrcLines } from "../protocol.ts";
import { IrcSocketWriter } from "../socket_writer.ts";
import { connectIrc, type IrcEndpoint, sendSaslPlain } from "./client.ts";
import type { SaslPlainCredentials } from "../registration.ts";

export interface IrcChannelMembership {
	say(text: string): Promise<void>;
	action(text: string): Promise<void>;
	part(): void;
	readonly down: Promise<string>;
}

export interface IrcMemberConnection {
	join(channel: string): Promise<IrcChannelMembership>;
	close(reason?: string): void;
	readonly down: Promise<string>;
}

interface ChannelState {
	readonly channel: string;
	readonly ready: Promise<IrcChannelMembership>;
	readonly resolve: (membership: IrcChannelMembership) => void;
	readonly reject: (error: Error) => void;
	readonly down: Promise<string>;
	readonly settleDown: (reason: string) => void;
	membership: IrcChannelMembership | null;
}

const REGISTRATION_MS = 20_000;
const JOIN_MS = 20_000;
const JOIN_REFUSALS = new Set(["403", "405", "471", "473", "474", "475", "476", "477"]);

function selfMessage(prefix: string | null | undefined, nick: string): boolean {
	return prefix?.toLowerCase().startsWith(nick.toLowerCase() + "!") === true;
}

function stateForMessage(channels: ReadonlyMap<string, ChannelState>, params: readonly string[]): ChannelState | null {
	for (const value of params) {
		const found = channels.get(ircFold(value));
		if (found != null) return found;
	}
	return null;
}

/** Register one IRC identity. `join` acquires channel memberships separately,
 * so several bridged rooms share this exact socket, account, and nickname. */
export function openIrcMemberConnection(
	endpoint: IrcEndpoint,
	nick: string,
	sasl?: SaslPlainCredentials,
	onNick?: (nick: string) => void,
): Promise<IrcMemberConnection> {
	return new Promise((resolve, reject) => {
		void (async () => {
			let conn: Deno.Conn;
			try {
				conn = await connectIrc({ ...endpoint, nick });
			} catch (error) {
				reject(error instanceof Error ? error : new Error(String(error)));
				return;
			}
			let registered = false;
			let current = nick;
			let ended = "the IRC server ended the connection";
			let retainedEnd: string | null = null;
			let settleDown!: (reason: string) => void;
			const down = new Promise<string>((done) => settleDown = done);
			const channels = new Map<string, ChannelState>();
			const cancelled = () => {
				ended = "IRC registration was superseded";
				try {
					conn.close();
				} catch { /* already closed */ }
			};
			endpoint.signal?.addEventListener("abort", cancelled, { once: true });
			if (endpoint.signal?.aborted) cancelled();
			const writer = new IrcSocketWriter(conn, (error) => {
				if (retainedEnd == null) ended = error.message;
				try {
					conn.close();
				} catch { /* already closed */ }
			});
			const connection: IrcMemberConnection = {
				join: (channel) => {
					const key = ircFold(channel);
					const existing = channels.get(key);
					if (existing != null) return existing.ready;
					let resolveReady!: (membership: IrcChannelMembership) => void;
					let rejectReady!: (error: Error) => void;
					let settleMembership!: (reason: string) => void;
					const ready = new Promise<IrcChannelMembership>((yes, no) => {
						resolveReady = yes;
						rejectReady = no;
					});
					const membershipDown = new Promise<string>((done) => settleMembership = done);
					const state: ChannelState = {
						channel,
						ready,
						resolve: resolveReady,
						reject: rejectReady,
						down: membershipDown,
						settleDown: settleMembership,
						membership: null,
					};
					channels.set(key, state);
					const expiry = setTimeout(() => {
						if (channels.get(key) !== state || state.membership != null) return;
						channels.delete(key);
						state.reject(new Error(`IRC did not confirm joining ${channel}`));
					}, JOIN_MS);
					void writer.send("JOIN", [channel]).catch((error) => {
						clearTimeout(expiry);
						if (channels.get(key) === state) channels.delete(key);
						state.reject(error instanceof Error ? error : new Error(String(error)));
					});
					void ready.finally(() => clearTimeout(expiry)).catch(() => {});
					return ready;
				},
				close: (reason) => {
					if (reason != null) ended = retainedEnd = reason;
					else void writer.send("QUIT", ["leaving IRC"]).catch(() => {});
					try {
						conn.close();
					} catch { /* already closed */ }
				},
				down,
			};
			const registrationDeadline = setTimeout(() => {
				ended = "IRC registration timed out";
				try {
					conn.close();
				} catch { /* already closed */ }
			}, REGISTRATION_MS);
			try {
				if (sasl !== undefined) await writer.send("CAP", ["LS", "302"]);
				await writer.send("NICK", [nick]);
				await writer.send("USER", [nick, "0", "*", "glowcap rooms member"]);
				let authenticated = sasl === undefined;
				for await (const message of readIrcLines(conn.readable)) {
					if (message.command === "PING") {
						await writer.send("PONG", message.params);
						continue;
					}
					if (
						message.command === "NICK" && typeof message.params[0] === "string" &&
						selfMessage(message.prefix, current)
					) {
						current = message.params[0];
						if (registered) onNick?.(current);
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
					if (message.command === "433") throw new Error(`IRC nickname "${nick}" is already in use`);
					if (message.command === "ERROR") {
						throw new Error(`IRC server closed: ${message.params.at(-1) ?? "unknown reason"}`);
					}
					if (message.command === "001") {
						if (!authenticated) throw new Error("IRC registered before SASL authentication completed");
						const granted = message.params[0];
						if (typeof granted === "string" && granted !== "*" && granted !== current) current = granted;
						registered = true;
						clearTimeout(registrationDeadline);
						if (current !== nick) onNick?.(current);
						resolve(connection);
						continue;
					}
					const channel = stateForMessage(channels, message.params);
					if (channel == null) continue;
					const key = ircFold(channel.channel);
					if (message.command === "JOIN" && selfMessage(message.prefix, current)) {
						if (channel.membership != null) continue;
						const membership: IrcChannelMembership = {
							say: (text) => writer.send("PRIVMSG", [channel.channel, text]),
							action: (text) => writer.send("PRIVMSG", [channel.channel, ctcpAction(text)]),
							part: () => {
								if (channels.get(key) !== channel) return;
								channels.delete(key);
								channel.settleDown(`left ${channel.channel}`);
								void writer.send("PART", [channel.channel, "leaving the room"]).catch(() => {});
							},
							down: channel.down,
						};
						channel.membership = membership;
						channel.resolve(membership);
						continue;
					}
					if (JOIN_REFUSALS.has(message.command) && channel.membership == null) {
						channels.delete(key);
						channel.reject(
							new Error(
								`IRC server refused ${channel.channel}: ${message.params.at(-1) ?? message.command}`,
							),
						);
						continue;
					}
					const kicked = message.command === "KICK" &&
						message.params.some((value) => ircFold(value) === ircFold(current));
					if ((message.command === "PART" && selfMessage(message.prefix, current)) || kicked) {
						channels.delete(key);
						channel.settleDown(
							kicked
								? `IRC removed you from ${channel.channel}`
								: `IRC ended membership in ${channel.channel}`,
						);
					}
				}
			} catch (error) {
				if (retainedEnd == null) ended = error instanceof Error ? error.message : String(error);
			} finally {
				clearTimeout(registrationDeadline);
				endpoint.signal?.removeEventListener("abort", cancelled);
				for (const channel of channels.values()) {
					if (channel.membership == null) channel.reject(new Error(ended));
					else channel.settleDown(ended);
				}
				channels.clear();
				try {
					conn.close();
				} catch { /* already closed */ }
				settleDown(ended);
				if (!registered) reject(new Error(ended));
			}
		})();
	});
}
