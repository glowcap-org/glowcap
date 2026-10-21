// One direct line to one peer, and the handle it hands back.
//
// The directory introduced the two of you and stepped out, so everything here
// runs on a connection between the two peers. Which side opened it decides what
// is possible: a line this side redeemed owns its connection and can be closed,
// and a line riding the connection a peer opened to us cannot.
//
// A message answers with a handle the receiver created, so a sender can change
// or take back what the receiver is looking at. It is the direct sibling of the
// reference a room answers a post with, except the durable owner here is the
// person you are talking to.

import {
	annotateSession,
	type Argument,
	type Behavior,
	currentSession,
	Ref,
	retainCleanupFailures,
	retainSecondaryFailure,
	type Session,
} from "@glowcap/runtime";
import {
	type Attachment,
	attachmentCapabilities,
	fetchBlob,
	fetchBlobChunk,
	readAttachments,
	sendWithAttachments,
} from "./attachment.ts";
import type { AttachmentSource } from "./attachment.ts";
import { DIRECT_READY, DM, HAND_ARCHIVE, HAND_ROOM, OFFER_ARCHIVE, OFFER_ROOM, TYPING } from "./protocol.ts";
import { type ArchiveShareKind, parseArchiveShareKind } from "./archive/handover.ts";
import { ask } from "./ask.ts";
import type { Directory } from "./directory.ts";
import { PostedLine } from "./posted_line.ts";
import { refuseCapabilityArguments, releaseUnexpectedCapabilityArguments } from "./argument_custody.ts";
import { lineCost, MAX_LINE } from "./limits.ts";

/** The direct protocol accepted on a public inbox or reply route. Messages and
 * reciprocal route delivery are the base contract. Optional sibling verbs
 * return their actual supported outcome. */
export interface DirectMessageReceiver {
	message(text: string, attachments: Attachment[], session: Session, reply: Ref | null): ReturnType<Behavior>;
	ready(session: Session, reply: Ref): void | Promise<void>;
	typing?(on: boolean): void;
	handRoom?(label: string, room: Ref, session: Session): void | Promise<void>;
	offerRoom?(label: string, link: string): void | Promise<void>;
	handArchive?(
		directory: string,
		kind: ArchiveShareKind,
		conversation: string | null,
		archive: Ref,
		session: Session,
	): void | Promise<void>;
	offerArchive?(
		directory: string,
		kind: ArchiveShareKind,
		conversation: string | null,
		sturdyref: string,
	): void | Promise<void>;
}

/** Parse the direct inbox protocol for a public inbox or a reply route. */
export function directMessageReceiverBehavior(
	receiver: DirectMessageReceiver,
	sessionFor: () => Session | null = currentSession,
): Behavior {
	const session = (): Session => {
		const active = sessionFor();
		if (active == null) throw new Error("a direct inbox is reachable only during a session turn");
		return active;
	};
	return (verb, args) => {
		if (verb === DIRECT_READY) {
			if (args.length !== 1 || !(args[0] instanceof Ref)) {
				refuseCapabilityArguments(session(), args, "directReady takes one reply capability");
			}
			return Promise.resolve(receiver.ready(session(), args[0])).then(() => null);
		}
		if (verb === TYPING) {
			if (args.length !== 1 || typeof args[0] !== "boolean") {
				refuseCapabilityArguments(session(), args, "direct typing takes one boolean");
			}
			if (receiver.typing == null) throw new Error("direct inbox has no typing receiver");
			receiver.typing(args[0]);
			return null;
		}
		if (verb === HAND_ROOM) {
			if (args.length !== 2 || typeof args[0] !== "string" || !(args[1] instanceof Ref)) {
				refuseCapabilityArguments(session(), args, "a handed room needs a label and room capability");
			}
			if (receiver.handRoom == null) {
				refuseCapabilityArguments(session(), args, "direct inbox cannot receive a handed room");
			}
			return Promise.resolve(receiver.handRoom(args[0], args[1], session())).then(() => null);
		}
		if (verb === OFFER_ROOM) {
			if (args.length !== 2 || typeof args[0] !== "string" || typeof args[1] !== "string") {
				refuseCapabilityArguments(session(), args, "a room-link invitation needs a label and sturdyref");
			}
			if (receiver.offerRoom == null) throw new Error("direct inbox cannot receive a room link");
			return Promise.resolve(receiver.offerRoom(args[0], args[1])).then(() => null);
		}
		if (verb === HAND_ARCHIVE) {
			if (
				args.length !== 4 || typeof args[0] !== "string" ||
				!(args[3] instanceof Ref)
			) {
				refuseCapabilityArguments(
					session(),
					args,
					"handArchive takes a directory, kind, conversation, and archive capability",
				);
			}
			let kind: ArchiveShareKind;
			try {
				kind = parseArchiveShareKind(args[1]);
			} catch (error) {
				refuseCapabilityArguments(session(), args, error instanceof Error ? error.message : String(error));
			}
			if (args[2] !== null && typeof args[2] !== "string") {
				refuseCapabilityArguments(
					session(),
					args,
					"handArchive conversation must be a string or null",
				);
			}
			if (receiver.handArchive == null) {
				refuseCapabilityArguments(session(), args, "direct inbox cannot receive archive history");
			}
			return Promise.resolve(receiver.handArchive(args[0], kind, args[2], args[3], session())).then(() => null);
		}
		if (verb === OFFER_ARCHIVE) {
			if (
				args.length !== 4 || typeof args[0] !== "string" || typeof args[3] !== "string" ||
				(args[2] !== null && typeof args[2] !== "string")
			) {
				refuseCapabilityArguments(
					session(),
					args,
					"offerArchive takes a directory, kind, conversation, and sturdyref",
				);
			}
			if (receiver.offerArchive == null) throw new Error("direct inbox cannot receive a durable archive offer");
			return Promise.resolve(
				receiver.offerArchive(args[0], parseArchiveShareKind(args[1]), args[2], args[3]),
			).then(() => null);
		}
		if (verb !== DM) refuseCapabilityArguments(session(), args, `direct inbox has no method ${verb}`);
		if (typeof args[0] !== "string" || lineCost(args[0]) > MAX_LINE) {
			refuseCapabilityArguments(session(), args, `a direct message needs text of at most ${MAX_LINE} bytes`);
		}
		const reply = args[1] instanceof Ref ? args[1] : null;
		const attachments = readAttachments(args, reply == null ? 1 : 2);
		const retained = attachmentCapabilities(attachments);
		if (reply != null) retained.add(reply);
		releaseUnexpectedCapabilityArguments(
			session(),
			args,
			retained,
			"a direct inbox could not return an unexpected capability",
		);
		return receiver.message(
			args[0],
			attachments,
			session(),
			reply,
		);
	};
}

