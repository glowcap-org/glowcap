// What holding a line's reference lets somebody do to it, and the same one
// level up for the room's topic.
//
// Neither verb asks who is calling, and that is the design rather than an
// omission: the reference went to whoever posted the line, and a member without
// it cannot form the request. Possession already answered the question, which
// is also what makes the authority passable — a member can hand it on, and a
// room could keep a copy to give whoever it wants moderating, without either
// side learning what a moderator is.
//
// A line owns its files, so taking it back frees them and refiling replaces the
// set. Refiling down to nothing takes the line back, because a message with no
// files and nothing said is not a message.

import type { Argument, Session } from "@pancake/runtime";
import { currentSession } from "@pancake/runtime";
import {
	EDIT,
	EDITED,
	GOVERNS,
	KICK,
	REFILE,
	REFILED,
	SET_TOPIC,
	TOPIC,
	WITHDRAW,
	WITHDRAWN,
} from "../lib/protocol.ts";
import { isManagedRoomId, lineCost, MAX_LINE, MAX_MESSAGE_FILES, MAX_TOPIC } from "../lib/limits.ts";
import { NOT_STEWARD, RoomError } from "../lib/errors.ts";
import { nickKey, type PostedFile, roomDurableIdentity, roomKey, type RoomState } from "./registry.ts";
import type { RoomServerContext } from "./context.ts";
import type { RoomLinks } from "./room_links.ts";
import { broadcast, leaveRoom } from "./presence.ts";
import { type LiveKeptLine, type RoomHistory } from "./history.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";

function refuseCapabilityArguments(args: Argument[], surface: string): void {
	if (!hasCapabilityArguments(args)) return;
	const session = currentSession();
	if (session == null) throw new Error(`${surface} is reachable only over a session`);
	throwAfterReleasingCapabilities(session, args, new Error(`${surface} does not take capability arguments`));
}

/** What holding a line's reference lets somebody do to it.
 *
 * Nothing here asks who is calling, and that is the whole design rather than an
 * omission: the reference went to the member whose `post` made the line, and a
 * member without it cannot form either request. Ownership is not checked
 * because it is not a question — possession already answered it.
 *
 * Which is also what makes the authority passable. Whoever holds this can hand
 * it on, so a member can let somebody else take their line down and a room can
 * keep a copy to give whoever it wants moderating, and neither party has to
 * learn what a moderator is.
 *
 * A withdrawn line is gone for good. Editing one afterwards would put text back
 * on screen that its author had taken down, so the reference stops answering
 * rather than pretending, and says which of the two happened.
 *
 * `files` is the line's own file set, empty for a plain line. The line owns it:
 * withdrawing the line frees those files, and `refile` replaces the set,
 * freeing whatever it drops. Naming the files here rather than leaving them
 * loose in the room's held list is what makes a file line's edit and takedown
 * mean the same thing a text line's do. */
export function lineBehavior(
	ctx: RoomServerContext,
	state: RoomState,
	history: RoomHistory,
	from: string,
	id: number,
	files: PostedFile[],
	kept: LiveKeptLine | null,
) {
	let withdrawn = false;
	return (verb: string, args: Argument[]): Argument => {
		refuseCapabilityArguments(args, "a line");
		if (verb === EDIT) {
			if (withdrawn) throw new Error("that line was withdrawn");
			if (args.length !== 1 || typeof args[0] !== "string") throw new Error("edit needs one text value");
			const text = args[0];
			// Counted the way the wire counts and the way a poster's own composer
			// counts. In JavaScript's own units this let an edit through at four
			// times the cap, because an emoji is two of those and four bytes.
			if (lineCost(text) > MAX_LINE) {
				throw new Error(`a line may be at most ${MAX_LINE} bytes`);
			}
			// Text only, so the files ride through a caption change untouched: the
			// members keep the blobs they hold, and the room re-sends none. `refile`
			// is the one verb that changes what a line carries.
			broadcast(ctx, state, from, text, EDITED, BigInt(id));
			if (kept !== null) history.update(roomDurableIdentity(state), kept, text);
			return null;
		}
		if (verb === REFILE) {
			if (withdrawn) throw new Error("that line was withdrawn");
			// A refile down to nothing withdraws the line, and the reference must
			// stop answering just as `withdraw` makes it: editing a blank line back
			// into existence is the state this flag exists to forbid.
			const session = currentSession();
			if (session == null) throw new Error("a line is reachable only over a session");
			withdrawn = refileLine(ctx, state, history, from, id, files, kept, args, session);
			return null;
		}
		if (verb === WITHDRAW) {
			if (args.length !== 0) throw new Error("withdraw takes no arguments");
			// Saying so twice is not an error. The line is gone either way, and a
			// second attempt is somebody making sure rather than doing something
			// wrong.
			if (!withdrawn) {
				withdrawn = true;
				// The line's files go with it: nothing left refers to them, so
				// holding their bytes would charge the room's budget for a line
				// nobody can see. A plain line's set is empty and this is a no-op.
				freeLineFiles(ctx, files);
				broadcast(ctx, state, from, "", WITHDRAWN, BigInt(id));
				if (kept !== null) history.forget(roomDurableIdentity(state), kept);
			}
			return null;
		}
		throw new Error(`a line has no method ${verb}`);
	};
}

