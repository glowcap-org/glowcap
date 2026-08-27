// The room object itself: what a member may ask of the room they are in.
//
// One membership per connection, so nothing here takes a "from" argument — the
// capability the call arrives on is the authority to speak in this room. The
// caller is read from the session whose turn is running rather than one closed
// over when the room was made, because a room reference crosses connections: a
// handoff carries it to another member, and a redeem enlivens it from a link.
//
// Everything a member is granted comes back as a reference: the line they just
// posted, the topic, the upload that will carry a file. There are no ranks to
// check because there is nothing to check them against.

import { currentSession, Ref } from "@pancake/runtime";
import type { Argument, Behavior } from "@pancake/runtime";
import { attachmentRefusal } from "../lib/attachment.ts";
import {
	ATTACH,
	AWAY,
	CALLED,
	HISTORY,
	LEAVE,
	LINE,
	LINK,
	LISTED,
	NOTIFY,
	POST,
	POST_FILES,
	PRIVATE,
	STEWARD,
	SUBSCRIBE,
	TOPIC,
	TYPING,
	UNLISTED,
} from "../lib/protocol.ts";
import {
	ATTACHMENT_REFUSED,
	BAD_ATTACHMENT,
	NICK_TAKEN,
	NICK_TOO_LONG,
	NO_SUCH_ROOM,
	NOT_STEWARD,
	RoomError,
	UPLOAD_INCOMPLETE,
} from "../lib/errors.ts";
import {
	isPrivateRoomKey,
	lineCost,
	MAX_AWAY,
	MAX_IMAGE_DIM,
	MAX_LINE,
	MAX_MESSAGE_FILES,
	nickRefusal,
} from "../lib/limits.ts";
import {
	claimedByAnother,
	findBySession,
	forgetRoom,
	handBack,
	HELD_LINE_REFS,
	heldRoomLinks,
	makeRoomState,
	nickKey,
	type PendingUpload,
	type PostedFile,
	registerRoom,
	roomKey,
	rooms,
	type RoomState,
} from "./registry.ts";
import { noteOperatorChange } from "./operator/revision.ts";
import { allocateUpload, armUploadTimer, broadcastFiles, dropUpload, postStaged, uploadBehavior } from "./files.ts";
import { lineBehavior, topicBehavior } from "./lines.ts";
import { notifyLocalRoom } from "./discovery.ts";
import { broadcast, broadcastTyping, leaveRoom, statePresence } from "./presence.ts";
import { redeemNameVoucher, registeredByAnother } from "./introductions.ts";
import { noteTrouble } from "./journal.ts";
import { historyEnabled, liveKeptLine, readRoomLines, recordRoomLine } from "./history.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";

/** The room behavior for one connection. The room grants at most one live
 * membership to the connection, so `post` needs no "from" argument — the
 * capability the post arrives on is the authority to speak in this room. */
