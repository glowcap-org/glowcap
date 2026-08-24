// An IRC channel presented as an ordinary Rooms directory and room.
// The IRC edge carries no capability semantics: this object translates the
// channel's roster and messages into the same public Rooms verbs every other
// server answers. An injected relay grants the optional outbound direction.

import { type Argument, type Behavior, Ref, type Session } from "@pancake/runtime";
import { MAX_NICK, MAX_ROOM, nickRefusal } from "../lib/limits.ts";
import {
	DIRECTORY,
	ENTER,
	ENTER_PUBLICATION,
	LEAVE,
	LINE_BYTES,
	LIST,
	LIST_PUBLICATIONS,
	NOTIFY,
	OPEN,
	POST,
	SUBSCRIBE,
	WATCH,
	WATCH_PUBLICATIONS,
} from "../lib/protocol.ts";
import { bareNamesNick, ctcpActionText, ircFold, type IrcMessage, nickFromPrefix } from "./protocol.ts";
import { IrcChannelRelay } from "./outbound.ts";

export const IRC_ROSTER_LIMIT = 256;
export const ROOMS_VIEWER_LIMIT = 256;

interface Member {
	readonly session: Session;
	readonly nick: string;
	readonly inbox: Ref;
	/** Why this member is away, or empty while they are here. */
	away: string;
}

interface Watcher {
	readonly session: Session;
	readonly inbox: Ref;
	readonly rich: boolean;
}

export class IrcBridgeRoom {
	readonly network: string;
	readonly channel: string;
	readonly roomName: string;
	readonly relay: IrcChannelRelay;
	readonly #members = new Map<Session, Member>();
	readonly #ircNicks = new Map<string, string>();
	readonly #watchers = new Map<Session, Watcher>();
	#namesPending: Map<string, string> | null = null;

	readonly #subscribeNote: ((nick: string) => string | null) | null;
	readonly #ownOutbound: boolean;
	readonly #seatNick: (nick: string) => boolean;

	constructor(
		network: string,
		channel: string,
		relay: IrcChannelRelay,
		options?: {
			subscribeNote?: (nick: string) => string | null;
			ownOutbound?: boolean;
			/** Whether an IRC nick is one of this room's own members speaking
			 * through their own connection. Their channel presence and lines
			 * are the member the room already shows, so echoing them back as
			 * a second `irc/` identity would double every seated member. */
			seatNick?: (nick: string) => boolean;
		},
	) {
		this.#subscribeNote = options?.subscribeNote ?? null;
		this.#ownOutbound = options?.ownOutbound ?? false;
		this.#seatNick = options?.seatNick ?? (() => false);
		if (!/^[A-Za-z0-9][A-Za-z0-9.-]*$/.test(network)) {
			throw new Error("IRC network name uses letters, digits, dots, and hyphens");
		}
		const forbiddenChannel = (c: string): boolean => {
			const code = c.charCodeAt(0);
			return code === 0 || code === 7 || code === 10 || code === 13 || " ,:".includes(c);
		};
		if (!channel.startsWith("#") || [...channel].some(forbiddenChannel)) {
			throw new Error("IRC bridge channel is malformed");
		}
		if (ircFold(relay.channel) !== ircFold(channel)) {
			throw new Error("IRC bridge room and channel relay name different channels");
		}
		this.network = network;
		this.channel = channel;
		this.relay = relay;
		this.roomName = `${network}/${channel}`;
		if (this.roomName.length > MAX_ROOM) {
			throw new Error(`the bridged room name may be at most ${MAX_ROOM} characters`);
		}
	}

	/** Publish this connection's directory under the ordinary Rooms name. */
	publish(session: Session): void {
		session.publish(DIRECTORY, this.directoryBehavior(session));
	}

	retire(session: Session): void {
		this.#dropMember(session, true);
		const watcher = this.#watchers.get(session);
		if (watcher !== undefined) {
			this.#watchers.delete(session);
			this.#release(watcher.session, watcher.inbox);
		}
	}

	/** One IRC connection ended. Its roster was connection-scoped, so retaining
	 * those names would claim presence the bridge can no longer observe. */
	disconnected(): void {
		this.#clearIrcRoster("the IRC connection ended");
	}

