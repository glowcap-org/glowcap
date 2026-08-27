// An IRC channel presented as an ordinary Rooms directory and room.
// The IRC edge carries no capability semantics: this object translates the
// channel's roster and messages into the same public Rooms verbs every other
// server answers. An injected relay grants the optional outbound direction.

import { type Argument, type Behavior, currentSession, Ref, type Session } from "@pancake/runtime";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";
import { MAX_AWAY, MAX_NICK, MAX_ROOM, nickRefusal } from "../lib/limits.ts";
import {
	AWAY,
	DIRECTORY,
	ENTER,
	ENTER_PUBLICATION,
	IRC_SEAT,
	type IrcSeatPhase,
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

const DIRECTORY_CAPABILITY_VERBS = new Set([WATCH, WATCH_PUBLICATIONS]);

function refuseCall(session: Session, args: readonly Argument[], message: string): never {
	throwAfterReleasingCapabilities(session, args, new Error(message));
}

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

export interface PreparedIrcRoomPost {
	readonly from: string;
	readonly text: string;
}

export interface IrcSeatView {
	readonly phase: IrcSeatPhase;
	readonly nick: string;
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
	readonly #seatView: (session: Session) => IrcSeatView | null;
	readonly #trouble: (context: string, error: unknown) => void;

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
			/** The gateway-owned IRC projection for one Rooms membership. The room
			 * reads it for arrival replay and never keeps a second seat state. */
			seatView?: (session: Session) => IrcSeatView | null;
			onTrouble?: (context: string, error: unknown) => void;
		},
	) {
		this.#subscribeNote = options?.subscribeNote ?? null;
		this.#ownOutbound = options?.ownOutbound ?? false;
		this.#seatNick = options?.seatNick ?? (() => false);
		this.#seatView = options?.seatView ?? (() => null);
		this.#trouble = options?.onTrouble ?? ((context, error) => {
			console.error(`rooms IRC bridge: ${context}: ${error instanceof Error ? error.message : error}`);
		});
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
		session.publish(DIRECTORY, this.directoryBehavior());
	}

	retire(session: Session): void {
		this.#dropMember(session, true);
		const watcher = this.#watchers.get(session);
		if (watcher !== undefined) {
			this.#watchers.delete(session);
			this.#release(watcher.session, watcher.inbox, "IRC bridge watcher capability release failed");
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

	directoryBehavior(sessionFor: () => Session | null = currentSession) {
		return (verb: string, args: Argument[]): Argument => {
			const session = sessionFor();
			if (session == null) throw new Error("an IRC bridge directory is reachable only during a session turn");
			if (!DIRECTORY_CAPABILITY_VERBS.has(verb) && hasCapabilityArguments(args)) {
				refuseCall(session, args, `IRC bridge directory ${verb} does not take capability arguments`);
			}
			if (verb === ENTER || verb === ENTER_PUBLICATION) {
				if (args.length !== 1 || args[0] !== this.roomName) {
					throw new Error(`no room named "${String(args[0] ?? "")}"`);
				}
				return session.spawn(this.roomBehavior());
			}
			if (verb === OPEN) throw new Error("an IRC bridge lists channels; it cannot create one");
			if (verb === LIST) {
				if (args.length !== 0) throw new Error("list takes no arguments");
				return this.#snapshot(false);
			}
			if (verb === LIST_PUBLICATIONS) {
				if (args.length !== 0) throw new Error("listPublications takes no arguments");
				return this.#snapshot(true);
			}
			if (verb === WATCH || verb === WATCH_PUBLICATIONS) {
				const inbox = args[0];
				if (args.length !== 1 || !(inbox instanceof Ref)) {
					refuseCall(session, args, "watch needs one inbox capability");
				}
				const prior = this.#watchers.get(session);
				if (prior === undefined && this.#watchers.size >= ROOMS_VIEWER_LIMIT) {
					refuseCall(
						session,
						args,
						`this IRC bridge already has ${ROOMS_VIEWER_LIMIT} directory watchers`,
					);
				}
				if (prior !== undefined) {
					this.#release(prior.session, prior.inbox, "replaced IRC bridge watcher capability release failed");
				}
				this.#watchers.set(session, { session, inbox, rich: verb === WATCH_PUBLICATIONS });
				const rooms = this.#snapshot(verb === WATCH_PUBLICATIONS);
				return verb === WATCH_PUBLICATIONS ? [rooms, [], 0n] : rooms;
			}
			throw new Error(`IRC bridge directory has no method ${verb}`);
		};
	}

	roomBehavior(sessionFor: () => Session | null = currentSession): Behavior {
		return (verb: string, args: Argument[]) => {
			const session = sessionFor();
			if (session == null) throw new Error("an IRC bridge room is reachable only during a session turn");
			if (verb !== SUBSCRIBE && hasCapabilityArguments(args)) {
				refuseCall(session, args, `IRC bridge room ${verb} does not take capability arguments`);
			}
			if (verb === SUBSCRIBE) {
				const nick = typeof args[0] === "string" ? args[0] : "";
				const inbox = args[1];
				if (args.length !== 2 || !(inbox instanceof Ref)) {
					refuseCall(session, args, "subscribe needs one name and inbox capability");
				}
				const refused = nickRefusal(nick);
				if (refused != null) refuseCall(session, args, refused);
				// This prefix is the bridge's attribution boundary, including for
				// baseline peers that see only the ordinary sender string. Reserving
				// it prevents a native reader from becoming visually identical to an
				// IRC user who arrives later.
				if (ircFold(nick).startsWith("irc/")) {
					refuseCall(session, args, 'names beginning with "irc/" are reserved for bridged IRC identities');
				}
				if (!this.#members.has(session) && this.#members.size >= ROOMS_VIEWER_LIMIT) {
					refuseCall(session, args, `this IRC bridge already has ${ROOMS_VIEWER_LIMIT} Rooms readers`);
				}
				const folded = ircFold(nick);
				let nameTaken = false;
				for (const member of this.#members.values()) {
					if (member.session !== session && ircFold(member.nick) === folded) {
						nameTaken = true;
						break;
					}
				}
				if (nameTaken) {
					refuseCall(session, args, `the name "${nick}" is already here`);
				}
				this.#dropMember(session, false);
				const member = { session, nick, inbox, away: "" };
				this.#members.set(session, member);
				this.relay.setReaders(this.#members.size);
				this.#broadcast("room", `${nick} joined (${this.#memberCount()} here)`, "join", nick);
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
				for (const seated of this.#members.values()) this.#tellSeat(member, seated);
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
				const post = this.preparePost(session, args);
				// With outbound owned elsewhere (the gateway's per-reader
				// connections), the relay never carries a post: queueing one on a
				// read-only relay parks the vow forever behind a writable
				// connection that will not come.
				const delivered = this.#ownOutbound ? Promise.resolve() : this.relay.post(post.from, post.text);
				return delivered.then(() => this.commitPost(post));
			}
			if (verb === AWAY) {
				const member = this.#members.get(session);
				if (member === undefined) throw new Error("away needs a claimed room membership");
				if (args.length !== 1 || typeof args[0] !== "string") throw new Error("away needs one reason");
				const why = args[0];
				if (why.length > MAX_AWAY) throw new Error(`an away reason may be at most ${MAX_AWAY} characters`);
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
				if (args.length !== 0) throw new Error("leave takes no arguments");
				this.#dropMember(session, true);
				return null;
			}
			throw new Error(`IRC bridge room has no method ${verb}`);
		};
	}

	/** Admit one post without changing either side. The gateway wrapper can then
	 * deliver it to IRC and commit the same captured authorship to Rooms. */
	preparePost(session: Session, args: readonly Argument[]): PreparedIrcRoomPost {
		const member = this.#members.get(session);
		if (member === undefined) throw new Error("post needs a claimed room membership");
		if (args.length !== 1 || typeof args[0] !== "string") {
			throw new Error("an IRC bridge post needs exactly one text line");
		}
		return { from: member.nick, text: args[0] };
	}

	/** Echo a post already accepted by its IRC delivery. */
	commitPost(post: PreparedIrcRoomPost): null {
		this.#broadcast(post.from, post.text);
		return null;
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
		const count = BigInt(this.#memberCount());
		return [rich ? [this.roomName, count, this.roomName, "local", "", "local"] : [this.roomName, count]];
	}

	#memberCount(): number {
		return this.#ircNicks.size + this.#members.size;
	}

	#visibleNicks(): string[] {
		const names: string[] = [];
		for (const nick of this.#ircNicks.values()) names.push(nick);
		for (const member of this.#members.values()) names.push(member.nick);
		return names.sort((a, b) => a.localeCompare(b));
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

	/** Broadcast the gateway-owned IRC projection for one Rooms member. The
	 * member row already exists, so this changes its treatment rather than
	 * inventing a second identity. */
	seatChanged(session: Session): void {
		const seated = this.#members.get(session);
		if (seated === undefined) return;
		const view = this.#seatView(seated.session);
		if (view === null) return;
		for (const member of this.#members.values()) this.#tellSeat(member, seated, view);
	}

	#tellSeat(member: Member, seated: Member, known?: IrcSeatView): void {
		const view = known ?? this.#seatView(seated.session);
		if (view === null) return;
		this.#tell(member, "room", "", IRC_SEAT, seated.nick, view.phase, view.nick);
	}

	#dropMember(session: Session, announce: boolean): void {
		const member = this.#members.get(session);
		if (member === undefined) return;
		this.#members.delete(session);
		this.#release(session, member.inbox, "IRC bridge member inbox capability release failed");
		this.relay.setReaders(this.#members.size);
		if (announce) {
			this.#broadcast("room", `${member.nick} left (${this.#memberCount()} here)`, "leave", member.nick);
		}
		this.#notifyCount();
	}

	#notifyCount(): void {
		const count = BigInt(this.#memberCount());
		for (const watcher of this.#watchers.values()) {
			const row: Argument[] = watcher.rich
				? [this.roomName, count, this.roomName, "local", "", "local"]
				: [this.roomName, count];
			watcher.session.tell(watcher.inbox, NOTIFY, ["count", ...row]).catch((error) => {
				if (!watcher.session.sessionOpen) {
					this.retire(watcher.session);
					return;
				}
				this.#trouble("directory watcher notification failed", error);
			});
		}
	}

	#broadcast(from: string, text: string, ...trailing: Argument[]): void {
		for (const member of this.#members.values()) this.#tell(member, from, text, ...trailing);
		// A roster is a full replacement on every Rooms client. Replay the
		// gateway-owned seat projections immediately after it, so clearing IRC
		// names cannot also erase the link state of native Rooms members.
		if (trailing[0] === "roster") {
			for (const seated of this.#members.values()) {
				const view = this.#seatView(seated.session);
				if (view === null) continue;
				for (const member of this.#members.values()) this.#tellSeat(member, seated, view);
			}
		}
	}

	#tell(member: Member, from: string, text: string, ...trailing: Argument[]): void {
		member.session.tell(member.inbox, NOTIFY, [from, text, ...trailing]).catch((error) => {
			if (!member.session.sessionOpen) {
				this.retire(member.session);
				return;
			}
			this.#trouble(`member notification to ${member.nick} failed`, error);
		});
	}

	#release(session: Session, ref: Ref, label: string): void {
		settleCapabilityCleanup(label, () => session.release(ref));
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
