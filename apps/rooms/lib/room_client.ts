// A small, friendly client for the rooms chat, built on pancake actors.
//
// This is the layer that knows about OCapN, and on the connection API it is
// barely a layer at all: connect, fetch the directory by name, ask it to open or
// enter a room (which hands back a live reference to that room), spawn an inbox
// the room can call back, subscribe by handing it that capability, and surface
// the room's callbacks as a stream. Everything above it — the terminal client,
// the web UI — reads like an app, not like a protocol.
//
//   const dir = await Directory.connect("127.0.0.1:9099");
//   const room = await Room.subscribe(dir.session, await dir.enter("general"), "alice");
//   room.say("hello");
//   for await (const msg of room.messages) console.log(msg.from, msg.text);
//   await room.leave();   // drop this room (keeps the connection)
//   await dir.close();    // end the session
//
// `Directory.open` and `enter` mirror the wire one-to-one — strict, each errors
// on the wrong precondition. The friendly "enter, opening it if new" behavior is
// a CLI convenience and lives in the apps (`enter_room.ts`), not here. The room
// name is the directory's lookup key; the room itself is the capability the
// directory returns.

import { annotateSession, type Argument, Ref, type Session } from "@pancake/stack";
// The one rooms dial: both transports, and the rooms codec.
import { dial as roomsDial } from "./locator.ts";
import type { Presence } from "./limits.ts";
import { INTRODUCTION_PENDING, RoomError, roomErrorOf } from "./errors.ts";
import {
	DIRECTORY,
	DM,
	ENTER,
	INTRODUCE,
	LEAVE,
	LIST,
	NOTIFY,
	OFFER_INBOX,
	OFFER_SIGNALING,
	OPEN,
	POST,
	REGISTER,
	SIG_ANSWER,
	SIG_CANDIDATE,
	SIGNAL_ANSWER,
	SIGNAL_CANDIDATE,
	SIGNAL_OFFER,
	SUBSCRIBE,
	TYPING,
	WATCH,
} from "./protocol.ts";

// How long `register` waits for the directory's `notify("registered")` before it
// rejects. A registration whose ack never lands (the server's `registerMember`
// threw) must surface as a failure the caller can retry, not a silent hang; the
// window sits far above the round-trip a healthy directory answers within.
const REGISTER_ACK_TIMEOUT_MS = 10_000;

// How long `introduceVia` waits for the peer to offer an inbox for us after the
// directory has asked them for one. Bounded, because the peer may never answer.
const INTRODUCIBLE_TIMEOUT_MS = 10_000;

/** One live room in the directory: its name and how many people are in it. */
export interface RoomInfo {
	name: string;
	count: number;
}

/** A change to the directory's live state, pushed to a `watch` observer. Some
 * changes are about rooms: a room `opened` when its first member arrived,
 * `closed` when its last left, or changed its member `count`. For those, `name`
 * is the room and `count` is how many are in it. Other changes are about people:
 * a member became `registered` or `unregistered` for direct messages, and there
 * `name` is the member's nick and `count` is 1 or 0. Both kinds arrive on one
 * observer, so switch on `kind` to tell them apart. */
export interface RoomEvent {
	kind: "opened" | "closed" | "count" | "registered" | "unregistered";
	name: string;
	count: number;
}

/** Parse the wire shape of `list`/`watch` — a list of `[name, count]` pairs,
 * counts arriving as `bigint` — into `RoomInfo`s. */
function parseRooms(raw: Argument): RoomInfo[] {
	if (!Array.isArray(raw)) return [];
	const out: RoomInfo[] = [];
	for (const item of raw) {
		if (Array.isArray(item) && item.length >= 2) {
			out.push({ name: String(item[0]), count: Number(item[1]) });
		}
	}
	return out;
}