	/** The connection remains registered, but this room intentionally parted
	 * its channel and can no longer claim that channel's presence. */
	leftChannel(): void {
		this.#clearIrcRoster("the bridge left the IRC channel");
	}

	#clearIrcRoster(notice: string): void {
		this.#namesPending = null;
		if (this.#ircNicks.size === 0) return;
		this.#ircNicks.clear();
		this.#broadcast("room", notice, "roster", ...this.#visibleNicks());
		this.#notifyCount();
	}

	directoryBehavior(session: Session) {
		return (verb: string, args: Argument[]): Argument => {
			if (verb === ENTER || verb === ENTER_PUBLICATION) {
				if (args[0] !== this.roomName) throw new Error(`no room named "${String(args[0] ?? "")}"`);
				return session.spawn(this.roomBehavior(session));
			}
			if (verb === OPEN) throw new Error("an IRC bridge lists channels; it cannot create one");
			if (verb === LIST) return this.#snapshot(false);
			if (verb === LIST_PUBLICATIONS) return this.#snapshot(true);
			if (verb === WATCH || verb === WATCH_PUBLICATIONS) {
				const inbox = args[0];
				if (!(inbox instanceof Ref)) throw new Error("watch needs an inbox capability");
				const prior = this.#watchers.get(session);
				if (prior === undefined && this.#watchers.size >= ROOMS_VIEWER_LIMIT) {
					throw new Error(`this IRC bridge already has ${ROOMS_VIEWER_LIMIT} directory watchers`);
				}
				if (prior !== undefined) this.#release(prior.session, prior.inbox);
				this.#watchers.set(session, { session, inbox, rich: verb === WATCH_PUBLICATIONS });
				return this.#snapshot(verb === WATCH_PUBLICATIONS);
			}
			throw new Error(`IRC bridge directory has no method ${verb}`);
		};
	}

	roomBehavior(session: Session): Behavior {
		return (verb: string, args: Argument[]) => {
			if (verb === SUBSCRIBE) {
				const nick = typeof args[0] === "string" ? args[0] : "";
				const inbox = args[1];
				const refused = nickRefusal(nick);
				if (refused !== null) throw new Error(refused);
				// This prefix is the bridge's attribution boundary, including for
				// baseline peers that see only the ordinary sender string. Reserving
				// it prevents a native reader from becoming visually identical to an
				// IRC user who arrives later.
				if (ircFold(nick).startsWith("irc/")) {
					throw new Error('names beginning with "irc/" are reserved for bridged IRC identities');
				}
				if (!(inbox instanceof Ref)) throw new Error("subscribe needs an inbox capability");
				if (!this.#members.has(session) && this.#members.size >= ROOMS_VIEWER_LIMIT) {
					throw new Error(`this IRC bridge already has ${ROOMS_VIEWER_LIMIT} Rooms readers`);
				}
				const folded = ircFold(nick);
				if (
					[...this.#ircNicks.values()].some((ircNick) => ircFold(ircNick) === folded) ||
					[...this.#members.values()].some((m) => m.session !== session && ircFold(m.nick) === folded)
				) {
					throw new Error(`the name "${nick}" is already here`);
				}
				this.#dropMember(session, false);
				const member = { session, nick, inbox, away: "" };
				this.#members.set(session, member);
				this.relay.setReaders(this.#members.size);
				this.#broadcast("room", `${nick} joined (${this.#visibleNicks().length} here)`, "join", nick);
				this.#tell(
					member,
					"room",
					this.#subscribeNote?.(nick) ??
						(this.relay.writable
							? `messages are relayed to ${this.channel} as <${nick}>`
							: `IRC messages from ${this.channel} are read-only here`),
					LINE_BYTES,
					BigInt(this.relay.lineBytes),
				);
				this.#tell(member, "room", "who is here", "roster", ...this.#visibleNicks());
				// Who is already away, one line each: the same line every later
				// change arrives on, exactly the native room's shape.
				for (const seated of this.#members.values()) {
					if (seated.away === "" || seated.session === session) continue;
					this.#tell(
						member,
						"room",
						`${seated.nick} is away: ${seated.away}`,
						"away",
						seated.nick,
						seated.away,
					);
				}
				this.#notifyCount();
				return null;
			}
			if (verb === POST) {
				const member = this.#members.get(session);
				if (member === undefined) throw new Error("post needs a claimed room membership");
				if (args.length > 1) throw new Error("an IRC bridge post carries only text");
				const said = typeof args[0] === "string" ? args[0] : "";
				// With outbound owned elsewhere (the gateway's per-reader
				// connections), the relay never carries a post: queueing one on a
				// read-only relay parks the vow forever behind a writable
				// connection that will not come.
				const delivered = this.#ownOutbound ? Promise.resolve() : this.relay.post(member.nick, said);
				this.#broadcast(member.nick, said);
				return delivered.then(() => null);
			}
			if (verb === "away") {
				const member = this.#members.get(session);
				if (member === undefined) throw new Error("away needs a claimed room membership");
				const why = typeof args[0] === "string" ? args[0].slice(0, 200) : "";
				if (why === member.away) return null;
				member.away = why;
				this.#broadcast(
					"room",
					why === "" ? `${member.nick} is back` : `${member.nick} is away: ${why}`,
					"away",
					member.nick,
					why,
				);
				return null;
			}
			if (verb === LEAVE) {
				this.#dropMember(session, true);
				return null;
			}
			throw new Error(`IRC bridge room has no method ${verb}`);
		};
	}

