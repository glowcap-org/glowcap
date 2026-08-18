// A small, friendly client for the rooms chat, built on pancake actors.
//
// This is the layer that knows about OCapN, and on the connection API it is
// barely a layer at all: connect, fetch the directory by name, ask it to open or
// enter a room (which hands back a live reference to that room), spawn an inbox
// the room can call back, subscribe by handing it that capability, and surface
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
// name is the directory's lookup key; the room itself is the capability the
// directory returns.

import { formatSturdyRef, Ref, retainCleanupFailures, retainSecondaryFailure } from "@pancake/runtime";
import type { Session } from "@pancake/runtime";
import type { Presence } from "./limits.ts";
import {
	type Attachment,
	type AttachmentSource,
	beginUpload,
	discardUpload,
	fetchBlob,
	fillUpload,
	postStagedFiles,
	readAttachments,
} from "./attachment.ts";
import { AWAY, LEAVE, LINK, NOTIFY, POST, SET_TOPIC, SUBSCRIBE, TYPING } from "./protocol.ts";
import { roomsLocator } from "./locator.ts";

// Everything this client is, reached through one name. The split is where the
// code lives; a caller still asks `room_client.ts` for the directory, a direct
// line, or a room, and gets what it always got.
export { Directory, readRoomEvent, type RoomEvent, type RoomInfo, signalingRoute } from "./directory.ts";
export { DirectMessage } from "./direct_message.ts";
export { PostedLine } from "./posted_line.ts";
export { type DiagnosticRow, snapshotDiagnostics, takeDiagnostics } from "./diagnostics.ts";
export { listenerDown, type ListenerRow, listenerUp, listListeners, takeListeners } from "./listeners.ts";
export {
	type Message,
	readLineBytes,
	readLineChange,
	readLineId,
	readPresence,
	readRoomFacts,
	readTopic,
	type RoomFacts,
	roomRecordAt,
} from "./room_message.ts";

import { ask } from "./ask.ts";
import { PostedLine } from "./posted_line.ts";
import {
	type Message,
	readLineChange,
	readLineId,
	readPresence,
	readRoomFacts,
	type RoomFacts,
	roomRecordAt,
} from "./room_message.ts";

/** A membership in a chat room. Get one with `Room.subscribe` (the app's
 * `joinRoom` in `enter_room.ts` is the friendly wrapper), read `messages`, call
 * `say`, and `leave` when you are done. */