/** Let go of every file a line held, wherever the room counts it. Idempotent
 * per file, so a file already evicted under the byte ceiling is a no-op. */
function freeLineFiles(ctx: RoomServerContext, files: PostedFile[]): void {
	for (const file of files) {
		ctx.files.dropFileBytes(file);
		ctx.files.forgetFile(file);
	}
}

/** Rebuild one line's file set from `refile(caption, ...keep)` and re-broadcast
 * it, or withdraw the line when nothing is left.
 *
 * Prepared before any effect: the caption and the kept indices are validated,
 * and the total is checked against `MAX_MESSAGE_FILES`, before a file is freed
 * or a staged upload is committed. So a refused refile leaves the line exactly
 * as it was — its files still held, its staged uploads still stageable.
 *
 * Answers whether the line is now withdrawn, which a refile to no files and no
 * caption does. */
function refileLine(
	ctx: RoomServerContext,
	state: RoomState,
	history: RoomHistory,
	from: string,
	id: number,
	files: PostedFile[],
	keptLine: LiveKeptLine | null,
	args: Argument[],
	session: Session,
): boolean {
	if (typeof args[0] !== "string") throw new Error("refile needs a caption");
	const caption = args[0];
	if (lineCost(caption) > MAX_LINE) throw new Error(`a caption may be at most ${MAX_LINE} bytes`);
	// Which of the line's current files to keep, in the order asked. Each index
	// is validated against the set it names and refused if it is out of range or
	// repeats one, so a kept run is always a real, distinct subsequence.
	const kept: PostedFile[] = [];
	const seen = new Set<number>();
	for (const arg of args.slice(1)) {
		if (typeof arg !== "bigint") throw new Error("refile keeps files by index");
		const at = Number(arg);
		if (!Number.isSafeInteger(at) || at < 0 || at >= files.length) {
			throw new Error(`no file at index ${at} on this line`);
		}
		if (seen.has(at)) throw new Error(`file ${at} is kept twice`);
		seen.add(at);
		kept.push(files[at]);
	}
	const staged = [...state.uploads.values()].flatMap((uploads) =>
		[...uploads].filter((upload) => upload.session === session && !upload.posted)
	);
	if (kept.length + staged.length > MAX_MESSAGE_FILES) {
		throw new Error(`a message may carry at most ${MAX_MESSAGE_FILES} files`);
	}
	// Free whatever this refile drops before posting its additions, so the bytes
	// the dropped files held make room under the ceiling rather than pushing the
	// kept ones out. Nothing is committed until this line, past every refusal.
	freeLineFiles(ctx, files.filter((file) => !kept.includes(file)));
	const added: PostedFile[] = [];
	ctx.files.postStagedFromSession(state, session, added);
	files.length = 0;
	files.push(...kept, ...added);
	if (files.length === 0 && caption === "") {
		// A line with no files and no caption is nothing, so a refile down to
		// empty takes it back rather than leaving a blank bubble. The takedown is
		// the room's own word, tagged so an older client draws it too.
		broadcast(ctx, state, from, "", WITHDRAWN, BigInt(id));
		if (keptLine !== null) history.forget(roomDurableIdentity(state), keptLine);
		return true;
	}
	ctx.files.broadcastFiles(state, from, caption, files, REFILED, id);
	if (keptLine !== null) history.update(roomDurableIdentity(state), keptLine, caption);
	return false;
}