	/** Apply one parsed server message. Registration/PING stay with the socket
	 * driver; channel state and attribution live here. */
	apply(message: IrcMessage): void {
		if (message.command === "353") {
			const channel = message.params.at(-2);
			const names = message.params.at(-1);
			if (channel === undefined || names === undefined || ircFold(channel) !== ircFold(this.channel)) return;
			if (this.#namesPending === null) this.#namesPending = new Map();
			for (const field of names.split(/\s+/)) {
				const nick = bareNamesNick(field);
				if (nick.length > 0 && !this.relay.isSelfNick(nick) && !this.#seatNick(nick)) {
					const display = displayIrcNick(nick);
					if (!this.#namesPending.has(ircFold(display)) && this.#namesPending.size >= IRC_ROSTER_LIMIT) {
						throw new Error(`IRC roster exceeds ${IRC_ROSTER_LIMIT} names`);
					}
					this.#namesPending.set(ircFold(display), display);
				}
			}
			return;
		}
		if (message.command === "366") {
			const channel = message.params.at(-2);
			if (channel !== undefined && ircFold(channel) === ircFold(this.channel) && this.#namesPending !== null) {
				this.#replaceIrcNicks(this.#namesPending);
				this.#namesPending = null;
			}
			return;
		}
		const nick = nickFromPrefix(message.prefix);
		if (nick === null) return;
		if (this.relay.isSelfNick(nick)) return;
		// A seated member's own echo: their JOIN, lines, and rename are the
		// member this room already carries, not a second arrival.
		if (this.#seatNick(nick)) return;
		if (
			message.command === "PRIVMSG" && message.params.length >= 2 &&
			ircFold(message.params[0]) === ircFold(this.channel)
		) {
			// A CTCP ACTION crosses as the rooms wire form for one, so every
			// rooms client draws the action it already knows how to draw.
			const raw = message.params[1];
			const action = ctcpActionText(raw);
			this.#broadcast(displayIrcNick(nick), action === null ? raw : "/me " + action);
			return;
		}
		if (
			(message.command === "TOPIC" && ircFold(message.params[0] ?? "") === ircFold(this.channel)) ||
			(message.command === "332" && ircFold(String(message.params.at(-2) ?? "")) === ircFold(this.channel))
		) {
			const topic = message.params.at(-1) ?? "";
			this.#broadcast("room", `the topic is: ${topic}`, "topic", topic);
			return;
		}
		if (message.command === "JOIN" && ircFold(message.params[0] ?? "") === ircFold(this.channel)) {
			this.#addIrcNick(nick);
			return;
		}
		if (message.command === "PART" && ircFold(message.params[0] ?? "") === ircFold(this.channel)) {
			this.#removeIrcNick(nick);
			return;
		}
		if (message.command === "KICK" && ircFold(message.params[0] ?? "") === ircFold(this.channel)) {
			const kicked = message.params[1];
			if (kicked !== undefined) this.#removeIrcNick(kicked);
			return;
		}
		if (message.command === "QUIT") {
			this.#removeIrcNick(nick);
			return;
		}
		if (message.command === "NICK" && message.params[0] !== undefined) {
			const old = this.#ircNicks.get(ircFold(displayIrcNick(nick)));
			if (old === undefined) return;
			this.#ircNicks.delete(ircFold(old));
			const next = displayIrcNick(message.params[0]);
			this.#ircNicks.set(ircFold(next), next);
			this.#broadcast("room", `${old} is now ${next}`, "leave", old);
			this.#broadcast("room", `${next} joined`, "join", next);
			this.#notifyCount();
		}
	}

	#snapshot(rich: boolean): Argument[] {
		const count = BigInt(this.#visibleNicks().length);
		return [rich ? [this.roomName, count, this.roomName, "local", "", "local"] : [this.roomName, count]];
	}

	#visibleNicks(): string[] {
		return [...this.#ircNicks.values(), ...[...this.#members.values()].map((m) => m.nick)].sort((a, b) =>
			a.localeCompare(b)
		);
	}

	#replaceIrcNicks(next: Map<string, string>): void {
		this.#ircNicks.clear();
		for (const [folded, nick] of next) this.#ircNicks.set(folded, nick);
		this.#broadcast("room", "the IRC roster was refreshed", "roster", ...this.#visibleNicks());
		this.#notifyCount();
	}