/** How many live lines ride each redeemed exporter connection.
 *
 * A redeem to an exporter this host has already dialed resolves the same live
 * session instead of opening a second one (`sendRedeeming` does this, and
 * `zig build rooms-dm-reredeem` proves it). So two lines to one member share
 * one connection, and "did a route come back" is not the same question as "did
 * this line open it". Closing on the first answer hangs up a connection the
 * other line is still talking on.
 *
 * Held weakly and keyed by the session, so a connection dropped without a
 * close takes its row with it instead of pinning one forever. */
const linesOnSession = new WeakMap<Session, number>();

/** A live, direct line to one member, obtained by introduction. `DirectMessage.open`
 * asks the directory to introduce you and wraps the redeemed capability. `say`
 * then delivers a message straight to that member over your connection. The
 * directory is not on the message path. It vouched for the introduction once,
 * and after that the two of you talk without it.
 *
 * The line is bidirectional. It hosts a reply inbox on the connection the
 * redeem opened and hands it to the member with each message, so the member
 * answers you back over that same connection even though you never listen.
 * The receiver passed to `open` handles that reply route's direct protocol. */

export class DirectMessage {
	#session: Session;
	#dm: Ref | null;
	#replyInbox: Ref | null;
	// Whether this line dialed the connection it rides. A redeemed introduction
	// opens one to the member and owns it. A send-only line rides the directory's
	// and must never close it, since everything else the tab is doing is on it.
	#ownsSession: boolean;
	#spent = false;
	readonly peer: string;
	readonly peerRegistrationId: string;

	/** Whether the connection this line rides is still open. A line outlives
	 * the peer that went offline, and every send on it fails. Asking first lets
	 * a caller re-introduce instead of spending a message to find out. */
	get live(): boolean {
		return this.#session.sessionOpen;
	}

	/** Whether an arriving occurrence names the route this line already uses.
	 * Ref wrappers own separate retains, so target equality is `Ref.equals`, not
	 * JavaScript object identity. */
	usesRoute(session: Session, target: Ref): boolean {
		return !this.#spent && this.#session === session && this.#dm?.equals(target) === true;
	}

	private constructor(
		session: Session,
		dm: Ref,
		peer: string,
		peerRegistrationId: string,
		replyInbox: Ref | null,
		ownsSession: boolean,
	) {
		this.#session = session;
		this.#dm = dm;
		this.peer = peer;
		this.peerRegistrationId = peerRegistrationId;
		this.#replyInbox = replyInbox;
		this.#ownsSession = ownsSession;
	}

	/** Adopt a reply route received by an inbox on an already-owned Host
	 * session. The route rides that arriving session and closing the line must
	 * release only the imported capability, never the shared Host session. */
	static adopt(session: Session, dm: Ref, peer: string, peerRegistrationId: string): DirectMessage {
		annotateSession(session, { label: peer });
		return new DirectMessage(session, dm, peer, peerRegistrationId, null, false);
	}

