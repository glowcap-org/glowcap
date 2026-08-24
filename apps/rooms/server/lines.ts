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

import type { Argument } from "@pancake/runtime";
import { currentSession } from "@pancake/runtime";
import { EDIT, EDITED, REFILE, REFILED, SET_TOPIC, TOPIC, WITHDRAW, WITHDRAWN } from "../lib/protocol.ts";
import { lineCost, MAX_LINE, MAX_MESSAGE_FILES, MAX_TOPIC } from "../lib/limits.ts";
import type { PostedFile, RoomState } from "./registry.ts";
import { broadcastFiles, dropFileBytes, forgetFile, postStaged } from "./files.ts";
import { broadcast } from "./presence.ts";
import { forgetRoomLine, updateRoomLine } from "./history.ts";

/** The upload capability `attach` answers with: one file being staged into a
 * message, spent when that message is posted or the file is discarded.
 *
 * Holding it is the whole authority — the room minted it in reply to that
 * member's `attach` on this connection, so `write` and `discard` ask no
 * questions about who is calling. What `write` checks is the file: bytes past
 * the declared size are refused rather than truncated.
 */
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
export function lineBehavior(state: RoomState, from: string, id: number, files: PostedFile[]) {
	let withdrawn = false;
	return (verb: string, args: Argument[]): Argument => {
		if (verb === EDIT) {
			if (withdrawn) throw new Error("that line was withdrawn");
			if (typeof args[0] !== "string") throw new Error("edit needs text");
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
			broadcast(state, from, text, EDITED, BigInt(id));
			if (!state.private) updateRoomLine(state.name, id, text);
			return null;
		}
		if (verb === REFILE) {
			if (withdrawn) throw new Error("that line was withdrawn");
			// A refile down to nothing withdraws the line, and the reference must
			// stop answering just as `withdraw` makes it: editing a blank line back
			// into existence is the state this flag exists to forbid.
			withdrawn = refileLine(state, from, id, files, args);
			return null;
		}
		if (verb === WITHDRAW) {
			// Saying so twice is not an error. The line is gone either way, and a
			// second attempt is somebody making sure rather than doing something
			// wrong.
			if (!withdrawn) {
				withdrawn = true;
				// The line's files go with it: nothing left refers to them, so
				// holding their bytes would charge the room's budget for a line
				// nobody can see. A plain line's set is empty and this is a no-op.
				freeLineFiles(files);
				broadcast(state, from, "", WITHDRAWN, BigInt(id));
				if (!state.private) forgetRoomLine(state.name, id);
			}
			return null;
		}
		throw new Error(`a line has no method ${verb}`);
	};
}

/** Let go of every file a line held, wherever the room counts it. Idempotent
 * per file, so a file already evicted under the byte ceiling is a no-op. */
function freeLineFiles(files: PostedFile[]): void {
	for (const file of files) {
		dropFileBytes(file);
		forgetFile(file);
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
function refileLine(state: RoomState, from: string, id: number, files: PostedFile[], args: Argument[]): boolean {
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
	const session = currentSession();
	if (session === null) throw new Error("a line is reachable only over a session");
	const staged = [...state.uploads.get(session) ?? []].filter((upload) => !upload.posted);
	if (kept.length + staged.length > MAX_MESSAGE_FILES) {
		throw new Error(`a message may carry at most ${MAX_MESSAGE_FILES} files`);
	}
	// Free whatever this refile drops before posting its additions, so the bytes
	// the dropped files held make room under the ceiling rather than pushing the
	// kept ones out. Nothing is committed until this line, past every refusal.
	freeLineFiles(files.filter((file) => !kept.includes(file)));
	const added: PostedFile[] = [];
	postStaged(state, session, added);
	files.length = 0;
	files.push(...kept, ...added);
	if (files.length === 0 && caption === "") {
		// A line with no files and no caption is nothing, so a refile down to
		// empty takes it back rather than leaving a blank bubble. The takedown is
		// the room's own word, tagged so an older client draws it too.
		broadcast(state, from, "", WITHDRAWN, BigInt(id));
		if (!state.private) forgetRoomLine(state.name, id);
		return true;
	}
	broadcastFiles(state, from, caption, files, REFILED, id);
	return false;
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
export function topicBehavior(state: RoomState) {
	return (verb: string, args: Argument[]): Argument => {
		if (verb !== SET_TOPIC) throw new Error(`a topic has no method ${verb}`);
		const said = typeof args[0] === "string" ? args[0] : "";
		if (said.length > MAX_TOPIC) {
			throw new Error(`a topic may be at most ${MAX_TOPIC} characters`);
		}
		if (said === state.topic) return null;
		state.topic = said;
		broadcast(
			state,
			"room",
			said === "" ? "the topic was taken down" : `the topic is now: ${said}`,
			TOPIC,
			said,
		);
		return null;
	};
}