	#addIrcNick(nick: string): void {
		const display = displayIrcNick(nick);
		const folded = ircFold(display);
		if (this.#ircNicks.has(folded)) return;
		if (this.#ircNicks.size >= IRC_ROSTER_LIMIT) throw new Error(`IRC roster exceeds ${IRC_ROSTER_LIMIT} names`);
		this.#ircNicks.set(folded, display);
		this.#broadcast("room", `${display} joined IRC`, "join", display);
		this.#notifyCount();
	}

	#removeIrcNick(nick: string): void {
		const folded = ircFold(displayIrcNick(nick));
		const present = this.#ircNicks.get(folded);
		if (present === undefined) return;
		this.#ircNicks.delete(folded);
		this.#broadcast("room", `${present} left IRC`, "leave", present);
		this.#notifyCount();
	}

	/** Say one room line to one member: the gateway's channel for seat news
	 * (a forced rename, a dropped connection) that concerns only them. */
	noteTo(session: Session, text: string): void {
		const member = this.#members.get(session);
		if (member === undefined) return;
		this.#tell(member, "room", text);
	}

	#dropMember(session: Session, announce: boolean): void {
		const member = this.#members.get(session);
		if (member === undefined) return;
		this.#members.delete(session);
		this.#release(session, member.inbox);
		this.relay.setReaders(this.#members.size);
		if (announce) {
			this.#broadcast("room", `${member.nick} left (${this.#visibleNicks().length} here)`, "leave", member.nick);
		}
		this.#notifyCount();
	}

	#notifyCount(): void {
		for (const watcher of this.#watchers.values()) {
			const row = this.#snapshot(watcher.rich)[0] as Argument;
			watcher.session.tell(watcher.inbox, NOTIFY, ["count", ...(row as Argument[])]).catch(() => {});
		}
	}

	#broadcast(from: string, text: string, ...trailing: Argument[]): void {
		for (const member of this.#members.values()) this.#tell(member, from, text, ...trailing);
	}

	#tell(member: Member, from: string, text: string, ...trailing: Argument[]): void {
		member.session.tell(member.inbox, NOTIFY, [from, text, ...trailing]).catch(() => {});
	}

	#release(session: Session, ref: Ref): void {
		try {
			session.release(ref);
		} catch {
			// Session teardown may have reclaimed it first; this class still drops
			// its only JavaScript occurrence and never retries against another session.
		}
	}
}

/** IRC identities stay visibly bridge-backed on every Rooms front, including
 * Goblins peers that know only the baseline notify shape. Refuse a server name
 * that cannot fit without truncating: shortening it would merge identities. */
function displayIrcNick(nick: string): string {
	const display = `irc/${nick}`;
	if (display.length > MAX_NICK || nickRefusal(display) !== null) {
		throw new Error(`IRC nickname cannot be represented safely in Rooms: ${JSON.stringify(nick)}`);
	}
	return display;
}
