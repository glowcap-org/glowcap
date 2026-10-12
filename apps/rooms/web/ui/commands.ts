// Slash commands, and where each one's authority comes from.
//
// A chat client usually ships every command it can imagine and lets the server
// refuse the ones you may not use. Permission is a check, the client holds the
// whole vocabulary, and "can I do this" is answered twice, once hopefully in
// the client and once for real on the other side.
//
// This is built on OCapN, where that is the wrong shape. Permission is not a
// check, it is possession: you can ask a room to do something exactly when you
// hold a reference that does it. So the commands a reader has are the ones they
// hold in *this* conversation, and the list is not a second permission check.
// It is what is there. A direct line does not offer `/invite`. A room
// that never handed over `/topic` does not either. Two members of one room can
// see two different command lists, and neither client contains a role, a rank,
// or an `if (isOperator)`.
//
// Three kinds, and the difference is where the authority lives:
//
//   `tab`      Yours because this window and what it already holds are yours.
//              `/help` and `/theme` never leave the page; `/join`, `/leave` and
//              `/msg` reach the wire through references the tab is already
//              holding, which is why they need nothing handed to them. A handle
//              the tab does not hold is a refusal from the catalog, the same
//              shape as a granted command: the power reports the missing
//              handle and does not explain itself.
//   `line`     Travels inside the message text, so any rooms client can send
//              and read one without a protocol extension. `/me`, `/shrug`.
//   `granted`  Needs a reference the room hands you. `/edit`, `/topic`,
//              `/kick`. Holding one is the whole of the permission, which is
//              why these can also be *given away*: a reference is a thing you
//              can pass on, so lending somebody the ability to set the topic
//              costs the room no new concept of a role.
//
// Being a granted command says where the authority comes from, not that it has
// arrived, and three of them hold a real reference today.
//
// `/edit` and `/delete` are usually built by asking a server "is this line
// yours?" and trusting the answer, an identity check standing in for an
// authority. The capability answer is smaller: posting a line hands back a
// reference to the line it made, and holding that reference is the authority to
// change or withdraw it. No ownership is asked about, because none has to be. A
// member who does not hold the handle cannot form the request at all.
//
// `/topic` is the same shape one level up. Subscribing answers with the
// authority to say what the room is about, so every member holds it, the room
// has no ranks to hand out, and a member can pass it to a bot that keeps the
// topic without the room learning what a bot is.
//
// What that buys beyond tidiness is the thing roles are usually invented for. A
// handle can be given away, so a member can pass one to somebody they want to be
// able to take their line down, and a room can hand its own copy to whoever it
// wants moderating, without the room ever growing a concept of a moderator, and
// without every client learning to draw one. Delegation is the mechanism rather
// than a feature built on top of it.
//
// A room built before any of this still works: it answers a post with nothing,
// the tab holds no handle for that line, and `/edit` there says it has no
// message it can still change rather than failing strangely.

import { messageMentions } from "./markdown.ts";
export type {
	Command,
	CommandHere,
	CommandKind,
	CommandOutcome,
	CommandPowers,
	HeldDirectory,
} from "./commands/types.ts";
export { held, hereOf, known } from "./commands/catalog.ts";
export { inviteWhy } from "./commands/targets.ts";
import type { Command, CommandPowers } from "./commands/types.ts";
import type { LineCarried } from "./types.ts";
import { known } from "./commands/catalog.ts";
import { applicationModule } from "./application.ts";

/** The action a line carries, or null when it carries none.
 *
 * The reading half of the `line` kind. A `/me` travels as text, so this is how
 * every client, including ones that have never heard of this registry, meets
 * one that somebody else sent. It lives beside the writing half so the two
 * cannot drift into disagreeing about what an action looks like on the wire. */
export function actionIn(text: string): string | null {
	const named = commandIn(text);
	if (named === null || named.command.kind !== "line") return null;
	const outcome = named.command.run(named.rest, NO_POWERS, null);
	return outcome.kind === "action" ? outcome.text : null;
}

/** The quiet line a message carries, or null when it carries none.
 *
 * The other reading half, beside `actionIn`. A notice is somebody speaking
 * rather than something happening, so unlike an action it keeps its author's
 * name. What it gives up is the notification, so that is why a reader sends
 * one. */
export function noticeIn(text: string): string | null {
	const named = commandIn(text);
	if (named === null || named.command.name !== "notice") return null;
	const outcome = named.command.run(named.rest, NO_POWERS, null);
	return outcome.kind === "say" ? outcome.text.replace(/^\/notice /, "") : null;
}

/** What a chat line carries besides ordinary words, read once where the line
 * enters the store and stamped on it.
 *
 * The log draws thousands of lines and is laid out again on every arrival, so
 * it reads this field instead of parsing. A line that carries nothing gets no
 * field at all, which is almost every line, and the slash guard in `commandIn`
 * means those cost no Wasm call either. */
export function lineCarried(text: string): LineCarried | undefined {
	const action = actionIn(text);
	if (action !== null) return { kind: "action", text: action };
	const notice = noticeIn(text);
	if (notice !== null) return { kind: "notice", text: notice };
	return undefined;
}

/** Whether a line arriving in a room should pull a reader back to it.
 *
 * One authority for that question, because it is answered in two moods: a
 * mention asks for you, and a notice is the one line that can name you without
 * asking. Left as a conjunction at the call site, removing either half still
 * compiled and still passed, which is why it is a function with a test rather
 * than two conditions somebody has to keep remembering to write together. */
export function notifiesYou(text: string, nick: string): boolean {
	return noticeIn(text) === null && messageMentions(text, nick);
}

/** A command read off the wire acts on nothing: reading a line must not join a
 * room or change a theme. Only the `line` kinds are run this way and none of
 * them reaches for a power, so every one of these throwing would be a defect
 * rather than a state to handle. */
const NO_POWERS: CommandPowers = {
	say: () => reading(),
	joinRoom: () => reading(),
	joinLink: () => reading(),
	leaveHere: () => reading(),
	directMessage: () => reading(),
	you: () => reading(),
	setTheme: () => reading(),
	showRoster: () => reading(),
	clearHere: () => reading(),
	ignore: () => reading(),
	unignore: () => reading(),
	ignored: () => reading(),
	editLast: () => reading(),
	withdrawLast: () => reading(),
	setTopic: () => reading(),
	setAway: () => reading(),
	invite: () => reading(),
	kick: () => reading(),
	steward: () => reading(),
	roomLink: () => reading(),
	standingHere: () => reading(),
	directories: () => reading(),
	granted: () => reading(),
	liveRooms: () => reading(),
	roster: () => reading(),
	quitDirectory: () => reading(),
	aboutConversation: () => reading(),
};

function reading(): never {
	throw new Error("a command read off the wire tried to act");
}

/** The command a line names, or null when it names none.
 *
 * A line that opens with a slash and no command anybody knows is ordinary text:
 * a reader typing about `/etc/hosts` is not issuing an order. */
export function commandIn(text: string): { command: Command; rest: string } | null {
	// The Rust reader answers null for anything that does not open with a
	// slash, so asking it about an ordinary sentence is a Wasm call that
	// returns nothing. Almost every line is an ordinary sentence.
	if (text[0] !== "/") return null;
	const encoded = applicationModule().readSlashCommand(text);
	if (encoded == null) return null;
	const parsed = JSON.parse(encoded) as { name: string; restStart: number };
	const command = known().find((candidate) => candidate.name === parsed.name);
	return command === undefined ? null : { command, rest: text.slice(parsed.restStart) };
}
