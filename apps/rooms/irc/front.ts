// IRC client-to-server protocol as a thin front over native Rooms
// capabilities. Each socket owns one Directory connection and the exact Room
// and DirectMessage objects it acquired; numerics describe those operations,
// never a second IRC-side model of authority.

import { DirectMessage, Directory, Room } from "../lib/room_client.ts";
import { NICK_TAKEN, PEER_OFFLINE, roomErrorOf } from "../lib/errors.ts";
import { MAX_TOPIC, nickRefusal } from "../lib/limits.ts";
import type { RoomsDial } from "../lib/locator.ts";
import { type IrcInboxRouter, releaseIrcRef } from "./front/inbox.ts";
import { boundedTrailing, channelForRoom, memberPrefix, projectedNick, reason, roomName } from "./front/render.ts";
import { encodeIrcMessage, ircFold, type IrcMessage, readIrcLines } from "./protocol.ts";
import { validateIrcNick } from "./registration.ts";
import { IrcSocketWriter } from "./socket_writer.ts";

export const IRC_FRONT_ROOM_LIMIT = 32;
export const IRC_FRONT_DIRECT_LIMIT = 32;
const IRC_FRONT_PROJECTED_NICK_LIMIT = 2048;

export interface IrcFrontOptions {
	readonly directory: string;
	readonly dial: RoomsDial;
	readonly dmLocator: string;
	readonly inboxRouter: IrcInboxRouter;
	readonly serverName: string;
	readonly registrationTimeoutMs?: number;
}

interface Membership {
	readonly channel: string;
	readonly name: string;
	readonly room: Room;
	readonly roster: Map<string, string>;
	topic: string | null;
}

/** Serve one accepted IRC socket until QUIT, EOF, malformed input, or a bounded
 * output failure. Cleanup releases every capability this connection acquired. */
export async function serveIrcFront(conn: Deno.Conn, options: IrcFrontOptions): Promise<void> {
	const client = new FrontClient(conn, options);
	await client.run();
}

class FrontClient {
	readonly #conn: Deno.Conn;
	readonly #options: IrcFrontOptions;
	readonly #writer: IrcSocketWriter;
	readonly #memberships = new Map<string, Membership>();
	readonly #direct = new Map<string, DirectMessage>();
	readonly #projected = new Map<string, string>();
	readonly #unprojected = new Map<string, string>();
	#directory: Directory | null = null;
	#detachInbox: (() => Promise<void>) | null = null;
	#nick: string | null = null;
	#user = false;
	#registered = false;
	#capNegotiating = false;
	#closing = false;

	constructor(conn: Deno.Conn, options: IrcFrontOptions) {
		this.#conn = conn;
		this.#options = options;
		this.#writer = new IrcSocketWriter(conn, () => this.#closeSocket());
	}

	async run(): Promise<void> {
		const timer = setTimeout(() => this.#closeSocket(), this.#options.registrationTimeoutMs ?? 30_000);
		let failure: unknown = null;
		try {
			for await (const message of readIrcLines(this.#conn.readable)) {
				if (await this.#handle(message)) break;
			}
		} catch (error) {
			failure = error;
		} finally {
			clearTimeout(timer);
			await this.#cleanup();
			this.#closeSocket();
		}
		if (failure !== null) throw failure;
	}

	async #handle(message: IrcMessage): Promise<boolean> {
		if (message.command === "QUIT") return true;
		if (message.command === "PING") {
			await this.#writer.send("PONG", message.params, this.#options.serverName);
			return false;
		}
		if (!this.#registered) {
			await this.#handleRegistration(message);
			return false;
		}
		switch (message.command) {
			case "NICK":
				await this.#numeric("438", [
					this.#nick!,
					message.params[0] ?? "*",
					"Nick changes require a new IRC connection",
				]);
				break;
			case "JOIN":
				await this.#join(message.params[0] ?? "");
				break;
			case "PART":
				await this.#part(message.params[0] ?? "");
				break;
			case "PRIVMSG":
				await this.#privmsg(message.params[0], message.params[1]);
				break;
			case "NAMES":
				await this.#names(message.params[0]);
				break;
			case "LIST":
				await this.#list();
				break;
			case "TOPIC":
				await this.#topic(message.params[0], message.params[1]);
				break;
			case "WHOIS":
				await this.#whois(message.params.at(-1));
				break;
			case "CAP":
				await this.#writer.send(
					"CAP",
					[this.#nick!, "NAK", message.params.at(-1) ?? ""],
					this.#options.serverName,
				);
				break;
			default:
				await this.#numeric("421", [this.#nick!, message.command, "Unknown command"]);
		}
		return false;
	}