/** The authority to remove a member, as a capability.
 *
 * The room publishes this only when its opening connection claims it. From
 * there the durable reference can be shared with whoever should moderate, and
 * the room never learns a rank or a moderator identity. Nothing here asks who
 * is calling — possession is the whole answer, the same shape as a line's
 * reference and the topic's.
 *
 * A kick is an ordinary departure with the steward's word said first: the
 * member hears it themselves, everyone reads why the leave that follows
 * happened, and nothing durable is minted — the person can walk straight
 * back in, which is what tells asking-to-leave apart from banishment. A
 * ban would need an identity to hold against a name, and a nick is not
 * one; that boundary stays stated here until identity gives it ground. */
export function stewardBehavior(ctx: RoomServerContext, state: RoomState) {
	return (verb: string, args: Argument[]): Argument => {
		refuseCapabilityArguments(args, "a steward");
		if (verb !== KICK) throw new Error(`a steward has no method ${verb}`);
		if (args.length !== 1 || typeof args[0] !== "string") throw new Error("kick needs one member name");
		const nick = args[0];
		if (nick === "") throw new Error("kick names the member to ask out");
		const key = nickKey(nick);
		const member = state.members.find((m) => nickKey(m.nick) === key);
		if (member === undefined) throw new Error(`nobody here answers to "${nick}"`);
		// The terminal membership fact reaches the member through `leaveRoom`;
		// everybody who remains first hears why the leave that follows happened.
		broadcast(ctx, state, "room", `${member.nick} was asked to leave`);
		leaveRoom(ctx, state, member.session, { ended: `You were asked to leave #${state.name}.` });
		return null;
	};
}

/** The durable steward publication for one room identity.
 *
 * It captures no live room state: a restart or an empty-room reclamation makes
 * a new `RoomState`, and a durable capability retaining the old object would
 * govern a dead generation. `governs` remains answerable while the room is
 * empty so a client can validate the authority before anybody joins; `kick`
 * resolves the current generation at the moment it is used. */
export function linkedStewardBehavior(
	ctx: RoomServerContext,
	durable: string,
	roomIdentity: string,
	active: () => boolean,
) {
	const key = isManagedRoomId(durable) ? durable : roomKey(durable);
	return (verb: string, args: Argument[]): Argument => {
		refuseCapabilityArguments(args, "a durable steward");
		if (!active()) {
			throw new RoomError(NOT_STEWARD, "this steward capability was revoked");
		}
		if (verb === GOVERNS) {
			if (args.length !== 0) throw new Error("governs takes no arguments");
			return roomIdentity;
		}
		const state = ctx.live.rooms.get(key);
		if (state === undefined) throw new Error("that room is not occupied");
		return stewardBehavior(ctx, state)(verb, args);
	};
}

/** What this room is about, as a capability.
 *
 * `subscribe` answers with one of these, so every member holds the authority to
 * say what the room is for. That is the room having no ranks rather than an
 * oversight: there is no operator to be, and a reference is a thing you can
 * pass on, so a member can hand this to a bot that keeps the topic without the
 * room ever learning what a bot is.
 *
 * The change is announced as a plain room line carrying the `topic` tag, so a
 * client that has never heard of topics still shows the sentence saying it
 * moved. Nobody is named as having set it: the caller is whoever holds the
 * reference, which may not be the member it was handed to, and a room that
 * cannot know who acted should not claim to. */
export function topicBehavior(ctx: RoomServerContext, state: RoomState, links: RoomLinks | null = null) {
	return (verb: string, args: Argument[]): Argument | Promise<Argument> => {
		refuseCapabilityArguments(args, "a room topic");
		if (verb !== SET_TOPIC) throw new Error(`a topic has no method ${verb}`);
		if (args.length !== 1 || typeof args[0] !== "string") throw new Error("setTopic needs one text value");
		const said = args[0];
		if (said.length > MAX_TOPIC) {
			throw new Error(`a topic may be at most ${MAX_TOPIC} characters`);
		}
		if (said === state.topic) return null;
		const durable = roomDurableIdentity(state);
		return (links == null ? Promise.resolve() : links.setTopic(durable, said)).then(() => {
			state.topic = said;
			broadcast(
				ctx,
				state,
				"room",
				said === "" ? "the topic was taken down" : `the topic is now: ${said}`,
				TOPIC,
				said,
			);
			return null;
		});
	};
}
