// A small, friendly client for the rooms chat, built on glowcap actors.
//
// This is the layer that knows about OCapN, and on the connection API it is
// barely a layer at all: connect, fetch the directory by name, ask it to open or
// enter a room (which hands back an entrance reference), spawn an inbox the
// room can call back, subscribe by handing it that capability, and surface
// the room's callbacks as a stream. Everything above it — the terminal client,
// the web UI — reads like an app, not like a protocol.
//
//   const dir = await Directory.connect("127.0.0.1:9099", dial);
//   const room = await Room.subscribe(dir.session, await dir.enter("general"), "alice");
//   room.say("hello");
//   for await (const msg of room.messages) console.log(msg.from, msg.text);
//   await room.leave();   // drop this room (keeps the connection)
//   await dir.close();    // end the session
//
// `Directory.open` and `enter` mirror the wire one-to-one — strict, each errors
// on the wrong precondition. The friendly "enter, opening it if new" behavior is
// a CLI convenience and lives in the apps (`enter_room.ts`), not here. The room
// name is the directory's lookup key; the entrance is the capability the
// directory returns, and the subscription answer carries the live membership.

import { Ref, retainCleanupFailures, retainSecondaryFailure } from "@glowcap/runtime";
import type { BridgeAnswers, BridgeForm } from "../bridge/form.ts";
import { answerBridgeForm, askBridgeForm } from "../bridge/wire.ts";
import type { Session } from "@glowcap/runtime";
import {
	type Attachment,
	type AttachmentSource,
	beginUpload,
	discardUpload,
	fetchBlob,
	fetchBlobChunk,
	fillUpload,
	postStagedFiles,
} from "../attachment.ts";
import {
	AWAY,
	CALLED,
	HISTORY,
	LEAVE,
	MINT_INVITATION,
	POST,
	PRIVATE,
	ROOM_POLICY,
	SET_TOPIC,
	SUBSCRIBE,
	TYPING,
} from "../protocol.ts";
import { RoomStewardship } from "./stewardship.ts";
import { managedRoomIdentity } from "./manager.ts";
import type { RoomAuthorityChange } from "./authority.ts";
import { readMembershipAnswer, type RoomMembershipKind } from "./membership.ts";
import { RoomMessageStream } from "./message_stream.ts";
import { settleCapabilityCleanup } from "../capability_cleanup.ts";
import { roomInboxBehavior } from "./inbox.ts";
import { answerWithin } from "../deadline.ts";
import { REQUEST_TIMEOUT_MS } from "../limits.ts";
import { RoomInvitation } from "./invitation.ts";
import { parseRoomPolicy, type RoomPolicy } from "./policy.ts";

// Everything this client is remains reachable through this one name. The
// implementation below owns Room, while the barrel owns its sibling clients.
export * from "./client_exports.ts";

import { ask } from "../ask.ts";
import { PostedLine } from "../posted_line.ts";
import type { Message } from "./message.ts";

/** What a room calls itself, asked of an entrance reference, including one
 * just enlivened from a link before subscribe. Empty when it has no label to
 * give. */
export async function roomCalledAs(session: Session, room: Ref): Promise<string> {
	const said = await ask(session, room, CALLED, [], "the room did not say what it is called");
	return typeof said === "string" ? said : "";
}

/** Mint or recover a durable link from a raw room capability without joining it. */
export async function linkRoomReference(session: Session, room: Ref): Promise<string> {
	return await new RoomStewardship(session, room).link();
}

/** Whether an entrance reference names an unlisted room. A public room's link
 * is still that public room; guessing from the name would open a listed room
 * that merely shares a private room's label. */
export async function roomIsPrivate(session: Session, room: Ref): Promise<boolean> {
	const said = await ask(session, room, PRIVATE, [], "the room did not say whether it is listed");
	if (said === true || said === "private") return true;
	if (said === false || said === "" || said === "listed") return false;
	throw new Error("the room did not say whether it is listed");
}

