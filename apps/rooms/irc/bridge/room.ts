// An IRC channel presented as an ordinary Rooms directory and room.
// The IRC edge carries no capability semantics: this object translates the
// channel's roster and messages into the same public Rooms verbs every other
// server answers. An injected relay grants the optional outbound direction.

import { type Argument, type Behavior, currentSession, Ref, type Session } from "@pancake/runtime";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../../lib/argument_custody.ts";
import { settleCapabilityCleanup } from "../../lib/capability_cleanup.ts";
import { NO_SUCH_ROOM, READ_ONLY_MEMBERSHIP, RoomError } from "../../lib/errors.ts";
import { MAX_AWAY, MAX_ROOM, nickRefusal } from "../../lib/limits.ts";
import {
	AWAY,
	CALLED,
	DIRECTORY,
	ENTER,
	ENTER_PUBLICATION,
	LEAVE,
	LINE_BYTES,
	LIST,
	LIST_PUBLICATIONS,
	MEMBERSHIP_ENDED,
	MEMBERSHIP_KIND,
	NOTIFY,
	OPEN,
	POST,
	PRIVATE,
	ROOM_AUTHORITY_CHANGED,
	ROOM_POLICY,
	SUBSCRIBE,
	WATCH,
	WATCH_PUBLICATIONS,
} from "../../lib/protocol.ts";
import { BRIDGE, SEAT } from "../../lib/protocol_irc.ts";
import { bareNamesNick, ctcpActionText, ircFold, type IrcMessage, nickFromPrefix } from "../protocol.ts";
import { IrcChannelRelay } from "./outbound.ts";
import { IrcRoomWatchers } from "./watchers.ts";
import { IRC_FOREIGN_BADGE, IRC_FOREIGN_SAID, IRC_PREFIX, type IrcSeatView, ircSeatWords } from "./seat.ts";
import { BridgePrefixes } from "../../lib/bridge/prefix.ts";
import { displayIrcNick, IRC_ROSTER_LIMIT, IrcRoster } from "./roster.ts";
import type { RoomMembershipKind } from "../../lib/room/membership.ts";
import type { OneShotRoomAdmission } from "../../lib/room/admission.ts";

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
	seat: Ref | null;
	kind: RoomMembershipKind;
}

export type IrcMembershipWrapper = (behavior: Behavior, memberSession: Session) => Behavior;

export interface PreparedIrcRoomPost {
	readonly from: string;
	readonly text: string;
}