export class Room {
	#session: Session;
	#room: Ref;
	#inbox: Ref | null = null;
	// Captured synchronously by the ReadableStream `start` callback.
	#lines!: ReadableStreamDefaultController<Message>;
	#leaving = false;
	/** The authority to say what the room is about, when it offered one. */
	#topic: Ref | null = null;

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
		voucher?: Uint8Array,
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
			self.#emit(
				from,
				text,
				readPresence(args),
				readAttachments(args, roomRecordAt(args)),
				readRoomFacts(args),
				readLineId(args),
				readLineChange(args),
			);
			return null;
		});
		// This local occurrence remains owned by the membership until leave or
		// replacement. The room owns the wire occurrence it adopted independently.
		self.#inbox = inbox;

		// End the message stream when the connection closes. A dropped connection
		// rejects serve(), which is expected here, so catch it rather than leak an
		// unhandled rejection.
		session.serve().finally(() => self.#endStream()).catch(() => {});

		// Subscribe, handing the room a capability to our inbox. Success is the
		// resolution — the room delivers the welcome and the roster as our first
		// `notify`, not as a return value. A rejected claim (e.g. the nickname is taken)
		// propagates; the connection stays open, the directory owns it, and the caller
		// may try another room or close the session itself.
		// The room may answer with the capability to say what it is about. Topic
		// authority is optional: holding one is the question a client asks rather
		// than inferring authority from a role or protocol version.
		// The voucher rides only when the caller has one to present: a subscribe
		// arriving on a connection that is not the name's registrar proves itself
		// with it, and every other subscribe needs nothing.
		try {
			const topic = await ask(
				session,
				roomRef,
				SUBSCRIBE,
				voucher === undefined ? [nick, inbox] : [nick, inbox, voucher],
				`the room did not answer ${nick} joining`,
			);
			if (topic instanceof Ref) self.#topic = topic;
			return self;
		} catch (error) {
			self.#leaving = true;
			self.#endStream();
			const cleanup = self.#releaseMembershipRefs();
			if (cleanup !== null) retainSecondaryFailure(error, cleanup);
			throw error;
		}
	}

	/** A durable authority to this room, composed with the address it was
	 * reached at: the string somebody else can redeem to be in it.
	 *
	 * It is asked for with the reference, so holding the room is the whole of
	 * the right to mint one, and what comes back is data — so it travels over
	 * any channel at all, including a channel this application knows nothing
	 * about. Whoever holds the string can redeem it, and can pass it on.
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
	 * server nothing. The lines said in a room are not kept either way — a link
	 * preserves the room's identity, not its history. */
	async link(locator: string): Promise<string> {
		const swiss = await ask(this.#session, this.#room, LINK, [], "the room did not answer linking itself");
		if (typeof swiss !== "string" || swiss.length === 0) {
			throw new Error("link() did not return a swissnum");
		}
		return formatSturdyRef(roomsLocator(locator), swiss, "next");
	}

	/** The reference this room is, for handing on.
	 *
	 * Holding it is being in reach of the room, so passing it to somebody is
	 * the whole of inviting them — the runtime carries it across sessions as a
	 * handoff, and nothing is asked of the room or the directory. */
	get reference(): Ref {
		return this.#room;
	}

	/** Whether this membership holds the authority to say what the room is
	 * about. False against a room that does not offer one. */
	get canSetTopic(): boolean {
		return this.#topic !== null;
	}

	/** Say this membership has stepped away, or `""` to say it is back.
	 *
	 * Nobody hands this over: a member's own standing is theirs to state, and
	 * the room writes it against the membership that called. */
	async away(reason: string): Promise<void> {
		await ask(this.#session, this.#room, AWAY, [reason], "the room did not answer stepping away");
	}

	/** Say what the room is about, for everyone in it and everyone who arrives
	 * after. An empty string takes the topic down.
	 *
	 * Throws when this membership holds no topic capability, which is what a
	 * room that does not offer one leaves it with; ask `canSetTopic` first. */
	async setTopic(text: string): Promise<void> {
		if (this.#topic === null) throw new Error("this room did not offer a topic to set");
		await ask(this.#session, this.#topic, SET_TOPIC, [text], "the room did not answer setting its topic");
	}

	/** Say a line to everyone in the room. */
	async say(text: string): Promise<PostedLine | null> {
		const line = await ask(this.#session, this.#room, POST, [text], "the room did not answer the line");
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
		return beginUpload(this.#session, this.#room, source);
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
		const line = await postStagedFiles(this.#session, this.#room, text);
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

	/** Give back a file capability this member no longer needs. */
	release(attachment: Attachment): void {
		this.#session.release(attachment.blob);
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
		let failure: unknown | null = null;
		try {
			await this.#session.send(this.#room, LEAVE, []);
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
		this.#leaving = true;
		this.#endStream();
		const failure = this.#releaseMembershipRefs();
		if (failure !== null) throw failure;
	}

	#releaseMembershipRefs(): unknown | null {
		let failure: unknown | null = null;
		const release = (field: "#inbox" | "#topic", ref: Ref | null) => {
			if (ref === null) return;
			try {
				this.#session.release(ref);
				if (field === "#inbox") this.#inbox = null;
				else this.#topic = null;
			} catch (error) {
				failure = failure === null ? error : retainSecondaryFailure(failure, error);
			}
		};
		release("#inbox", this.#inbox);
		release("#topic", this.#topic);
		return failure;
	}

	#emit(
		from: string,
		text: string,
		presence?: Presence,
		attachments: Attachment[] = [],
		facts?: RoomFacts,
		lineId?: number,
		change?: "said" | "edited" | "refiled" | "withdrawn",
	): void {
		try {
			this.#lines.enqueue({
				from,
				text,
				system: from === "room",
				presence,
				attachments,
				facts,
				lineId,
				change,
			});
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