export function roomBehavior(state: RoomState) {
	// The same return the directory declares: a room answers with a value, and
	// one of its verbs answers with a promise of one, because minting a durable
	// name persists before it publishes.
	//
	// The caller is the session whose turn is running, never a session closed
	// over at spawn time. A room reference crosses connections now — a handoff
	// carries it to another member, and a redeem enlivens it from a link — so
	// the connection that asked for the reference and the connection calling it
	// are two different facts. Closing over the first blamed every call on it:
	// a member taking up a handed room was seated *as the inviter's
	// connection*, which silently replaced the inviter's own membership.
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		const session = currentSession();
		if (session === null) throw new Error("a room is reachable only over a session");
		if (verb !== SUBSCRIBE && hasCapabilityArguments(args)) {
			throwAfterReleasingCapabilities(
				session,
				args,
				new Error(`room ${verb} does not take capability arguments`),
			);
		}
		if (verb === SUBSCRIBE) {
			const nick = typeof args[0] === "string" ? args[0] : "";
			const inbox = args[1];
			const voucher = args[2];
			if (
				(args.length !== 2 && args.length !== 3) || !(inbox instanceof Ref) ||
				(args.length === 3 && !(voucher instanceof Uint8Array))
			) {
				throwAfterReleasingCapabilities(
					session,
					args,
					new Error("subscribe needs an inbox capability, a name, and optional name voucher"),
				);
			}
			// This is where a room grants a name, and every member carries what it
			// grants: into the roster, into the line saying somebody joined, and in
			// front of everything they say.
			const unnameable = nickRefusal(nick);
			if (unnameable != null) {
				handBack(session, inbox, "refused room subscriber inbox");
				throw new RoomError(NICK_TOO_LONG, unnameable);
			}
			// The one step here that can fail — spawning the topic export — is done
			// first, before any of the bookkeeping that a failure after it would
			// leave inconsistent: a spent voucher, an unseated previous member, a
			// dropped count. A refusal past this point hands the export back rather
			// than orphaning it. Everything after the spawn is infallible commit.
			let topic: Ref;
			try {
				topic = session.spawn(topicBehavior(state));
			} catch (error) {
				handBack(session, inbox, "unseated room subscriber inbox");
				throw error;
			}
			const refuse = (error: Error): never => {
				handBack(session, topic, "unseated room topic authority");
				handBack(session, inbox, "unseated room subscriber inbox");
				throw error;
			};
			// Whether this subscribe carries proof that the caller is the name's own
			// holder on another connection: a voucher the name capability minted,
			// redeemed exactly once. Checked only where a holder stands in the way,
			// so an unneeded voucher is not burnt; both refusals below yield to it,
			// because both exist to keep one name on one person and the voucher is
			// the proof this is that person.
			const entitled = () => voucher instanceof Uint8Array && redeemNameVoucher(nick, voucher);
			if (claimedByAnother(state, session, nick)) {
				if (!entitled()) refuse(new RoomError(NICK_TAKEN, `name "${nick}" is already claimed`));
				// The same member, moving connections: the seat they held from the
				// old one is re-claimed rather than doubled, the way a same-session
				// resubscribe already replaces itself.
				const key = nickKey(nick);
				const previous = state.members.find(
					(member) => member.session !== session && nickKey(member.nick) === key,
				);
				if (previous !== undefined) leaveRoom(state, previous.session, true);
			} // The room is not the only holder of a name. Someone who left this room
			// but stayed connected still answers to theirs for direct messages, so
			// granting it here would put one name on two people: the roster would
			// show the newcomer while an introduction under that name reached the
			// member who left.
			else if (registeredByAnother(session, nick) && !entitled()) {
				refuse(
					new RoomError(
						NICK_TAKEN,
						`name "${nick}" is held for direct messages by a member who is still connected`,
					),
				);
			}
			// A resubscribe (same connection re-claiming) nets no count change, so it
			// must not fire a discovery event; a fresh membership does.
			const already = findBySession(state, session);
			const wasMember = already !== null;
			// The references to this connection's recent lines outlive the record
			// holding them: re-claiming a place is not saying anything, and a
			// member who can no longer fix what they said a moment ago would have
			// been robbed by bookkeeping.
			const lines = already?.lines ?? [];
			if (wasMember) leaveRoom(state, session, true, true);
			state.members.push({ nick, inbox, session, lines, topic, away: "" });
			noteOperatorChange();
			// The one moment this process KNOWS which member a session
			// carries: state it for the trace, so a viewer can name the peer
			// instead of showing its claimed address.
			statePresence(session);
			// Listed-ness before the join line this arrival also receives.
			// `/join` of a locator seats from that fact; the join broadcast is
			// sent to every member and must not be the first thing the occupant
			// hears, or listed-ness is still unknown and a public link sits in a
			// held clone. Additive: an older client skips the unknown tag.
			// Subscribe still answers the topic capability in this turn — a
			// deferred answer cannot carry a reference.
			session.tell(inbox, NOTIFY, ["room", "", state.private ? UNLISTED : LISTED]).catch((error) => {
				noteTrouble(`a listed notify to ${nick} failed`, error);
			});
			broadcast(state, "room", `${nick} joined (${state.members.length} here)`, "join", nick);
			if (!wasMember) {
				notifyLocalRoom(
					state,
					state.members.length === 1 ? "opened" : "count",
					state.members.length,
				);
			}
			// Who is here, to the arrival alone, carrying the roster as structured
			// trailing args ("roster" then each nick) so a client learns who arrived
			// before it without parsing the text. `subscribe` itself returns a bare
			// ack: success is the resolution, and a claimed nick is the rejection
			// above.
			//
			// A statement of who is present rather than a greeting. It used to read
			// "welcome <nick>", which is how a room addresses everyone about one
			// person, and this is the opposite: one person being told about everyone,
			// privately. It also named the reader twice, once as the one being
			// welcomed and again in the list. The count went with it, because the
			// joining line broadcast a moment ago already carries one.
			const names = state.members.map((m) => m.nick);
			session.tell(inbox, NOTIFY, [
				"room",
				`in the room: ${names.join(", ")}`,
				"roster",
				...names,
			]).catch((error) => {
				noteTrouble(`a roster notify to ${nick} failed`, error);
			});
			// Who is already away. One line each rather than a field on the roster,
			// because that is the same line every later change arrives on: a client
			// learns the state and the change through one path instead of two that
			// have to agree. Bounded by the roster, which the room already bounds.
			for (const m of state.members) {
				if (m.away === "" || m.nick === nick) continue;
				session.tell(inbox, NOTIFY, ["room", `${m.nick} is away: ${m.away}`, AWAY, m.nick, m.away]).catch(
					(error) => {
						noteTrouble(`an away notify to ${nick} failed`, error);
					},
				);
			}
			// What the room is about, if it is about anything. Sent only when there
			// is one, because "no topic" is the absence of this line rather than a
			// line saying nothing — a room that announced an empty topic to every
			// arrival would be telling each of them it had just been taken down.
			if (state.topic !== "") {
				session.tell(inbox, NOTIFY, ["room", `the topic is: ${state.topic}`, TOPIC, state.topic]).catch(
					(error) => {
						noteTrouble(`a topic notify to ${nick} failed`, error);
					},
				);
			}
			// Answering with the topic capability is how a member comes to hold it.
			// An older client ignores the answer and simply has no topic to set.
			return topic;
		}
		if (verb === POST) {
			if (args.length > 1) {
				throw new RoomError(BAD_ATTACHMENT, "post carries trailing args; attach a file with attach()");
			}
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("post needs exactly one text line");
			}
			const member = findBySession(state, session);
			if (member === null) {
				throw new Error("post needs a claimed room membership");
			}
			// What rides after a line's text is the room's own vocabulary —
			// members read presence, typing, and file records there as the room's
			// word — so a post that supplies its own is refused rather than
			// relayed. A file goes out through `attach`, which is the one path
			// that puts a record on the wire.
			// The line goes out named, and the reference that governs it comes
			// back. Holding it is the authority to change or withdraw that one
			// line, so the verbs on it ask nobody who is calling — the same shape
			// `attach` uses, and the reason neither needs a membership check of
			// its own.
			// The room's own cap, held by the room. A client checks too, so a reader
			// is warned while they type rather than refused after they press, but
			// that check is a courtesy to its own reader: nothing stops a peer
			// posting whatever it likes, and every member would carry it.
			const said = typeof args[0] === "string" ? args[0] : "";
			if (lineCost(said) > MAX_LINE) {
				throw new Error(`a line may be at most ${MAX_LINE} bytes`);
			}
			// The reference is minted before the line goes out, because minting is
			// what can fail and a line cannot be un-said: refused after the room
			// had already broadcast it, the poster is told their line failed while
			// everyone else is reading it, and their retry says it twice.
			const id = state.nextLine++;
			const kept = !state.private && historyEnabled() ? liveKeptLine(member.nick, said, Date.now()) : null;
			// No files: a plain line's set is empty, and a later `refile` may still
			// give it one, which is what makes a text line and a file line one kind.
			const line = session.spawn(lineBehavior(state, member.nick, id, [], kept));
			broadcast(state, member.nick, said, LINE, BigInt(id));
			// Listed rooms only: a private room is reference-only, and keeping
			// its lines is a retention decision its holders never made.
			if (kept !== null) recordRoomLine(state.name, kept);
			// Past the bound the oldest goes back, so a member talking all day
			// costs the room a fixed number of exports rather than one per line.
			// Oldest first, because what a member wants to fix is what they just
			// said.
			member.lines.push(line);
			noteOperatorChange();
			while (member.lines.length > HELD_LINE_REFS) handBack(session, member.lines.shift()!);
			return line;
		}
		if (verb === POST_FILES) {
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new RoomError(BAD_ATTACHMENT, "postFiles needs one caption");
			}
			const member = findBySession(state, session);
			if (member === null) throw new Error("postFiles needs a claimed room membership");
			// Nothing is staged, nothing to post. Checked before any effect so the
			// refusal changes no state.
			const staged = [...state.uploads.get(session) ?? []].find((upload) => !upload.posted);
			if (staged === undefined) {
				throw new RoomError(UPLOAD_INCOMPLETE, "no files are staged");
			}
			// The line's own file set, filled by the commit below. It is spawned
			// into the line reference first, empty, so minting — the one step that
			// can fail — happens before the uploads are committed, the same order
			// `post` follows: a line cannot be un-said.
			const files: PostedFile[] = [];
			const id = state.nextLine++;
			const caption = typeof args[0] === "string" && args[0] !== "" ? args[0] : staged.file.name;
			const kept = !state.private && historyEnabled() ? liveKeptLine(member.nick, caption, Date.now()) : null;
			const line = session.spawn(lineBehavior(state, member.nick, id, files, kept));
			postStaged(state, session, files);
			broadcastFiles(state, member.nick, caption, files, LINE, id);
			// The files keep their own bounded bytes; room history keeps only the
			// caption. The line capability retains this row's in-memory token, so
			// refiling and withdrawal cannot reach a prior room generation.
			if (kept !== null) recordRoomLine(state.name, kept);
			member.lines.push(line);
			noteOperatorChange();
			while (member.lines.length > HELD_LINE_REFS) handBack(session, member.lines.shift()!);
			return line;
		}
		if (verb === ATTACH) {
			if (
				(args.length !== 3 && args.length !== 5) || typeof args[0] !== "string" ||
				typeof args[1] !== "string" || typeof args[2] !== "bigint" ||
				(args.length === 5 && (typeof args[3] !== "bigint" || typeof args[4] !== "bigint"))
			) throw new Error("attach needs a name, mime type, size, and optional image dimensions");
			// Begin one upload and answer with the capability that drives it.
			// Holding that capability is the authority to fill or discard this one
			// file, so those verbs need no membership check of their own —
			// only the member this reply reaches can call them.
			const member = findBySession(state, session);
			if (member === null) {
				throw new Error("attach needs a claimed room membership");
			}
			const name = typeof args[0] === "string" ? args[0] : "";
			const mime = typeof args[1] === "string" ? args[1] : "";
			const size = typeof args[2] === "bigint" ? Number(args[2]) : -1;
			const pixelCount = (value: Argument | undefined): number =>
				typeof value === "bigint" && value > 0n && value <= BigInt(MAX_IMAGE_DIM) ? Number(value) : 0;
			const width = pixelCount(args[3]);
			const height = pixelCount(args[4]);
			// The same answer the sender's own check gives, from the one place both
			// of them ask, so a room and a client cannot describe one rule two ways.
			const refused = attachmentRefusal(name, mime, size);
			if (refused !== null) throw new RoomError(ATTACHMENT_REFUSED, refused);
			let pending = state.uploads.get(session);
			if (pending === undefined) {
				pending = new Set();
				state.uploads.set(session, pending);
			}
			if ([...pending].filter((upload) => !upload.posted).length >= MAX_MESSAGE_FILES) {
				throw new RoomError(
					ATTACHMENT_REFUSED,
					`post or abandon an upload first; ${MAX_MESSAGE_FILES} are already open`,
				);
			}
			// Admission and allocation are one transaction in the byte-budget
			// owner. A saturated caller therefore cannot force this process to
			// allocate the very buffer it is about to refuse, while an allocation
			// failure restores the reservation before it escapes.
			const bytes = allocateUpload(size);
			if (bytes === null) {
				throw new RoomError(
					ATTACHMENT_REFUSED,
					"the server is holding all the uploads it can; try again shortly",
				);
			}
			const file: PostedFile = {
				room: state,
				name,
				mime,
				size,
				width,
				height,
				bytes,
				written: 0,
				failure: null,
				waiters: new Set(),
			};
			const upload: PendingUpload = {
				size,
				file,
				posted: false,
				spent: false,
				ref: null,
				expires: null,
			};
			pending.add(upload);
			armUploadTimer(state, session, upload);
			try {
				upload.ref = session.spawn(uploadBehavior(state, session, upload));
			} catch (err) {
				// The one fallible step left, and it is past the commit: nobody can
				// hold an upload whose capability was never handed out, so unwind it
				// here rather than leave its reservation and its timer behind.
				dropUpload(state, session, upload);
				throw err;
			}
			return upload.ref;
		}
		if (verb === TYPING) {
			if (args.length !== 1 || typeof args[0] !== "boolean") {
				throw new Error("typing needs one boolean");
			}
			// Ephemeral: only a claimed member can signal, and the signal reaches the
			// other members alone. An un-subscribed connection is a silent no-op — a
			// stale typing flag is never worth an error.
			const member = findBySession(state, session);
			if (member !== null) broadcastTyping(state, member.nick, args[0] === true, session);
			return null;
		}
		if (verb === HISTORY) {
			if (args.length !== 0) throw new Error("history takes no arguments");
			if (!historyEnabled()) throw new Error("room has no method history");
			if (findBySession(state, session) === null) {
				throw new Error("history needs a claimed room membership");
			}
			if (state.private) return [];
			return readRoomLines(state.name, 100).then((lines) =>
				lines.map((line) => [line.from, line.text, line.at] as Argument)
			) as ReturnType<Behavior>;
		}
		if (verb === STEWARD) {
			if (args.length !== 0) throw new Error("steward takes no arguments");
			// The opener may issue the room's one durable steward. Once issued,
			// later room generations never infer it from being first to arrive:
			// they must present the sturdyref. Repeated asks by the issuing
			// generation are idempotent, so losing the first answer does not lose
			// the authority forever.
			if (session !== state.creator) {
				throw new RoomError(
					NOT_STEWARD,
					"the steward is answered only to the connection that opened this room",
				);
			}
			const links = heldRoomLinks();
			if (links === null) throw new Error("this directory does not publish room links");
			const durable = state.private ? state.key : state.name;
			if (links.hasSteward(durable) && !state.stewardIssuedHere) {
				throw new RoomError(NOT_STEWARD, "this room's steward has already been issued");
			}
			// Mark this generation before the durable commit. If the answer is lost
			// after persistence, its opener may repeat the ask; a reconstructed room
			// still cannot mistake first arrival for ownership.
			state.stewardIssuedHere = true;
			return links.steward(durable, session, state.topic).then((grant) => {
				return [grant.room, grant.identity, grant.steward] as Argument;
			}) as ReturnType<Behavior>;
		}
		if (verb === CALLED) {
			if (args.length !== 0) throw new Error("called takes no arguments");
			// A link is not a name, but the room still has one while it is live:
			// a public room's directory name, or a private room's label. Empty
			// when a private room came back from a link with nobody left to
			// remember what it was called.
			return state.name;
		}
		if (verb === PRIVATE) {
			if (args.length !== 0) throw new Error("private takes no arguments");
			return state.private ? "private" : "listed";
		}
		if (verb === LINK) {
			if (args.length !== 0) throw new Error("link takes no arguments");
			// Asked for with the reference, so nothing here asks who is calling:
			// holding the room is the authority to hold a durable name for it, the
			// same way holding it is the authority to hand it on.
			//
			// A public room's durable name is its name, so this answers exactly
			// what `directory.link` answers. A private room's is its own key,
			// which is already unguessable and says nothing about what the room
			// is called — and it is the only durable name it has, because its
			// label is not an identity.
			const links = heldRoomLinks();
			if (links === null) throw new Error("this directory does not publish room links");
			return links.link(state.private ? state.key : state.name, session, state.topic);
		}
		if (verb === AWAY) {
			if (args.length !== 1 || typeof args[0] !== "string") throw new Error("away needs one reason");
			const member = findBySession(state, session);
			if (member === null) throw new Error("away needs a claimed room membership");
			const why = args[0];
			if (why.length > MAX_AWAY) throw new Error(`an away reason may be at most ${MAX_AWAY} characters`);
			if (why === member.away) return null;
			member.away = why;
			noteOperatorChange();
			broadcast(
				state,
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
			// Drop just this membership, keeping the connection open so the client can
			// enter another room. Idempotent: leaving a room you are not in is a no-op.
			leaveRoom(state, session);
			return null;
		}
		throw new Error(`room has no method ${verb}`);
	};
}