export class IrcBridgeRoom {
	readonly network: string;
	readonly channel: string;
	readonly roomName: string;
	readonly publicationId: string;
	readonly origin: string;
	readonly relay: IrcChannelRelay;
	readonly #members = new Map<Session, Member>();
	readonly #irc = new IrcRoster();
	readonly #watchers: IrcRoomWatchers;
	/** The attribution namespace this bridge's rooms answer to. */
	readonly prefixes: BridgePrefixes;
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
			/** Exact identity of this bridge publication generation. It is
			 * correlation, not authority, and must not be inferred from the room's
			 * display name. */
			publicationId?: string;
			/** Human-readable IRC endpoint or network behind this bridge. */
			origin?: string;
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
			/** The server's namespace, when several bridges share one. */
			prefixes?: BridgePrefixes;
			onTrouble?: (context: string, error: unknown) => void;
		},
	) {
		this.#subscribeNote = options?.subscribeNote ?? null;
		this.prefixes = options?.prefixes ?? new BridgePrefixes();
		this.#ownOutbound = options?.ownOutbound ?? false;
		this.#seatNick = options?.seatNick ?? (() => false);
		this.#seatView = options?.seatView ?? (() => null);
		this.#trouble = options?.onTrouble ?? ((context, error) => {
			console.error(`rooms IRC bridge: ${context}: ${error instanceof Error ? error.message : error}`);
		});
		// One namespace for this server's rooms, and this bridge takes its own
		// place in it. A standalone bridge is the only holder, which is the
		// degenerate case of the same rule the gateway needs with several.
		const refused = this.prefixes.claim(IRC_PREFIX, "irc");
		if (refused !== null) throw new Error(refused);
		// The watchers own their own table and bound; what stays here is the row,
		// because what a count says about this room is this room's to say.
		this.#watchers = new IrcRoomWatchers(ROOMS_VIEWER_LIMIT, {
			release: (session, ref, label) => this.#release(session, ref, label),
			retire: (session) => this.retire(session),
			trouble: (context, error) => this.#trouble(context, error),
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
		this.publicationId = options?.publicationId ?? crypto.randomUUID();
		this.origin = options?.origin ?? network;
		if (this.publicationId === "" || this.publicationId.length > 128) {
			throw new Error("IRC bridge publication identity is malformed");
		}
		if (this.origin === "" || this.origin.length > 256) {
			throw new Error("IRC bridge origin is malformed");
		}
		if (this.roomName.length > MAX_ROOM) {
			throw new Error(`the bridged room name may be at most ${MAX_ROOM} characters`);
		}
	}

	/** Publish this connection's directory under the ordinary Rooms name. */
	publish(session: Session): void {
		session.publish(DIRECTORY, this.directoryBehavior());
	}

	retire(session: Session, ended?: string): void {
		const member = this.#members.get(session);
		if (member != null && ended != null) this.#tell(member, "room", ended, MEMBERSHIP_ENDED);
		this.#dropMember(session, true);
		this.#watchers.drop(session);
	}

	memberSession(nick: string): Session | null {
		const folded = ircFold(nick);
		for (const member of this.#members.values()) if (ircFold(member.nick) === folded) return member.session;
		return null;
	}

	authorityChanged(kind: "manager" | "steward" | "room", token: string): void {
		for (const member of this.#members.values()) {
			this.#tell(member, "room", "", ROOM_AUTHORITY_CHANGED, kind, token, false);
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
		if (!this.#irc.clear()) return;
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
				const expected = verb === ENTER ? this.roomName : this.publicationId;
				if (args.length !== 1 || args[0] !== expected) {
					throw new RoomError(
						NO_SUCH_ROOM,
						verb === ENTER
							? `no room named "${String(args[0] ?? "")}"`
							: "that room publication is not current",
					);
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
				const refusal = this.#watchers.admit(session, inbox, verb === WATCH_PUBLICATIONS);
				if (refusal !== null) refuseCall(session, args, refusal);
				const rooms = this.#snapshot(verb === WATCH_PUBLICATIONS);
				return verb === WATCH_PUBLICATIONS ? [rooms, [], 0n] : rooms;
			}
			throw new Error(`IRC bridge directory has no method ${verb}`);
		};
	}

	roomBehavior(
		options: {
			sessionFor?: () => Session | null;
			wrapMembership?: IrcMembershipWrapper;
			membershipKind?: RoomMembershipKind;
			admission?: OneShotRoomAdmission;
		} = {},
	): Behavior {
		const sessionFor = options.sessionFor ?? currentSession;
		const wrapMembership = options.wrapMembership ?? ((behavior) => behavior);
		const membershipKind = options.membershipKind ?? "participant";
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
				if (options.admission?.available() === false) {
					refuseCall(session, args, "this room invitation was claimed already");
				}
				const refused = nickRefusal(nick);
				if (refused != null) refuseCall(session, args, refused);
				// The attribution boundary, including for baseline peers that see
				// only the ordinary sender string: reserving it stops a native
				// reader becoming visually identical to a bridged one who arrives
				// later. The registry answers rather than a literal here, because
				// the prefix is the server's to grant and a second bridge's is
				// reserved by exactly the same act.
				const reserved = this.prefixes.nickRefusal(nick);
				if (reserved !== null) refuseCall(session, args, reserved);
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
				const member: Member = { session, nick, inbox, away: "", seat: null, kind: membershipKind };
				try {
					member.seat = session.spawn(wrapMembership(this.#membershipBehavior(member, sessionFor), session));
					options.admission?.consume();
				} catch (error) {
					if (member.seat !== null) {
						this.#release(session, member.seat, "unseated IRC bridge membership capability release failed");
					}
					this.#release(session, inbox, "unseated IRC bridge member inbox capability release failed");
					throw error;
				}
				this.#dropMember(session, false);
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
				// Before the roster, always: the next line names members whose rows
				// only mean something once a reader knows which names are not this
				// room's own. A roster that arrived first would be drawn as a list
				// of oddly-spelled Rooms members for as long as it took.
				// The network is the scope: one IRC identity serves every channel on
				// it, so a reader who linked on a sibling channel is already linked
				// here and this is how a client can know that before anyone has.
				this.#tell(member, "room", "", BRIDGE, IRC_PREFIX, IRC_FOREIGN_BADGE, IRC_FOREIGN_SAID, this.network);
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
				return [member.seat, member.kind, null];
			}
			if (verb === CALLED) {
				if (args.length !== 0) throw new Error("called takes no arguments");
				return this.roomName;
			}
			if (verb === PRIVATE) {
				if (args.length !== 0) throw new Error("private takes no arguments");
				return "listed";
			}
			if (verb === ROOM_POLICY) {
				if (args.length !== 0) throw new Error("roomPolicy takes no arguments");
				return ["listed", "open", "open"];
			}
			throw new Error(`IRC bridge room has no method ${verb}`);
		};
	}

	#membershipBehavior(member: Member, sessionFor: () => Session | null): Behavior {
		return (verb, args) => {
			const caller = sessionFor();
			if (caller == null) throw new Error("an IRC bridge membership is reachable only during a session turn");
			if (hasCapabilityArguments(args)) {
				refuseCall(caller, args, `IRC bridge membership ${verb} does not take capability arguments`);
			}
			if (this.#members.get(member.session) !== member) throw new Error("this IRC bridge membership has ended");
			if (verb === MEMBERSHIP_KIND) {
				if (args.length !== 0) throw new Error("membershipKind takes no arguments");
				return member.kind;
			}
			if (verb === POST) {
				if (member.kind !== "participant") {
					throw new RoomError(READ_ONLY_MEMBERSHIP, "this observer membership cannot speak to IRC");
				}
				const post = this.preparePost(member.session, args);
				const delivered = this.#ownOutbound ? Promise.resolve() : this.relay.post(post.from, post.text);
				return delivered.then(() => this.commitPost(post));
			}
			if (verb === AWAY) {
				if (args.length !== 1 || typeof args[0] !== "string") throw new Error("away needs one reason");
				const why = args[0];
				if (why.length > MAX_AWAY) throw new Error(`an away reason may be at most ${MAX_AWAY} characters`);
				if (why === member.away) return null;
				member.away = why;
				this.#broadcast(
					"room",
					why === "" ? `${member.nick} is back` : `${member.nick} is away: ${why}`,
					AWAY,
					member.nick,
					why,
				);
				return null;
			}
			if (verb === LEAVE) {
				if (args.length !== 0) throw new Error("leave takes no arguments");
				this.#dropMember(member.session, true);
				return null;
			}
			throw new Error(`IRC bridge membership has no method ${verb}`);
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
			const renamed = this.#irc.rename(nick, message.params[0]);
			if (renamed === null) return;
			const { was: old, now: next } = renamed;
			this.#broadcast("room", `${old} is now ${next}`, "leave", old);
			this.#broadcast("room", `${next} joined`, "join", next);
			this.#notifyCount();
		}
	}

	#snapshot(rich: boolean): Argument[] {
		const count = BigInt(this.#memberCount());
		return [
			rich
				? [this.roomName, count, this.publicationId, "bridge", this.origin, "bridge", "participant"]
				: [this.roomName, count],
		];
	}

	#memberCount(): number {
		return this.#irc.size + this.#members.size;
	}

	#visibleNicks(): string[] {
		const names = [...this.#irc.names()];
		for (const member of this.#members.values()) names.push(member.nick);
		return names.sort((a, b) => a.localeCompare(b));
	}

	#replaceIrcNicks(next: Map<string, string>): void {
		this.#irc.replace(next);
		this.#broadcast("room", "the IRC roster was refreshed", "roster", ...this.#visibleNicks());
		this.#notifyCount();
	}

	#addIrcNick(nick: string): void {
		const display = this.#irc.add(nick);
		if (display === null) return;
		this.#broadcast("room", `${display} joined IRC`, "join", display);
		this.#notifyCount();
	}

	#removeIrcNick(nick: string): void {
		const present = this.#irc.remove(nick);
		if (present === null) return;
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
		const words = ircSeatWords(view);
		this.#tell(
			member,
			"room",
			"",
			SEAT,
			seated.nick,
			view.phase,
			view.nick,
			view.network,
			words.badge,
			words.said,
		);
	}

	#dropMember(session: Session, announce: boolean): void {
		const member = this.#members.get(session);
		if (member === undefined) return;
		this.#members.delete(session);
		this.#release(session, member.inbox, "IRC bridge member inbox capability release failed");
		if (member.seat !== null) this.#release(session, member.seat, "IRC bridge membership release failed");
		this.relay.setReaders(this.#members.size);
		if (announce) {
			this.#broadcast("room", `${member.nick} left (${this.#memberCount()} here)`, "leave", member.nick);
		}
		this.#notifyCount();
	}

	#notifyCount(): void {
		const count = BigInt(this.#memberCount());
		this.#watchers.notify((rich) =>
			rich
				? [this.roomName, count, this.publicationId, "bridge", this.origin, "bridge", "participant"]
				: [this.roomName, count]
		);
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