	/** Give this line back.
	 *
	 * A redeemed introduction is a connection to the member, held open for as
	 * long as the line is. Dropping the reference to a `DirectMessage` does not
	 * end that connection, and the reply inbox this side exported stays live on
	 * it. Closing does both, and releases the imported capability with the
	 * session that carried it. A send-only line dialed nothing and rides the
	 * directory's connection, so closing it is a no-op and not a hang-up on
	 * everything else the caller is doing.
	 *
	 * The peer is unaffected. Nothing was taken from them, and a later `open`
	 * redeems a fresh introduction. */
	async close(): Promise<void> {
		// Spent once. A second close would decrement a count this line has
		// already given up and hang up on whoever holds the connection now.
		if (this.#spent) return;
		if (this.#ownsSession) {
			const rest = (linesOnSession.get(this.#session) ?? 1) - 1;
			if (rest > 0) {
				// Another line is still talking on this connection. Give back
				// what was this line's, the imported capability, and leave the
				// connection to the lines that are still using it.
				this.#releaseRefs();
				linesOnSession.set(this.#session, rest);
				this.#spent = true;
				return;
			}
			// Last line out. Closing the connection reclaims everything on it,
			// imports included.
			await this.#session.close();
			linesOnSession.delete(this.#session);
			this.#dm = null;
			this.#replyInbox = null;
			this.#spent = true;
			return;
		}
		// A send-only line rides the directory's connection, which the tab still
		// needs, so closing is not an option. The member's capability was this
		// line's to hold and is now nobody's. Give it back so the exporter can
		// drop the matching export instead of keeping it alive for the life of
		// the tab. The handle is spent afterwards, and `say` on a closed line
		// throws instead of reaching whatever that position names next.
		this.#releaseRefs();
		this.#spent = true;
	}

	#releaseRefs(): void {
		let failure: unknown | null = null;
		const release = (ref: Ref | null, clear: () => void) => {
			if (ref === null) return;
			try {
				this.#session.release(ref);
				clear();
			} catch (error) {
				failure = failure === null ? error : retainSecondaryFailure(failure, error);
			}
		};
		release(this.#dm, () => (this.#dm = null));
		release(this.#replyInbox, () => (this.#replyInbox = null));
		if (failure !== null) throw failure;
	}

	#target(): Ref {
		if (this.#spent || this.#dm === null) throw new Error("this direct line is closed");
		return this.#dm;
	}

	/** Open a direct line to `peer` by asking `dir` to introduce you. `receiver`
	 * defines the complete protocol accepted on the reply route handed to that
	 * peer. The peer name is not repeated because the introduction already
	 * identifies who holds that route. */
	static async open(
		dir: Directory,
		peer: string,
		receiver?: DirectMessageReceiver,
		expectedRegistrationId?: string,
	): Promise<DirectMessage> {
		const registrationId = expectedRegistrationId ?? await dir.memberRegistration(peer);
		const { dm, via } = await dir.introduceVia(peer, registrationId);
		// The reply inbox must live on the connection the redeemed capability
		// routes to (`via`), so it is a valid near export the member can call
		// back. Without a `via` (no fresh redeem) there is no connection to host
		// it on, so the line is send-only.
		const session = via ?? dir.session;
		const owns = via != null;
		let replyInbox: Ref | null = null;
		try {
			if (receiver != null && via) {
				replyInbox = session.spawn(directMessageReceiverBehavior(receiver, () => session));
			}
			// Name the direct connection for whoever is watching the live timeline.
			// Only a redeemed one: a send-only line rides the directory's connection,
			// whose partner is the room and not this member. The annotation is a
			// claim about what the session carries, never identity. A consumer may
			// display it and must not merge or split peers on it.
			if (via) annotateSession(via, { label: peer });
			// Count this line onto the connection before handing it over, so a
			// close knows whether it is the last one out.
			if (owns) linesOnSession.set(session, (linesOnSession.get(session) ?? 0) + 1);
			return new DirectMessage(session, dm, peer, registrationId, replyInbox, owns);
		} catch (error) {
			// The introduction already transferred the imported DM reference and
			// may have opened a direct session. If constructing this line fails, no
			// DirectMessage exists to own either. Release the exact occurrences and
			// close only an otherwise-unowned redeemed session; a sibling line may
			// already be using a deduplicated exporter connection.
			throw await retainCleanupFailures(error, [
				...(replyInbox === null ? [] : [() => session.release(replyInbox!)]),
				() => session.release(dm),
				...(owns && (linesOnSession.get(session) ?? 0) === 0 ? [() => session.close()] : []),
			]);
		}
	}

	/** Deliver one direct message to the peer. There is no sender argument (see
	 * `offerInbox` in `protocol.ts`). Carries the reply inbox when this line has
	 * one, so the member can answer. */
	async say(text: string): Promise<PostedLine | null> {
		const args: Argument[] = this.#replyInbox ? [text, this.#replyInbox] : [text];
		const line = await ask(this.#session, this.#target(), DM, args, "they did not answer the message");
		// The peer answers with a handle to this line when it is one that can be
		// changed, the direct sibling of the reference a room's `post` answers, and
		// a `PostedLine` holds it the same way. A peer may grant no editing
		// authority, in which case the line is just said.
		return line instanceof Ref ? new PostedLine(this.#session, line) : null;
	}

	/** Hand the peer our reply inbox without sending a visible message. This is
	 * the reciprocal introduction path for peers whose carrier we can dial even
	 * when they cannot dial ours. */
	async establishReplyRoute(): Promise<void> {
		if (this.#replyInbox == null) throw new Error("this direct line has no reply route to establish");
		await ask(
			this.#session,
			this.#target(),
			DIRECT_READY,
			[this.#replyInbox],
			"they did not answer the reciprocal direct route",
		);
	}

	/** Hand this peer a room, over this line.
	 *
	 * The reference is the invitation: it crosses as a handoff and arrives as a
	 * working reference to the room, with nothing asked of the room or the
	 * directory and nothing durable created anywhere. The label is what the
	 * sender calls it. */
	async handRoom(label: string, room: Ref): Promise<void> {
		await ask(this.#session, this.#target(), HAND_ROOM, [label, room], "they did not answer being handed a room");
	}

	/** Hand this peer a read-only archive facet. The pipe is this direct line;
	 * `kind` and `conversation` name the facet's archive scope, which need not
	 * be this conversation. */
	async handArchive(
		directory: string,
		kind: ArchiveShareKind,
		conversation: string | null,
		archive: Ref,
	): Promise<void> {
		await ask(
			this.#session,
			this.#target(),
			HAND_ARCHIVE,
			[directory, kind, conversation, archive],
			"they did not answer being handed archive history",
		);
	}

	/** Host a short-lived facet on this direct session so its capability can be
	 * handed to the peer on the same connection. */
	spawn(behavior: import("@glowcap/runtime").Behavior): Ref {
		return this.#session.spawn(behavior);
	}

	releaseCapability(capability: Ref): void {
		this.#session.release(capability);
	}

	/** Offer this peer a room as durable data, over this line.
	 *
	 * Two strings: what to call it, and a link (`Room.link`) they can redeem.
	 * The offer survives every connection under it, which `handRoom` cannot
	 * say. The price is the durable link it costs. */
	async offerRoom(label: string, link: string): Promise<void> {
		await ask(this.#session, this.#target(), OFFER_ROOM, [label, link], "they did not answer being offered a room");
	}

	/** Offer this peer a durable archive share as data, over this line. */
	async offerArchive(
		directory: string,
		kind: ArchiveShareKind,
		conversation: string | null,
		sturdyref: string,
	): Promise<void> {
		await ask(
			this.#session,
			this.#target(),
			OFFER_ARCHIVE,
			[directory, kind, conversation, sturdyref],
			"they did not answer being offered archive history",
		);
	}

	/** Deliver one direct message with files. Each file is a capability hosted
	 * on this direct session. The receiver pulls bounded chunks through it, so
	 * this works unchanged over every transport that can carry the DM itself. */
	async sendFiles(sources: AttachmentSource[], text = ""): Promise<PostedLine | null> {
		const args: Argument[] = this.#replyInbox ? [text, this.#replyInbox] : [text];
		const line = await sendWithAttachments(this.#session, this.#target(), DM, args, sources);
		return line instanceof Ref ? new PostedLine(this.#session, line) : null;
	}

	/** Pull one file received on this line. */
	fetch(attachment: Attachment, onProgress?: (got: number) => void): Promise<Uint8Array> {
		return fetchBlob(this.#session, attachment, onProgress);
	}

	/** Pull one bounded slice without materializing the complete attachment. */
	fetchChunk(attachment: Attachment, offset: number, maxLen: number): Promise<Uint8Array> {
		return fetchBlobChunk(this.#session, attachment, offset, maxLen);
	}

	/** Give back a file capability this member no longer needs.  status-allow: lifecycle transition */
	release(attachment: Attachment): void {
		this.#session.release(attachment.blob);
	}

	/** Flag whether we are typing to this peer. This is the direct sibling of
	 * `Room.setTyping` with the same posture: fire-and-forget (`tell`), so a
	 * lost flag costs nothing and never blocks a keystroke, and an inbox that
	 * predates the verb breaks the tell silently. */
	typing(on: boolean): Promise<void> {
		// best-effort: a lost flag is the whole loss; the next keystroke sends another.
		return this.#session.tell(this.#target(), TYPING, [on]).catch(() => {});
	}
}