/** The directory of rooms: the server's one published object. Connect to it,
 * then `open` a new room or `enter` an existing one, each returns a reference
 * to that room. Both mirror the wire: `open` rejects if the name is taken,
 * `enter` rejects if there is no such room. `list` and `watch` are discovery:
 * the rooms that have people in them, as a snapshot or a live feed. The
 * directory owns the connection; close it with `close` when the session ends. */
export class Directory {
	readonly session: Session;
	#directory: Ref;
	// Callers parked in `introduceVia` waiting for a peer to offer them an inbox,
	// by the peer's lowercased nick. Fed by the register inbox's `introducible`.
	readonly #introducible = new Map<string, (() => void)[]>();
	// Peers whose `introducible` arrived with nobody parked on it. The notify
	// dispatches synchronously inside the inbound feed while our own refusal
	// surfaces as a promise rejection on a later microtask, so the wakeup can
	// reach us before the caller it is for.
	readonly #introducibleSeen = new Set<string>();

	private constructor(session: Session, directory: Ref) {
		this.session = session;
		this.#directory = directory;
	}

	/** Dial `locator`, start serving, and fetch the directory by name. `dial`
	 * overrides the stack's default `connect`: the terminal clients pass the
	 * locator-aware Deno dialer (TCP or iroh), the browser stack dials through
	 * its injected adapter and needs no override. */
	static async connect(
		locator: string,
		dial: (locator: string) => Promise<Session> = roomsDial,
	): Promise<Directory> {
		const session = await dial(locator);
		// Start the inbound loop before fetching, so the fetch's resolution arrives.
		session.serve().catch(() => {});
		const directory = await session.fetch(DIRECTORY);
		return new Directory(session, directory);
	}