export async function roomPolicy(session: Session, room: Ref): Promise<RoomPolicy> {
	const answer = await ask(session, room, ROOM_POLICY, [], "the room did not answer its policy");
	const policy = parseRoomPolicy(answer);
	if (policy === null) throw new Error("the room answered an invalid policy");
	return policy;
}

export interface RoomSubscribeOptions {
	readonly onTyping?: (from: string, on: boolean) => void;
	readonly voucher?: Uint8Array;
	readonly onAuthorityChanged?: (room: Room, change: RoomAuthorityChange) => void;
	readonly onPolicyChanged?: (room: Room, policy: RoomPolicy) => void;
}

/** A membership in a chat room. Get one with `Room.subscribe` (the app's
 * `joinRoom` in `enter_room.ts` is the friendly wrapper), read `messages`, call
 * `say`, and `leave` when you are done. */
export class Room {
	#session: Session;
	#room: Ref;
	#membership: Ref | null = null;
	#membershipKind: RoomMembershipKind = "participant";
	#inbox: Ref | null = null;
	readonly #messageStream: RoomMessageStream;
	/** The authority to say what the room is about, when it offered one. */
	#topic: Ref | null = null;
	/** The authority to put files in this room, when it offered one: what
	 * `attach` and `postFiles` go to. A room that cannot hold bytes offers
	 * none, and so does an observer seat. */
	#files: Ref | null = null;
	readonly #stewardship: RoomStewardship;
	/** What subscribe's arrival said about this occupancy, when it said so. */
	#listed: boolean | undefined;
	#endedReason: string | null = null;
	#arrivalSettled = false;
	#arrivalFailure: Error | null = null;
	#arrival: Promise<void>;
	#resolveArrival: () => void = () => {};
	#retired = false;
	#leavePromise: Promise<void> | null = null;

	/** The lines the room sends you, in order, as an async stream. The stream ends
	 * when you `leave` or the room hangs up. */
	readonly messages: ReadableStream<Message>;