	async #handleRegistration(message: IrcMessage): Promise<void> {
		if (message.command === "CAP") {
			const subcommand = message.params[0]?.toUpperCase();
			if (subcommand === "LS") {
				this.#capNegotiating = true;
				await this.#writer.send("CAP", [this.#nick ?? "*", "LS", ""], this.#options.serverName);
			} else if (subcommand === "END") {
				this.#capNegotiating = false;
			} else if (subcommand === "REQ") {
				await this.#writer.send(
					"CAP",
					[this.#nick ?? "*", "NAK", message.params.at(-1) ?? ""],
					this.#options.serverName,
				);
			}
		} else if (message.command === "NICK") {
			const nick = message.params[0] ?? "";
			try {
				validateIrcNick(nick);
				const refused = nickRefusal(nick);
				if (refused !== null) throw new Error(refused);
				this.#nick = nick;
			} catch (error) {
				await this.#numeric("432", ["*", nick || "*", reason(error)]);
			}
		} else if (message.command === "USER") {
			if (message.params.length < 4) {
				await this.#numeric("461", [this.#nick ?? "*", "USER", "Not enough parameters"]);
			} else this.#user = true;
		} else {
			await this.#numeric("451", [this.#nick ?? "*", "You have not registered"]);
		}
		if (this.#nick !== null && this.#user && !this.#capNegotiating) await this.#register();
	}

