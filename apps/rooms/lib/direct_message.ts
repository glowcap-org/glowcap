// One direct line to one peer, and the handle it hands back.
//
// The room introduced the two of you and stepped out, so everything here runs
// on a connection between the two peers. Which side opened it decides what is
// possible: a line this side redeemed owns its connection and can be closed, a
// line riding the connection a peer opened to us cannot.
//
// A message answers with a handle the receiver minted, so a sender can change
// or take back what the receiver is looking at — the direct sibling of the
// reference a room answers a post with, except the durable owner here is the
// person you are talking to.

import { annotateSession, Ref, retainSecondaryFailure } from "@pancake/runtime";
import type { Argument, Session } from "@pancake/runtime";
import { type Attachment, fetchBlob, readAttachments, sendWithAttachments } from "./attachment.ts";
import type { AttachmentSource } from "./attachment.ts";
import { DM, HAND_ROOM, OFFER_ROOM, TYPING } from "./protocol.ts";
import { ask } from "./ask.ts";
import type { Directory } from "./directory.ts";
import { PostedLine } from "./posted_line.ts";

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
	#dm: Ref | null;
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
	async close(): Promise<void> {
		// Spent once. A second close would decrement a count this line has
		// already given up and hang up on whoever holds the connection now.
		if (this.#spent) return;
		if (this.#ownsSession) {
			const rest = (linesOnSession.get(this.#session) ?? 1) - 1;
			if (rest > 0) {
				// Another line is still talking on this connection. Give back
				// what was this line's — the imported capability — and leave the
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
		// needs, so closing is not an option — but the member's capability was
		// this line's to hold and is now nobody's. Give it back, so the exporter
		// can drop the matching export instead of keeping it alive for the life
		// of the tab. The handle is spent afterwards; `say` on a closed line
		// throws rather than reaching whatever that position names next.
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

	/** Open a direct line to `peer` by asking `dir` to introduce you. `onReply`,
	 * if given, fires with each reply and its files on the direct connection;
	 * it is the member we were introduced to, so no name is carried. */
	static async open(
		dir: Directory,
		peer: string,
		onReply?: (text: string, attachments: Attachment[], session: Session) => Argument,
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
				const recordAt = args[1] instanceof Ref ? 2 : 1;
				// The reply inbox answers whatever the receiver mints for this line —
				// a handle the peer holds to change it later. Only a fresh `dm` reaches
				// here; editing an existing line calls that handle, not this inbox.
				return onReply(
					typeof args[0] === "string" ? args[0] : "",
					readAttachments(args, recordAt),
					session,
				);
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
	async say(text: string): Promise<PostedLine | null> {
		const args: Argument[] = this.#replyInbox ? [text, this.#replyInbox] : [text];
		const line = await ask(this.#session, this.#target(), DM, args, "they did not answer the message");
		// The peer answers with a handle to this line when it is one that can be
		// changed, the direct sibling of the reference a room's `post` answers, and
		// a `PostedLine` holds it the same way. A peer may grant no editing
		// authority, in which case the line is simply said.
		return line instanceof Ref ? new PostedLine(this.#session, line) : null;
	}

	/** Hand this peer a room, over this line.
	 *
	 * The reference is the invitation: it crosses as a handoff and arrives as a
	 * working reference to the room, with nothing asked of the room or the
	 * directory and nothing durable minted anywhere. The label is what the
	 * sender calls it. */
	async handRoom(label: string, room: Ref): Promise<void> {
		await ask(this.#session, this.#target(), HAND_ROOM, [label, room], "they did not answer being handed a room");
	}

	/** Offer this peer a room as durable data, over this line.
	 *
	 * Two strings: what to call it, and a link (`Room.link`) they can redeem.
	 * The offer survives every connection under it, which `handRoom` cannot
	 * say; the price was the durable mint the link cost. */
	async offerRoom(label: string, link: string): Promise<void> {
		await ask(this.#session, this.#target(), OFFER_ROOM, [label, link], "they did not answer being offered a room");
	}

	/** Deliver one direct message with files. Each file is a capability hosted
	 * on this direct session; the receiver pulls bounded chunks through it, so
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

	/** Give back a file capability this member no longer needs. */
	release(attachment: Attachment): void {
		this.#session.release(attachment.blob);
	}

	/** Flag whether we are typing to this peer — the direct sibling of
	 * `Room.setTyping`, with the same posture: fire-and-forget (`tell`), so a
	 * lost flag costs nothing and never blocks a keystroke, and an inbox that
	 * predates the verb breaks the tell silently. */
	typing(on: boolean): Promise<void> {
		return this.#session.tell(this.#target(), TYPING, [on]).catch(() => {});
	}
}