	private constructor(session: Session, room: Ref) {
		this.#session = session;
		this.#room = room;
		this.#stewardship = new RoomStewardship(session, room);
		this.#messageStream = new RoomMessageStream((message) => {
			for (const attachment of message.attachments) {
				settleCapabilityCleanup(
					"unread room file capability release failed",
					() => session.release(attachment.blob),
				);
			}
		});
		this.#arrival = new Promise((resolve) => {
			this.#resolveArrival = resolve;
		});
		this.messages = this.#messageStream.readable;
	}

	/** Subscribe to a room you already hold a reference to, on an open connection.
	 * Publishes the inbox, hands the room that capability, and surfaces the
	 * room's callbacks on `messages`. `onTyping`, if given, fires with each
	 * other member's ephemeral typing flag; those signals never reach `messages`. */
	static async subscribe(
		session: Session,
		roomRef: Ref,
		nick: string,
		options: RoomSubscribeOptions = {},
	): Promise<Room> {
		const self = new Room(session, roomRef);

		// The room calls this back with every line; surface it on `messages`. A system
		// line may carry a structured presence change after its text.
		const inbox = session.spawn(roomInboxBehavior(session, {
			typing: (from, on) => options.onTyping?.(from, on),
			listed: (listed) => self.#listed = listed,
			line: (message) => self.#messageStream.push(message),
			arrived: () => self.#arrive(),
			ended: (reason) => {
				self.#endedReason = reason;
				self.#endStream();
			},
			authorityChanged: (change) => {
				self.#stewardship.forget(change);
				options.onAuthorityChanged?.(self, change);
			},
			authorityStatus: () => {},
			policyChanged: (policy) => options.onPolicyChanged?.(self, policy),
		}));
		// This local occurrence remains owned by the membership until leave or
		// replacement. The room owns the wire occurrence it adopted independently.
		self.#inbox = inbox;

		// The session owner reports why a shared connection ended. Each room only
		// ends its own stream, so one connection loss does not print once per room.
		const endStream = () => self.#endStream();
		void session.serve().then(endStream, endStream);

		// Subscribe, handing the room a capability to our inbox. The answer carries
		// the membership seat, kind, and optional topic authority; the room delivers
		// the welcome and roster as `notify` calls. A rejected claim (e.g. the nickname is taken)
		// propagates; the connection stays open, the directory owns it, and the caller
		// may try another room or close the session itself.
		// Topic authority is optional: holding one is the question a client asks
		// rather than inferring authority from a role or protocol version.
		// The voucher rides only when the caller has one to present: a subscribe
		// arriving on a connection that is not the name's registrar proves itself
		// with it, and every other subscribe needs nothing.
		try {
			const answer = await ask(
				session,
				roomRef,
				SUBSCRIBE,
				options.voucher === undefined ? [nick, inbox] : [nick, inbox, options.voucher],
				`the room did not answer ${nick} joining`,
			);
			const membership = readMembershipAnswer(session, answer);
			self.#membership = membership.seat;
			self.#membershipKind = membership.kind;
			self.#topic = membership.topic;
			self.#files = membership.files;
			await answerWithin(self.#arrival, `the room did not announce ${nick} arriving`, REQUEST_TIMEOUT_MS);
			if (self.#arrivalFailure !== null) throw self.#arrivalFailure;
			return self;
		} catch (error) {
			self.#endStream();
			const cleanup = self.#releaseMembershipRefs();
			if (cleanup !== null) retainSecondaryFailure(error, cleanup);
			throw error;
		}
	}

	/** A durable authority to this room: the string somebody else can redeem to
	 * be in it. Its Host authors the location and authority together.
	 *
	 * An ordinary room reference returns an existing link. Creating or reissuing
	 * one requires the separate room manager capability retained by this client.
	 * What comes back is data, so it travels over any channel at all, including
	 * one this application knows nothing about. Whoever holds the string can
	 * redeem it and pass it on.
	 *
	 * It works for a private room precisely as it does for a public one. A
	 * private room's durable name is its own unguessable key rather than its
	 * label, so nothing about what the room is called is in the link, and
	 * nothing about the link is guessable from the label.
	 *
	 * Asking makes the room durable, and that is a cost as well as a feature:
	 * the server records the room's durable name for good, against a bounded
	 * registry. Mint one when an invitation must outlive its sessions; the
	 * ordinary hand-over is the room itself (`handRoom`), which costs the
	 * server nothing. A link preserves the room's identity, not its history
	 * policy: retention is still the Rooms operator's explicit choice. */
	async link(): Promise<string> {
		return await this.#stewardship.link();
	}

	/** What this room calls itself, or "" when it has no label to give.
	 *
	 * A link does not carry a name. This is how `/join` of that locator still
	 * sits in the place that minted it rather than under an invented one. */
	async called(): Promise<string> {
		return await roomCalledAs(this.#session, this.#room);
	}

	/** Whether this room is unlisted. A link to a public room is still that
	 * public room; a link to a private one is not a name on the directory. */
	async isPrivate(): Promise<boolean> {
		return await roomIsPrivate(this.#session, this.#room);
	}

	policy(): Promise<RoomPolicy> {
		return roomPolicy(this.#session, this.#room);
	}

	/** The reference this room is, for handing on.
	 *
	 * Holding it is being in reach of the room, so passing it to somebody is
	 * the whole of inviting them — the runtime carries it across sessions as a
	 * handoff, and nothing is asked of the room or the directory. */
	get reference(): Ref {
		return this.#room;
	}

	get membershipReference(): Ref {
		return this.#membershipRef();
	}

	/** Whether this occupancy is a directory name, when subscribe said so.
	 *
	 * Undefined against a room that did not state it — an older room, or one
	 * that is not this protocol. `/join` of a locator seats from this rather
	 * than asking a method first. */
	get listed(): boolean | undefined {
		return this.#listed;
	}

	get membershipKind(): RoomMembershipKind {
		return this.#membershipKind;
	}

	get canSpeak(): boolean {
		return this.#membershipKind === "participant";
	}

	async invite(kind: RoomMembershipKind = "participant"): Promise<RoomInvitation> {
		const invitation = await ask(
			this.#session,
			this.#membershipRef(),
			MINT_INVITATION,
			[kind],
			"the membership did not answer an invitation",
		);
		if (!(invitation instanceof Ref)) throw new Error("the membership answered without an invitation capability");
		return new RoomInvitation(this.#session, invitation);
	}

	/** Why the room ended this membership, when it sent a terminal fact before
	 * closing the message stream. Null for local leave, replacement, or a lost
	 * connection whose session owns the reason. */
	get endedReason(): string | null {
		return this.#endedReason;
	}

	/** Whether this membership holds the authority to say what the room is
	 * about. False against a room that does not offer one. */
	get canSetTopic(): boolean {
		return this.#topic !== null;
	}

	/** Whether this membership holds the authority to put files in the room.
	 * False against a room that offers none: one that cannot hold bytes, or an
	 * observer seat. A composer draws its attach control from this. */
	get canPostFiles(): boolean {
		return this.#files !== null;
	}

	/** Say this membership has stepped away, or `""` to say it is back.
	 *
	 * Nobody hands this over: a member's own standing is theirs to state, and
	 * the room writes it against the membership that called. */
	async away(reason: string): Promise<void> {
		await ask(this.#session, this.#membershipRef(), AWAY, [reason], "the membership did not answer stepping away");
	}

	/** Try to mint the room's durable steward authority. Only the exact typed
	 * `not-steward` answer means this membership does not hold it; transport,
	 * parser, runtime, and publication failures remain failures. */
	async claimSteward(): Promise<boolean> {
		return await this.#stewardship.claim();
	}

	/** Take a steward sturdyref for this exact room. The imported capability
	 * identifies the room publication it governs before replacing any authority
	 * already held, so pasting a valid steward for another room fails closed. */
	async takeSteward(stewardLink: string): Promise<void> {
		await this.#stewardship.take(stewardLink);
	}

	async takeManager(managerLink: string): Promise<void> {
		await this.#stewardship.takeManager(managerLink);
	}

	managerIdentity(): Promise<string> {
		return managedRoomIdentity(this.#session, this.#room);
	}

	dropSteward(): void {
		this.#stewardship.drop();
	}

	dropManager(): void {
		this.#stewardship.dropManager();
	}

	revokeManagedAuthority(kind: "room" | "steward", token: string): Promise<void> {
		return this.#stewardship.revokeManagedAuthority(kind, token);
	}

	unregisterManagedRoom(): Promise<{ policy: RoomPolicy; name: string }> {
		return this.#stewardship.unregisterRoom();
	}

	setPolicy(policy: RoomPolicy, name: string): Promise<{ policy: RoomPolicy; name: string }> {
		return this.#stewardship.setPolicy(policy, name);
	}

	get roomLink(): string | null {
		return this.#stewardship.roomLink;
	}

	get stewardLink(): string | null {
		return this.#stewardship.stewardLink;
	}

	get managerLink(): string | null {
		return this.#stewardship.managerLink;
	}

	/** Whether this membership holds the steward. */
	get canKick(): boolean {
		return this.#stewardship.held;
	}

	get canClaimSteward(): boolean {
		return this.#stewardship.managerLink !== null;
	}

	/** Ask a member, by nick, to leave through the steward already held. */
	async kick(nick: string): Promise<void> {
		await this.#stewardship.kick(nick);
	}

	/** Say what the room is about, for everyone in it and everyone who arrives
	 * after. An empty string takes the topic down.
	 *
	 * Throws when this membership holds no topic capability. A room that does
	 * not offer one leaves the membership in that state; ask `canSetTopic` first. */
	async setTopic(text: string): Promise<void> {
		if (this.#topic === null) throw new Error("this room did not offer a topic to set");
		await ask(this.#session, this.#topic, SET_TOPIC, [text], "the room did not answer setting its topic");
	}

	/** What the room kept of its own conversation, oldest first, when this
	 * server keeps history at all. A server that keeps none refuses the optional
	 * verb; callers can therefore distinguish unavailable retention from an
	 * enabled room whose retained tail is empty. */
	async history(): Promise<{ from: string; text: string; at: number }[]> {
		const raw = await ask(
			this.#session,
			this.#membershipRef(),
			HISTORY,
			[],
			"the membership did not answer its history",
		);
		if (!Array.isArray(raw)) return [];
		const lines: { from: string; text: string; at: number }[] = [];
		for (const row of raw) {
			if (!Array.isArray(row)) continue;
			const from = typeof row[0] === "string" ? row[0] : "";
			const text = typeof row[1] === "string" ? row[1] : "";
			const at = typeof row[2] === "bigint" ? Number(row[2]) : typeof row[2] === "number" ? row[2] : 0;
			if (from !== "") lines.push({ from, text, at });
		}
		return lines;
	}

	/** What form this membership's bridge wants drawn, or null when it wants
	 * none. See `askBridgeForm`. */
	bridgeForm(): Promise<BridgeForm | null> {
		return askBridgeForm(this.#session, this.#membershipRef());
	}

	/** Press one of that form's actions with what the reader typed. The answer is
	 * the bridge's own sentence about what happened. */
	submitBridgeForm(action: string, answers: BridgeAnswers): Promise<string> {
		return answerBridgeForm(this.#session, this.#membershipRef(), action, answers);
	}

	/** Say a line to everyone in the room. */
	async say(text: string): Promise<PostedLine | null> {
		const line = await ask(
			this.#session,
			this.#membershipRef(),
			POST,
			[text],
			"the membership did not answer the line",
		);
		// A room that answers with a reference is one that will let this line be
		// changed or taken back. A room may accept the line without granting that
		// authority, so absence is an explicit result rather than a failure.
		return line instanceof Ref ? new PostedLine(this.#session, line) : null;
	}

	/** Stage a file into the message being written and return the capability
	 * that holds it: post first, then fill it, or `discard` before posting.
	 *
	 * The room holds the bytes, so a posted file stays viewable after this
	 * client closes — and a client nothing on the network can dial, such as a
	 * browser tab, can post one at all. */
	stage(source: AttachmentSource): Promise<Ref> {
		return beginUpload(this.#session, this.#filesRef(), source);
	}

	/** Drive an admitted upload. Separate from `stage` so a message can become
	 * visible before its independently progressing files finish. */
	upload(
		upload: Ref,
		source: AttachmentSource,
		onProgress?: (sent: number) => void,
		signal?: AbortSignal,
	): Promise<void> {
		return fillUpload(this.#session, upload, source, onProgress, signal);
	}

	/** Take one staged file back out of the message. */
	discard(upload: Ref): Promise<unknown> {
		return discardUpload(this.#session, upload);
	}

	/** Send everything staged on this connection as one message, captioned
	 * with `text`, and answer the line it made.
	 *
	 * A room that answers with a reference is one that will let this file line be
	 * captioned again, have its files changed, or be taken back. A room may grant
	 * no such authority; absence is returned exactly as `say` returns it. */
	async postFiles(text = ""): Promise<PostedLine | null> {
		const line = await postStagedFiles(this.#session, this.#filesRef(), text);
		return line instanceof Ref ? new PostedLine(this.#session, line) : null;
	}

	/** Stage one file and post it on its own, the shape a terminal client
	 * wants: there is no composer to hold it in between. */
	async attach(source: AttachmentSource, text = "", onProgress?: (sent: number) => void): Promise<void> {
		const upload = await this.stage(source);
		try {
			await this.postFiles(text);
			await this.upload(upload, source, onProgress);
		} catch (error) {
			throw await retainCleanupFailures(error, [async () => {
				await this.discard(upload);
			}]);
		}
	}

	/** Pull a posted file's bytes through the capability its line carried. */
	fetch(attachment: Attachment, onProgress?: (got: number) => void): Promise<Uint8Array> {
		return fetchBlob(this.#session, attachment, onProgress);
	}

	readFile(attachment: Attachment, offset: number, maxLen: number): Promise<Uint8Array> {
		return fetchBlobChunk(this.#session, attachment, offset, maxLen);
	}

	/** Give back a file capability this member no longer needs. */
	release(attachment: Attachment): void {
		this.#session.release(attachment.blob);
	}

	/** Flag whether we are typing in this room. Fire-and-forget (`tell`, no reply):
	 * a typing signal is ephemeral, so a lost one costs nothing and never blocks a
	 * keystroke. The room drops it silently if we are no longer subscribed. */
	setTyping(on: boolean): Promise<void> {
		// best-effort: a lost flag is the whole loss; the next keystroke sends another.
		return this.#session.tell(this.#membershipRef(), TYPING, [on]).catch(() => {});
	}

	/** Leave this room — drop the membership and end the `messages` stream —
	 * without closing the connection, so the same connection can enter another
	 * room. Close the session itself with `Directory.close`. */
	leave(): Promise<void> {
		if (this.#leavePromise !== null) return this.#leavePromise;
		if (this.#retired) return Promise.resolve();
		this.#retired = true;
		this.#leavePromise = this.#leave();
		return this.#leavePromise;
	}

	async #leave(): Promise<void> {
		let failure: unknown | null = null;
		try {
			// Bounded like every other request, and for a reason particular to
			// this one: the cleanup below is in the `finally`, so a room that
			// stays connected and never answers the goodbye holds this
			// membership's references and its stream for the life of the tab.
			// Leaving is something this side does; telling the room is a
			// courtesy, and a courtesy must not hold the leaving hostage.
			await answerWithin(
				this.#session.send(this.#membershipRef(), LEAVE, []),
				"the room did not answer the goodbye",
				REQUEST_TIMEOUT_MS,
			);
		} catch (error) {
			failure = error;
		} finally {
			const cleanup = this.#releaseMembershipRefs();
			if (cleanup !== null) {
				failure = failure === null ? cleanup : retainSecondaryFailure(failure, cleanup);
			}
			this.#endStream();
		}
		if (failure !== null) throw failure;
	}

	/** Stop reading this membership without telling the room, because a newer
	 * claim on the same connection has already replaced it.
	 *
	 * `leave` is the wrong verb there and not merely a wasteful one: the room
	 * keys a departure by connection, so a leave sent after re-entering would
	 * take back the place the re-entry had just made, leaving a member who
	 * believes they are in a room the room no longer has them in. Re-entry
	 * already replaced the record on the room's side; what is left is this
	 * side's stream. */
	replaced(): void {
		if (this.#retired) return;
		this.#retired = true;
		this.#endStream();
		const failure = this.#releaseMembershipRefs();
		if (failure !== null) throw failure;
	}

	#releaseMembershipRefs(): unknown | null {
		let failure: unknown | null = null;
		const release = (field: "#inbox" | "#topic" | "#files" | "#membership", ref: Ref | null) => {
			if (ref === null) return;
			try {
				this.#session.release(ref);
				if (field === "#inbox") this.#inbox = null;
				else if (field === "#topic") this.#topic = null;
				else if (field === "#files") this.#files = null;
				else this.#membership = null;
			} catch (error) {
				failure = failure === null ? error : retainSecondaryFailure(failure, error);
			}
		};
		release("#inbox", this.#inbox);
		release("#topic", this.#topic);
		release("#files", this.#files);
		release("#membership", this.#membership);
		try {
			this.#stewardship.release();
		} catch (error) {
			failure = failure === null ? error : retainSecondaryFailure(failure, error);
		}
		return failure;
	}

	#membershipRef(): Ref {
		if (this.#membership === null) throw new Error("this room membership has ended");
		return this.#membership;
	}

	#filesRef(): Ref {
		this.#membershipRef();
		if (this.#files === null) throw new Error("this room does not carry files");
		return this.#files;
	}

	#endStream(): void {
		this.#finishArrival(new Error("the room session ended before the membership arrived"));
		this.#messageStream.close();
	}

	#arrive(): void {
		this.#finishArrival(null);
	}

	#finishArrival(failure: Error | null): void {
		if (this.#arrivalSettled) return;
		this.#arrivalSettled = true;
		this.#arrivalFailure = failure;
		this.#resolveArrival();
	}
}