	/** Create a new room and return a reference to it. Rejects if the name is
	 * taken. */
	open(name: string): Promise<Ref> {
		return this.session.send(this.#directory, OPEN, [name]) as Promise<Ref>;
	}

	/** Return a reference to an existing room. Rejects if there is no such room. */
	enter(name: string): Promise<Ref> {
		return this.session.send(this.#directory, ENTER, [name]) as Promise<Ref>;
	}

	/** The live rooms right now, the ones with people in them. */
	async list(): Promise<RoomInfo[]> {
		return parseRooms(
			await this.session.send(this.#directory, LIST, []) as Argument,
		);
	}

	/** Follow the live room list: spawn an observer the directory calls back with
	 * each change, register it, and return the current snapshot as a baseline.
	 * `onEvent` then fires on every open/close/count change. */
	async watch(onEvent: (event: RoomEvent) => void): Promise<RoomInfo[]> {
		const observer = this.session.spawn((verb, args) => {
			if (verb !== NOTIFY) throw new Error(`watch inbox has no method ${verb}`);
			onEvent({
				kind: (typeof args[0] === "string" ? args[0] : "count") as RoomEvent[
					"kind"
				],
				name: typeof args[1] === "string" ? args[1] : "",
				count: Number(args[2] ?? 0),
			});
			return null;
		});
		return parseRooms(
			await this.session.send(this.#directory, WATCH, [observer]) as Argument,
		);
	}

	/** Announce a member for DM introduce. `locator` is the listen address redeem
	 * should dial. Resolves on `notify("registered", …)`.
	 *
	 * `onMintInboxFor` fires when the directory needs an inbox for a named peer.
	 * Supply one to be reachable by direct message at all: without it every
	 * `introduce` aimed here stays pending. Answer it with `offerInbox`. */
	register(
		nick: string,
		locator: string,
		onMintInboxFor?: (peer: string) => void,
	): Promise<void> {
		return new Promise((resolve, reject) => {
			// The timeout is armed before `settle` exists because `settle` has to
			// clear it. Neither forward reference runs early: the callback below
			// is stored, not called, and the block finishes before any task can
			// fire it.
			const timer = setTimeout(
				() =>
					settle(() =>
						reject(new Error(`register("${nick}") was not acknowledged in time`))
					),
				REGISTER_ACK_TIMEOUT_MS,
			);
			const settle = (run: () => void) => {
				clearTimeout(timer);
				run();
			};
			const inbox = this.session.spawn((verb, args) => {
				if (verb !== NOTIFY) return null;
				const event = args[0];
				const peer = typeof args[1] === "string" ? args[1] : "";
				if (event === "registered") settle(resolve);
				else if (event === "mintInboxFor" && peer) onMintInboxFor?.(peer);
				else if (event === "introducible" && peer) this.#wakeIntroducible(peer);
				return null;
			});
			// A real reject edge: a dropped `send` (the directory session died
			// mid-register) and an ack that never arrives both surface as a failure
			// the caller can retry, instead of a promise that only ever resolves or
			// hangs — a hang would pin the caller out of the DM roster silently.
			this.session.send(this.#directory, REGISTER, [nick, locator, inbox]).catch(
				(err) => settle(() => reject(err)),
			);
		});
	}

	/** Ask the directory to introduce us to a registered member, returning a live
	 * reference to that member's `dm` object. The directory answers with a
	 * `desc:handoff-give`, and the binding redeems it by dialing the member
	 * directly. The reference we get back therefore talks to the member over our
	 * own connection, not through the directory.
	 *
	 * `register` first: the directory reads the asker's name off its own
	 * registration, never from the message, so an unregistered caller has no name
	 * an inbox could have been minted for. Rejects if no member with that nick is
	 * registered. */
	async introduce(nick: string): Promise<Ref> {
		return (await this.introduceVia(nick)).dm;
	}

	/** Introduce us to a member, returning both the member's `dm` reference and
	 * the direct `Session` the redeem dialed to reach it (`via`). Hosting a reply
	 * inbox on `via` and sending the DM over `via` lets the member answer us back
	 * over that same connection — the bidirectional completion of the
	 * introduction, which is the only way a member can reach a caller (a browser,
	 * say) that cannot itself be dialed. `via` is null only if the reply named no
	 * fresh redeem. Requires a `register`, like `introduce`. Rejects if no member
	 * with that nick is registered. */
	async introduceVia(nick: string): Promise<{ dm: Ref; via: Session | null }> {
		try {
			return await this.#introduceOnce(nick);
		} catch (err) {
			if (roomErrorOf(err)?.code !== INTRODUCTION_PENDING) throw err;
		}
		// First contact with this peer: the directory has just asked them for an
		// inbox for us. Wait for the offer to land, then ask again.
		//
		// Twice, because a wakeup recorded before we asked may be spent: the
		// directory drops a member's offers whenever either name changes hands, so
		// an `introducible` we banked can name an inbox that no longer exists. A
		// retry refused again therefore waits for a fresh notify rather than
		// reporting failure on the strength of an old one.
		for (let attempt = 0; attempt < 2; attempt += 1) {
			await this.#awaitIntroducible(nick, attempt === 0);
			try {
				return await this.#introduceOnce(nick);
			} catch (err) {
				if (roomErrorOf(err)?.code !== INTRODUCTION_PENDING) throw err;
			}
		}
		throw new RoomError(
			INTRODUCTION_PENDING,
			`"${nick}" did not offer an inbox for us`,
		);
	}

	async #introduceOnce(nick: string): Promise<{ dm: Ref; via: Session | null }> {
		const { reply, via } = await this.session.sendRedeeming(this.#directory, INTRODUCE, [nick]);
		if (!(reply instanceof Ref)) {
			throw new Error(`introduce("${nick}") did not return a capability`);
		}
		return { dm: reply, via };
	}

	#wakeIntroducible(peer: string): void {
		const key = peer.toLowerCase();
		const waiting = this.#introducible.get(key);
		this.#introducible.delete(key);
		// A list every waiter has timed out of is the same as no list: bank the
		// wakeup, or it reaches nobody and the next caller parks on a signal that
		// has already been sent.
		if (waiting === undefined || waiting.length === 0) {
			this.#introducibleSeen.add(key);
			return;
		}
		for (const wake of waiting) wake();
	}

	/** Wait for `nick` to offer us an inbox. `useBanked` spends a wakeup that
	 * arrived before this call; the retry pass passes false, so it waits for a
	 * fresh one. */
	#awaitIntroducible(nick: string, useBanked: boolean): Promise<void> {
		const key = nick.toLowerCase();
		if (useBanked && this.#introducibleSeen.delete(key)) return Promise.resolve();
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				const waiting = this.#introducible.get(key);
				if (waiting !== undefined) {
					const i = waiting.indexOf(wake);
					if (i >= 0) waiting.splice(i, 1);
					// Drop the row with its last waiter, or the map keeps one per peer
					// ever waited on for the session's life.
					if (waiting.length === 0) this.#introducible.delete(key);
				}
				reject(
					new RoomError(
						INTRODUCTION_PENDING,
						`"${nick}" did not offer an inbox for us in time`,
					),
				);
			}, INTRODUCIBLE_TIMEOUT_MS);
			const wake = () => {
				clearTimeout(timer);
				resolve();
			};
			const waiting = this.#introducible.get(key);
			if (waiting === undefined) this.#introducible.set(key, [wake]);
			else waiting.push(wake);
		});
	}

	/** Offer the directory an inbox for one named peer, the answer to a
	 * `mintInboxFor` request. */
	async offerInbox(forNick: string, inbox: Ref): Promise<void> {
		await this.session.send(this.#directory, OFFER_INBOX, [forNick, inbox]);
	}

	// ── WebRTC signaling carried by the directory (ADR-0089) ────────────────
	// One row per target designator: the reply capability the answer and the
	// far peer's candidates ride back on, plus whoever is waiting on each.
	readonly #signals = new Map<
		string,
		{
			reply: Ref;
			onAnswer: ((sdp: string) => void) | null;
			sink: ((ice: string) => void) | null;
		}
	>();

	#signalRow(designator: string) {
		let row = this.#signals.get(designator);
		if (row === undefined) {
			const fresh = {
				reply: null as unknown as Ref,
				onAnswer: null as ((sdp: string) => void) | null,
				sink: null as ((ice: string) => void) | null,
			};
			fresh.reply = this.session.spawn((verb, args) => {
				if (verb === SIG_ANSWER) {
					fresh.onAnswer?.(typeof args[0] === "string" ? args[0] : "");
				} else if (verb === SIG_CANDIDATE) {
					fresh.sink?.(typeof args[0] === "string" ? args[0] : "");
				}
				return null;
			});
			this.#signals.set(designator, fresh);
			row = fresh;
		}
		return row;
	}

	/** File this member's WebRTC signaling inbox with the directory
	 * (`offerSignaling`): offers and candidates aimed at this member's `webrtc`
	 * designator arrive on it as `offer(id, sdp)` / `candidate(id, ice)`. */
	async offerSignaling(inbox: Ref): Promise<void> {
		await this.session.send(this.#directory, OFFER_SIGNALING, [inbox]);
	}

	/** Start one signaling exchange toward `designator` and resolve the far
	 * peer's SDP answer. The answer rides a reply capability this method spawns,
	 * because directory behaviors return nothing (every signaling message is an
	 * eventual send). */
	async signalOffer(designator: string, sdp: string): Promise<string> {
		const row = this.#signalRow(designator);
		const answer = new Promise<string>((resolve) => (row.onAnswer = resolve));
		await this.session.send(this.#directory, SIGNAL_OFFER, [designator, sdp, row.reply]);
		return answer;
	}

	/** Answer exchange `id` with this member's SDP answer (the answering half). */
	signalAnswer(id: string, sdp: string): void {
		this.session.tell(this.#directory, SIGNAL_ANSWER, [id, sdp]).catch(() => {});
	}

	/** Trickle one ICE candidate. `key` is the target's designator on the
	 * offering side, or the exchange id on the answering side; the directory
	 * resolves which from the calling session. */
	signalCandidate(key: string, ice: string): void {
		this.session.tell(this.#directory, SIGNAL_CANDIDATE, [key, ice]).catch(() => {});
	}

	/** Register the sink for candidates the far peer of `designator`'s exchange
	 * trickles back. Returns a disposer. */
	onSignalCandidate(designator: string, sink: (ice: string) => void): () => void {
		const row = this.#signalRow(designator);
		row.sink = sink;
		return () => {
			if (row.sink === sink) row.sink = null;
		};
	}

	/** Close the session, ending every room's `messages` stream. */
	async close(): Promise<void> {
		this.session.close();
		await this.session.serve().catch(() => {});
	}
}

/** A live, direct line to one member, obtained by introduction. `DirectMessage.open`
 * asks the directory to introduce you and wraps the redeemed capability. `say`
 * then delivers a message straight to that member over your own connection. The
 * directory is not on the message path. It vouched for the introduction once, and
 * after that the two of you talk without it.
 *
 * The line is bidirectional. It hosts a reply inbox on the very connection the
 * redeem opened and hands it to the member with each message, so the member
 * answers you back over that same connection — even though you never listen. An
 * `onReply` handler passed to `open` receives those replies. */
/** How many live lines ride each redeemed exporter connection.
 *
 * A redeem to an exporter this host has already dialed resolves the *same*
 * live session rather than opening a second one — `sendRedeeming` says so, and
 * `zig build demo-rooms-dm-reredeem` proves it. So two lines to one member
 * share one connection, and "did a route come back" is not the same question
 * as "did this line open it". Closing on the first answer hangs up a
 * connection the other line is still talking on.
 *
 * Held weakly and keyed by the session itself, so a connection dropped without
 * a close takes its row with it rather than pinning one forever. */
const linesOnSession = new WeakMap<Session, number>();

export class DirectMessage {
	#session: Session;
	#dm: Ref;
	#replyInbox: Ref | null;
	// Whether this line dialed the connection it rides. A redeemed introduction
	// opens one to the member and owns it; a send-only line rides the directory's
	// and must never close it, since everything else the tab is doing is on it.
	#ownsSession: boolean;
	#spent = false;
	readonly peer: string;

	/** Whether the connection this line rides is still open. A line outlives
	 * the peer that went offline, and every send on it fails; asking first lets
	 * a caller re-introduce instead of spending a message to find out. */
	get live(): boolean {
		return this.#session.sessionOpen;
	}

	private constructor(
		session: Session,
		dm: Ref,
		peer: string,
		replyInbox: Ref | null,
		ownsSession: boolean,
	) {
		this.#session = session;
		this.#dm = dm;
		this.peer = peer;
		this.#replyInbox = replyInbox;
		this.#ownsSession = ownsSession;
	}

	/** Give this line back.
	 *
	 * A redeemed introduction is a connection to the member, held open for as
	 * long as the line is. Dropping the reference to a `DirectMessage` does not
	 * end that connection, and the reply inbox this side exported stays live on
	 * it; closing does both, and releases the imported capability with the
	 * session that carried it. A send-only line dialed nothing and rides the
	 * directory's connection, so closing it is a no-op rather than a hang-up on
	 * everything else the caller is doing.
	 *
	 * The peer is unaffected: nothing was taken from them, and a later `open`
	 * redeems a fresh introduction. */
	close(): void {
		// Spent once. A second close would decrement a count this line has
		// already given up and hang up on whoever holds the connection now.
		if (this.#spent) return;
		this.#spent = true;
		if (this.#ownsSession) {
			const rest = (linesOnSession.get(this.#session) ?? 1) - 1;
			if (rest > 0) {
				// Another line is still talking on this connection. Give back
				// what was this line's — the imported capability — and leave the
				// connection to the lines that are still using it.
				linesOnSession.set(this.#session, rest);
				this.#session.release(this.#dm);
				return;
			}
			linesOnSession.delete(this.#session);
			// Last line out. Closing the connection reclaims everything on it,
			// imports included.
			this.#session.close();
			return;
		}
		// A send-only line rides the directory's connection, which the tab still
		// needs, so closing is not an option — but the member's capability was
		// this line's to hold and is now nobody's. Give it back, so the exporter
		// can drop the matching export instead of keeping it alive for the life
		// of the tab. The handle is spent afterwards; `say` on a closed line
		// throws rather than reaching whatever that position names next.
		this.#session.release(this.#dm);
	}

	/** Open a direct line to `peer` by asking `dir` to introduce you. `onReply`,
	 * if given, fires with each reply the member sends back over the direct
	 * connection; it is the member we were introduced to, so no name is carried. */
	static async open(
		dir: Directory,
		peer: string,
		onReply?: (text: string) => void,
	): Promise<DirectMessage> {
		const { dm, via } = await dir.introduceVia(peer);
		// The reply inbox must live on the connection the redeemed capability
		// routes to (`via`), so it is a valid near export the member can call
		// back. Without a `via` (no fresh redeem) there is no connection to host
		// it on, so the line is send-only.
		const session = via ?? dir.session;
		let replyInbox: Ref | null = null;
		if (onReply && via) {
			replyInbox = session.spawn((verb, args) => {
				if (verb !== DM) throw new Error(`dm reply inbox has no method ${verb}`);
				onReply(typeof args[0] === "string" ? args[0] : "");
				return null;
			});
		}
		// Name the direct connection for whoever is watching the live timeline.
		// Only a redeemed one: a send-only line rides the directory's connection,
		// whose partner is the room and not this member. The annotation is a
		// claim about what the session carries, never identity — a consumer may
		// display it and must not merge or split peers on it.
		if (via) annotateSession(via, { label: peer });
		const owns = via !== undefined && via !== null;
		// Count this line onto the connection before handing it over, so a
		// close knows whether it is the last one out.
		if (owns) linesOnSession.set(session, (linesOnSession.get(session) ?? 0) + 1);
		return new DirectMessage(session, dm, peer, replyInbox, owns);
	}

	/** Deliver one direct message to the peer. There is no sender argument (see
	 * `offerInbox` in `protocol.ts`). Carries the reply inbox when this line has
	 * one, so the member can answer. */
	async say(text: string): Promise<void> {
		const args: Argument[] = this.#replyInbox ? [text, this.#replyInbox] : [text];
		await this.#session.send(this.#dm, DM, args);
	}

	/** Flag whether we are typing to this peer — the direct sibling of
	 * `Room.setTyping`, with the same posture: fire-and-forget (`tell`), so a
	 * lost flag costs nothing and never blocks a keystroke, and an inbox that
	 * predates the verb breaks the tell silently. */
	typing(on: boolean): Promise<void> {
		return this.#session.tell(this.#dm, TYPING, [on]).catch(() => {});
	}
}

/** One line in the room. `system` is true for the room's own announcements (a
 * member joining, your welcome); otherwise `from` is the member who said it.
 * `presence` is set on a system line that is a membership change — the roster on
 * arrival, or a join/leave — carried as structured wire args, not scraped from the
 * text. */
export interface Message {
	from: string;
	text: string;
	system: boolean;
	presence?: Presence;
}

/** Read the structured presence a room line carries after its display text:
 * `notify("room", text, "roster", ...names)` or `notify("room", text, kind, nick)`.
 * Ordinary chat lines carry none. */
export function readPresence(args: Argument[]): Presence | undefined {
	const kind = args[2];
	if (kind === "roster") {
		return {
			kind: "roster",
			names: args.slice(3).filter((n): n is string => typeof n === "string"),
		};
	}
	if ((kind === "join" || kind === "leave") && typeof args[3] === "string") {
		return { kind, name: args[3] };
	}
	return undefined;
}

/** A membership in a chat room. Get one with `Room.subscribe` (the app's
 * `joinRoom` in `enter_room.ts` is the friendly wrapper), read `messages`, call
 * `say`, and `leave` when you are done. */
export class Room {
	#session: Session;
	#room: Ref;
	// Captured synchronously by the ReadableStream `start` callback.
	#lines!: ReadableStreamDefaultController<Message>;
	#leaving = false;

	/** The lines the room sends you, in order, as an async stream. The stream ends
	 * when you `leave` or the room hangs up. */
	readonly messages: ReadableStream<Message>;

	private constructor(session: Session, room: Ref) {
		this.#session = session;
		this.#room = room;
		this.messages = new ReadableStream<Message>({
			start: (controller) => {
				this.#lines = controller;
			},
		});
	}

	/** Subscribe to a room you already hold a reference to, on an open connection.
	 * Publishes the inbox, hands the room that capability, and surfaces the
	 * room's callbacks on `messages`. `onTyping`, if given, fires with each
	 * other member's ephemeral typing flag; those signals never reach `messages`. */
	static async subscribe(
		session: Session,
		roomRef: Ref,
		nick: string,
		onTyping?: (from: string, on: boolean) => void,
	): Promise<Room> {
		const self = new Room(session, roomRef);

		// The room calls this back with every line; surface it on `messages`. A system
		// line may carry a structured presence change after its text.
		const inbox = session.spawn((verb, args) => {
			if (verb !== NOTIFY) throw new Error(`inbox has no method ${verb}`);
			// A typing flag is ephemeral presence, not a line: it carries no text and
			// must never enter the message stream. Route it to `onTyping` and stop.
			if (args[2] === "typing" && typeof args[3] === "string") {
				onTyping?.(args[3], args[4] === true);
				return null;
			}
			const from = typeof args[0] === "string" ? args[0] : "?";
			const text = typeof args[1] === "string" ? args[1] : "";
			self.#emit(from, text, readPresence(args));
			return null;
		});

		// End the message stream when the connection closes. A dropped connection
		// rejects serve(), which is expected here, so catch it rather than leak an
		// unhandled rejection.
		session.serve().finally(() => self.#endStream()).catch(() => {});

		// Subscribe, handing the room a capability to our inbox. Success is the
		// resolution — the room delivers the welcome and the roster as our first
		// `notify`, not as a return value. A rejected claim (e.g. the nickname is taken)
		// propagates; the connection stays open, the directory owns it, and the caller
		// may try another room or close the session itself.
		await session.send(roomRef, SUBSCRIBE, [nick, inbox]);
		return self;
	}

	/** Say a line to everyone in the room. */
	async say(text: string): Promise<void> {
		await this.#session.send(this.#room, POST, [text]);
	}

	/** Flag whether we are typing in this room. Fire-and-forget (`tell`, no reply):
	 * a typing signal is ephemeral, so a lost one costs nothing and never blocks a
	 * keystroke. The room drops it silently if we are no longer subscribed. */
	setTyping(on: boolean): Promise<void> {
		return this.#session.tell(this.#room, TYPING, [on]).catch(() => {});
	}

	/** Leave this room — drop the membership and end the `messages` stream —
	 * without closing the connection, so the same connection can enter another
	 * room. Close the session itself with `Directory.close`. */
	async leave(): Promise<void> {
		this.#leaving = true;
		await this.#session.send(this.#room, LEAVE, []).catch(() => {});
		this.#endStream();
	}

	#emit(from: string, text: string, presence?: Presence): void {
		try {
			this.#lines.enqueue({ from, text, system: from === "room", presence });
		} catch {
			// The stream is already closed (we have left), drop the late line.
		}
	}

	#endStream(): void {
		if (!this.#leaving) console.error("rooms: the room closed the connection");
		try {
			this.#lines.close();
		} catch {
			// Already closed.
		}
	}
}