/** A room sturdyref is stable across sessions, while membership stays
 * connection-local. The room behind a link is the same room the directory
 * hands out, so this projects the same semantics; an empty linked room is
 * reconstituted on its first subscribe, whether it emptied earlier or the
 * process has just restarted.
 *
 * The room is published once for the whole Host rather than onto each accepted
 * session, because a link is redeemed by whoever holds it — including a peer
 * whose session opened long after the mint, and who asks the directory nothing.
 * A Host-wide object belongs to no one session, so the caller is the session
 * whose turn is running, which is what `currentSession` answers. */
export function linkedRoomBehavior(durable: string, active: () => boolean = () => true): Behavior {
	// A durable name is either a room's name or a private room's key, and the
	// two are told apart the way the table tells them apart. A private room
	// restored this way has no label: what it is called lives with whoever kept
	// the link, and the room never needed it.
	const isPrivate = isPrivateRoomKey(durable);
	const key = isPrivate ? durable : roomKey(durable);
	return (verb, args) => {
		if (!active()) throw new RoomError(NO_SUCH_ROOM, "this room link was revoked");
		const session = currentSession();
		if (session == null) throw new Error("a room link is reachable only over a session");
		if (verb !== SUBSCRIBE && hasCapabilityArguments(args)) {
			throwAfterReleasingCapabilities(
				session,
				args,
				new Error(`room ${verb} does not take capability arguments`),
			);
		}
		let state = rooms.get(key);
		if (state === undefined) {
			if (verb === CALLED) {
				if (args.length !== 0) throw new Error("called takes no arguments");
				return isPrivate ? "" : durable;
			}
			if (verb === PRIVATE) {
				if (args.length !== 0) throw new Error("private takes no arguments");
				return isPrivate ? "private" : "listed";
			}
			if (verb !== SUBSCRIBE) throw new Error("subscribe to this room before using it");
			state = makeRoomState(isPrivate ? "" : durable, session, {
				private: isPrivate,
				key,
				topic: heldRoomLinks()?.topic(durable) ?? "",
			});
			registerRoom(state);
			try {
				return roomBehavior(state)(verb, args);
			} catch (error) {
				// A cold link has no room until its first membership commits. Invalid
				// arguments, a claimed name, or a failed export must not leave an empty
				// room charged to this connection or blocking the public name. The
				// subscribe transaction performs every fallible step before seating a
				// member, so an empty state here is exactly the uncommitted row.
				if (state.members.length === 0) forgetRoom(state);
				throw error;
			}
		}
		return roomBehavior(state)(verb, args);
	};
}