	async #register(): Promise<void> {
		if (this.#registered || this.#directory !== null) return;
		const nick = this.#nick!;
		try {
			const directory = await Directory.connect(this.#options.directory, this.#options.dial);
			this.#directory = directory;
			const route = this.#options.inboxRouter.attach(
				nick,
				directory,
				(peer, text, attachmentCount) => this.#receiveDirect(peer, text, attachmentCount),
				(peer, error) => {
					void this.#notice(`Could not prepare direct messages from ${peer}: ${reason(error)}`).catch(
						() => {},
					);
				},
			);
			this.#detachInbox = route.detach;
			await directory.register(nick, this.#options.dmLocator, route.offer);
			this.#registered = true;
			await this.#numeric("001", [nick, `Welcome to Rooms, ${nick}`]);
			await this.#numeric("002", [nick, `Your server is ${this.#options.serverName}`]);
			await this.#numeric("005", [
				nick,
				"CASEMAPPING=rfc1459",
				"CHANTYPES=#",
				"NICKLEN=28",
				`TOPICLEN=${MAX_TOPIC}`,
				"are supported",
			]);
			await this.#numeric("376", [nick, "End of MOTD"]);
		} catch (error) {
			const code = roomErrorOf(error)?.code === NICK_TAKEN ? "433" : "400";
			await this.#numeric(code, ["*", nick, reason(error)]).catch(() => {});
			this.#closeSocket();
		}
	}

	async #join(raw: string): Promise<void> {
		if (raw.length === 0) return void await this.#numeric("461", [this.#nick!, "JOIN", "Not enough parameters"]);
		for (const channel of raw.split(",")) {
			let name: string;
			try {
				name = roomName(channel);
			} catch (error) {
				await this.#numeric("403", [this.#nick!, channel || "*", reason(error)]);
				continue;
			}
			const key = ircFold(channel);
			if (this.#memberships.has(key)) continue;
			if (this.#memberships.size >= IRC_FRONT_ROOM_LIMIT) {
				await this.#numeric("405", [
					this.#nick!,
					channel,
					`You may join at most ${IRC_FRONT_ROOM_LIMIT} rooms`,
				]);
				continue;
			}
			try {
				const ref = await this.#directory!.enter(name);
				const room = await Room.subscribe(this.#directory!.session, ref, this.#nick!);
				const membership: Membership = { channel, name, room, roster: new Map(), topic: null };
				this.#memberships.set(key, membership);
				await this.#writer.send("JOIN", [channel], memberPrefix(this.#nick!, this.#options.serverName));
				void this.#pumpRoom(membership);
			} catch (error) {
				const numeric = roomErrorOf(error)?.code === NICK_TAKEN ? "433" : "403";
				await this.#numeric(numeric, [this.#nick!, channel, reason(error)]);
			}
		}
	}

	async #part(raw: string): Promise<void> {
		if (raw.length === 0) return void await this.#numeric("461", [this.#nick!, "PART", "Not enough parameters"]);
		for (const channel of raw.split(",")) {
			const key = ircFold(channel);
			const membership = this.#memberships.get(key);
			if (membership === undefined) {
				await this.#numeric("442", [this.#nick!, channel, "You're not on that channel"]);
				continue;
			}
			this.#memberships.delete(key);
			await membership.room.leave().catch(() => {});
			await this.#writer.send("PART", [channel], memberPrefix(this.#nick!, this.#options.serverName));
		}
	}

	async #privmsg(target: string | undefined, text: string | undefined): Promise<void> {
		if (target === undefined) return void await this.#numeric("411", [this.#nick!, "No recipient given"]);
		if (text === undefined || text.length === 0) {
			return void await this.#numeric("412", [this.#nick!, "No text to send"]);
		}
		if (target.startsWith("#")) {
			const membership = this.#memberships.get(ircFold(target));
			if (membership === undefined) {
				return void await this.#numeric("442", [this.#nick!, target, "You're not on that channel"]);
			}
			try {
				const posted = await membership.room.say(text);
				posted?.release();
			} catch (error) {
				await this.#numeric("404", [this.#nick!, target, reason(error)]);
			}
			return;
		}
		const peer = this.#unprojected.get(ircFold(target)) ?? target;
		if (ircFold(peer) === ircFold(this.#nick!)) {
			return void await this.#numeric("401", [this.#nick!, target, "No such nick"]);
		}
		const key = peer.toLowerCase();
		let line = this.#direct.get(key);
		try {
			if (line !== undefined && !line.live) {
				await line.close().catch(() => {});
				this.#direct.delete(key);
				line = undefined;
			}
			if (line === undefined) {
				for (const [heldKey, held] of this.#direct) {
					if (held.live) continue;
					await held.close().catch(() => {});
					this.#direct.delete(heldKey);
				}
				if (this.#direct.size >= IRC_FRONT_DIRECT_LIMIT) {
					return void await this.#numeric("407", [
						this.#nick!,
						target,
						`You may hold at most ${IRC_FRONT_DIRECT_LIMIT} direct lines`,
					]);
				}
				line = await DirectMessage.open(this.#directory!, peer, (reply, attachments, session) => {
					for (const attachment of attachments) {
						releaseIrcRef(session, attachment.blob, "unsupported DM file");
					}
					void this.#sendChat(peer, this.#projectNick(peer), reply).catch(() => {});
					if (attachments.length > 0) {
						void this.#notice(
							`${peer} sent ${attachments.length} file(s); IRC cannot carry their capabilities`,
						)
							.catch(() => {});
					}
					return null;
				});
				this.#direct.set(key, line);
			}
			const posted = await line.say(text);
			posted?.release();
		} catch (error) {
			const code = roomErrorOf(error)?.code === PEER_OFFLINE ? "401" : "400";
			await this.#numeric(code, [this.#nick!, target, reason(error)]);
		}
	}

	async #names(raw?: string): Promise<void> {
		const memberships = raw === undefined
			? [...this.#memberships.values()]
			: raw.split(",").map((channel) => this.#memberships.get(ircFold(channel))).filter((
				room,
			): room is Membership => room !== undefined);
		for (const membership of memberships) await this.#sendNames(membership);
	}

	async #sendNames(membership: Membership): Promise<void> {
		const names = [this.#nick!, ...membership.roster.values()].map((name) => this.#projectNick(name));
		let batch: string[] = [];
		for (const name of names) {
			const candidate = [...batch, name];
			try {
				encodeIrcMessage(
					"353",
					[this.#nick!, "=", membership.channel, candidate.join(" ")],
					this.#options.serverName,
				);
				batch = candidate;
			} catch {
				if (batch.length > 0) {
					await this.#numeric("353", [this.#nick!, "=", membership.channel, batch.join(" ")]);
				}
				batch = [name];
			}
		}
		if (batch.length > 0) await this.#numeric("353", [this.#nick!, "=", membership.channel, batch.join(" ")]);
		await this.#numeric("366", [this.#nick!, membership.channel, "End of NAMES list"]);
	}

	async #list(): Promise<void> {
		await this.#numeric("321", [this.#nick!, "Channel", "Users Name"]);
		let omitted = 0;
		try {
			for (const room of await this.#directory!.list()) {
				const channel = channelForRoom(room.name);
				// IRC's LIST record requires an integer member count and an IRC
				// channel spelling. A foreign publication deliberately has no count,
				// and some native names are not IRC-addressable; omitting them is more
				// truthful than manufacturing either field.
				if (channel === null || room.count === null) {
					omitted += 1;
					continue;
				}
				await this.#numeric("322", [
					this.#nick!,
					channel,
					String(room.count),
					"",
				]);
			}
		} catch (error) {
			await this.#numeric("400", [this.#nick!, reason(error)]);
		}
		await this.#numeric("323", [this.#nick!, "End of LIST"]);
		if (omitted > 0) {
			await this.#notice(`${omitted} room publication(s) were not addressable as counted IRC channels`);
		}
	}

	async #topic(channel: string | undefined, text: string | undefined): Promise<void> {
		if (channel === undefined) {
			return void await this.#numeric("461", [this.#nick!, "TOPIC", "Not enough parameters"]);
		}
		const membership = this.#memberships.get(ircFold(channel));
		if (membership === undefined) {
			return void await this.#numeric("442", [this.#nick!, channel, "You're not on that channel"]);
		}
		if (text === undefined) {
			await this.#numeric(membership.topic === null ? "331" : "332", [
				this.#nick!,
				channel,
				membership.topic ?? "No topic is set",
			]);
			return;
		}
		if (!membership.room.canSetTopic) {
			return void await this.#numeric("482", [this.#nick!, channel, "You do not hold topic authority"]);
		}
		try {
			await membership.room.setTopic(text);
		} catch (error) {
			await this.#numeric("482", [this.#nick!, channel, reason(error)]);
		}
	}

	async #whois(raw?: string): Promise<void> {
		const asked = raw?.split(",")[0] ?? "";
		const peer = this.#unprojected.get(ircFold(asked)) ?? asked;
		const known = ircFold(peer) === ircFold(this.#nick!) ||
			[...this.#memberships.values()].some((room) => room.roster.has(peer.toLowerCase()));
		if (known) await this.#numeric("311", [this.#nick!, asked, "rooms", this.#options.serverName, "*", peer]);
		else await this.#numeric("401", [this.#nick!, asked || "*", "No such nick"]);
		await this.#numeric("318", [this.#nick!, asked || "*", "End of WHOIS"]);
	}

	async #pumpRoom(membership: Membership): Promise<void> {
		try {
			for await (const message of membership.room.messages) {
				if (!this.#memberships.has(ircFold(membership.channel))) break;
				// IRC can report that files existed but cannot carry their blob
				// capabilities. Give those occurrences back before any socket write
				// can fail and skip the remainder of this iteration.
				for (const attachment of message.attachments) membership.room.release(attachment);
				if (message.presence?.kind === "roster") {
					membership.roster.clear();
					for (const name of message.presence.names) {
						if (ircFold(name) !== ircFold(this.#nick!)) membership.roster.set(name.toLowerCase(), name);
					}
					await this.#sendNames(membership);
				} else if (message.presence?.kind === "join") {
					const name = message.presence.name;
					if (ircFold(name) !== ircFold(this.#nick!)) {
						membership.roster.set(name.toLowerCase(), name);
						await this.#writer.send(
							"JOIN",
							[membership.channel],
							memberPrefix(this.#projectNick(name), this.#options.serverName),
						);
					}
				} else if (message.presence?.kind === "leave") {
					const name = membership.roster.get(message.presence.name.toLowerCase()) ?? message.presence.name;
					membership.roster.delete(message.presence.name.toLowerCase());
					await this.#writer.send(
						"PART",
						[membership.channel],
						memberPrefix(this.#projectNick(name), this.#options.serverName),
					);
				}
				if (message.facts?.topic !== undefined) {
					membership.topic = message.facts.topic;
					try {
						await this.#writer.send(
							"TOPIC",
							[membership.channel, membership.topic],
							this.#options.serverName,
						);
					} catch (error) {
						if (!reason(error).includes("exceeds 512 bytes")) throw error;
						await this.#notice(
							`${membership.channel} has a ${
								new TextEncoder().encode(membership.topic).length
							}-byte topic that cannot fit one IRC line`,
						);
					}
				}
				if (!message.system && ircFold(message.from) !== ircFold(this.#nick!)) {
					await this.#sendChat(
						message.from,
						this.#projectNick(message.from),
						message.text,
						membership.channel,
					);
					if (message.attachments.length > 0) {
						await this.#notice(
							`${message.from} sent ${message.attachments.length} file(s) in ${membership.channel}; IRC cannot carry their capabilities`,
						);
					}
				}
			}
		} catch (error) {
			if (!this.#closing) await this.#notice(`${membership.channel} ended: ${reason(error)}`).catch(() => {});
		}
	}

	#receiveDirect(peer: string, text: string, attachmentCount: number): void {
		void this.#sendChat(peer, this.#projectNick(peer), text).catch(() => {});
		if (attachmentCount > 0) {
			void this.#notice(`${peer} sent ${attachmentCount} file(s); IRC cannot carry their capabilities`).catch(
				() => {},
			);
		}
	}

	async #sendChat(from: string, wireFrom: string, text: string, target = this.#nick!): Promise<void> {
		try {
			await this.#writer.send("PRIVMSG", [target, text], memberPrefix(wireFrom, this.#options.serverName));
		} catch (error) {
			if (reason(error).includes("exceeds 512 bytes")) {
				await this.#notice(
					`A ${new TextEncoder().encode(text).length}-byte message from ${from} could not fit one IRC line`,
				);
				return;
			}
			throw error;
		}
	}

	#projectNick(name: string): string {
		const key = name.toLowerCase();
		const held = this.#projected.get(key);
		if (held !== undefined) return held;
		if (this.#projected.size >= IRC_FRONT_PROJECTED_NICK_LIMIT) {
			throw new Error("IRC projected nickname table is full");
		}
		let projected = name;
		try {
			validateIrcNick(projected);
			if (this.#unprojected.has(ircFold(projected))) throw new Error("IRC nickname projection collides");
		} catch {
			projected = projectedNick(name);
			let suffix = 0;
			while (this.#unprojected.has(ircFold(projected))) {
				suffix += 1;
				projected = `${projectedNick(name).slice(0, 24)}-${suffix}`;
			}
		}
		this.#projected.set(key, projected);
		this.#unprojected.set(ircFold(projected), name);
		return projected;
	}

	#numeric(command: string, params: readonly string[]): Promise<void> {
		try {
			return this.#writer.send(command, params, this.#options.serverName);
		} catch (error) {
			if (!reason(error).includes("exceeds 512 bytes") || params.length === 0) throw error;
			const last = params.at(-1)!;
			const replacement = boundedTrailing(
				command,
				params.slice(0, -1),
				this.#options.serverName,
				last,
			);
			return this.#writer.send(command, [...params.slice(0, -1), replacement], this.#options.serverName);
		}
	}

	#notice(text: string): Promise<void> {
		const target = this.#nick ?? "*";
		return this.#writer.send(
			"NOTICE",
			[target, boundedTrailing("NOTICE", [target], this.#options.serverName, text)],
			this.#options.serverName,
		);
	}

	async #cleanup(): Promise<void> {
		this.#closing = true;
		await this.#detachInbox?.();
		this.#detachInbox = null;
		const rooms = [...this.#memberships.values()];
		this.#memberships.clear();
		const lines = [...this.#direct.values()];
		this.#direct.clear();
		await Promise.allSettled([...rooms.map((room) => room.room.leave()), ...lines.map((line) => line.close())]);
		await this.#directory?.close().catch(() => {});
		this.#directory = null;
	}

	#closeSocket(): void {
		this.#closing = true;
		try {
			this.#conn.close();
		} catch { /* peer or writer closed first */ }
	}
}
