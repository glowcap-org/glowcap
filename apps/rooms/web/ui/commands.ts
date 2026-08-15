// Slash commands, and where each one's authority comes from.
//
// A chat client usually ships every command it can imagine and lets the server
// refuse the ones you may not use. Permission is a check, the client holds the
// whole vocabulary, and "can I do this" is answered twice — once hopefully in
// the client and once for real on the other side.
//
// This is built on OCapN, where that is the wrong shape. Permission is not a
// check, it is possession: you can ask a room to do something exactly when you
// hold a reference that does it. So the commands a reader has are the ones they
// hold, and the list is not filtered — it is simply what is there. Two members
// of one room can see two different command lists, and neither client contains
// a role, a rank, or an `if (isOperator)`.
//
// Three kinds, and the difference is where the authority lives:
//
//   `tab`      Yours because this window and what it already holds are yours.
//              `/help` and `/theme` never leave the page; `/join`, `/leave` and
//              `/msg` reach the wire through references the tab is already
//              holding, which is why they need nothing handed to them.
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
// change or withdraw it. No ownership is asked about, because none has to be; a
// member who does not hold the handle cannot form the request at all.
//
// `/topic` is the same shape one level up. Subscribing answers with the
// authority to say what the room is about, so every member holds it — the room
// has no ranks to hand out — and a member can pass it to a bot that keeps the
// topic without the room learning what a bot is.
//
// The rest name a grant nothing answers with, which is what `grant` records:
// they are named but not held, so a conversation leaves them off the reader's
// list and running one says what it waits for rather than pretending. The UI
// above them is finished; what is missing is on the other side of the wire.
//
// What that buys beyond tidiness is the thing roles are usually invented for. A
// handle can be given away, so a member can pass one to somebody they want to be
// able to take their line down, and a room can hand its own copy to whoever it
// wants moderating — without the room ever growing a concept of a moderator, and
// without every client learning to draw one. Delegation is the mechanism rather
// than a feature built on top of it.
//
// A room built before any of this still works: it answers a post with nothing,
// the tab holds no handle for that line, and `/edit` there says it has no
// message it can still change rather than failing strangely.

import type { Conv } from "./types.ts";
import { MAX_AWAY, MAX_TOPIC } from "../../lib/limits.ts";
import { mentionsYou } from "./text.ts";

/** Where a command's authority comes from. See the header. */
export type CommandKind = "tab" | "line" | "granted";

/** What a command may reach.
 *
 * Deliberately small and named one verb at a time rather than handing commands
 * the whole interface: the set of things a command can do should be readable in
 * one screen, and a command that wants something not here is a decision rather
 * than a reach. This is the same argument the rest of the app makes about
 * authority, applied to its own vocabulary. */
export interface CommandPowers {
	/** Say something back where the command was typed. Not sent to anyone. */
	say(text: string): void;
	/** Enter a room on the directory this conversation is on. */
	joinRoom(name: string): void;
	/** Leave the conversation the command was typed in. */
	leaveHere(): void;
	/** Open a direct line to a member. */
	directMessage(who: string): void;
	setTheme(theme: "light" | "dark"): void;
	/** Empty this conversation's history in this window only. */
	clearHere(): void;
	/** Stop drawing lines from somebody, in this window only. */
	ignore(name: string): void;
	/** Draw them again. False when they were not being ignored. */
	unignore(name: string): boolean;
	/** Everybody this window is currently not drawing. */
	ignored(): readonly string[];
	/** Change the most recent line of ours here. False when there is none this
	 * window still holds the authority for. */
	editLast(text: string): boolean;
	/** Take the most recent line of ours here back. */
	withdrawLast(): boolean;
	/** Say what this room is about. False when this membership holds no topic
	 * capability, which is what an older room leaves it with. */
	setTopic(text: string): boolean;
	/** Say you have stepped away, or `""` that you are back. False when there is
	 * no room membership to say it about. */
	setAway(reason: string): boolean;
	/** The conversation-wide grants this membership holds, by name. What makes
	 * the list of commands a reader has a fact about their room. */
	granted(): ReadonlySet<string>;
	showRoster(shown: boolean): void;
	/** The rooms this directory is advertising, with how many are in each. */
	liveRooms(): ReadonlyMap<string, number>;
	/** Who is in this room, how each stands, and whether each is reachable
	 * directly. */
	roster(): readonly { name: string; online: boolean; away: string; reachable: boolean }[];
	/** Give this directory back: the name it granted, and everything open on it. */
	quitDirectory(): void;
}

/** What running a command comes to.
 *
 * `say` and `action` hand text back to the send path rather than sending it
 * themselves, so one place still owns what reaches a room — a command cannot
 * post something the ordinary path would have refused. */
export type CommandOutcome =
	/** Handled here. Nothing goes to the room. */
	| { kind: "done" }
	/** Send this instead of what was typed. */
	| { kind: "say"; text: string }
	/** Send this as an action, the `/me` shape. */
	| { kind: "action"; text: string }
	/** Say why, and send nothing. */
	| { kind: "refused"; why: string };

export interface Command {
	name: string;
	kind: CommandKind;
	/** What it does, in the reader's words. `/help` and the completion list both
	 * show this, so it is written once. */
	summary: string;
	/** How it is written, shown when it is written wrong. */
	usage: string;
	/** Whether something has to be written after the name for this to do
	 * anything.
	 *
	 * Enter is the send key, and the completion list borrows it only while it
	 * still has something to offer. Once a whole command is typed, a command
	 * that needs an argument keeps Enter — the reader is mid-thought and the
	 * accepted row leaves them at the argument — and one that needs nothing
	 * gives it back, so `/delete` and Enter withdraws a line instead of costing
	 * a second keystroke for a row that says what is already on screen. Tab
	 * accepts either way.
	 *
	 * A command that sets this must refuse when handed nothing, which
	 * `commands_test.ts` asks of every one of them. */
	needsArgument?: true;
	/** The name of the conversation-wide grant this command needs, when it needs
	 * one the room hands out per membership.
	 *
	 * This is what makes the list of commands a reader holds a fact about their
	 * conversation rather than about this file. `/topic` is here because a room
	 * answers a subscribe with the capability to set it, and a room that offers
	 * none leaves the command named but not held.
	 *
	 * Absent means nothing conversation-wide gates it, which covers three cases
	 * worth telling apart: `tab` and `line` commands need nothing handed to them,
	 * and `/edit` and `/delete` are granted per line rather than per membership,
	 * so a reader holds them by having spoken.
	 *
	 * A command naming a grant nothing ever answers with is simply never held,
	 * which is the honest state of `/kick` and its neighbours today. */
	grant?: string;
	/** Other spellings that reach it. IRC clients have carried some of these for
	 * thirty years and a reader's fingers know them. */
	aliases?: readonly string[];
	run(rest: string, powers: CommandPowers, conv: Conv | null): CommandOutcome;
}

/** A command that needs a reference the room has not handed out yet.
 *
 * It says what it is waiting for rather than failing vaguely or, worse, looking
 * like it worked. Named here so every stub refuses the same way and so there is
 * one place to delete when the room starts granting them. */
function awaitingGrant(name: string): CommandOutcome {
	return {
		kind: "refused",
		why: `/${name} needs the room to hand you that ability, and this room does not offer it yet.`,
	};
}

const COMMANDS: readonly Command[] = [
	{
		name: "help",
		kind: "tab",
		summary: "list what you can do here",
		usage: "/help",
		aliases: ["commands", "?"],
		run(_rest, powers) {
			// What a reader holds, which is the whole of what they can do. There is
			// no second list of commands they may not use, because a command they
			// cannot use is a reference they do not have and so is not here.
			const lines = held(powers.granted()).map((command) => `/${command.name} — ${command.summary}`);
			powers.say(`You can use:\n${lines.join("\n")}`);
			return { kind: "done" };
		},
	},
	{
		name: "me",
		kind: "line",
		summary: "describe an action",
		usage: "/me waves",
		needsArgument: true,
		run(rest) {
			const action = rest.trim();
			return action === ""
				? { kind: "refused", why: "Use /me followed by an action." }
				: { kind: "action", text: action };
		},
	},
	{
		name: "shrug",
		kind: "line",
		summary: "append a shrug to your message",
		usage: "/shrug or /shrug some text",
		run(rest) {
			const shrug = "¯\\_(ツ)_/¯";
			const said = rest.trim();
			return { kind: "say", text: said === "" ? shrug : `${said} ${shrug}` };
		},
	},
	{
		name: "join",
		kind: "tab",
		summary: "enter a room on this directory",
		usage: "/join lobby",
		needsArgument: true,
		run(rest, powers) {
			const name = rest.trim().replace(/^#/, "");
			if (name === "") return { kind: "refused", why: "Use /join followed by a room name." };
			powers.joinRoom(name);
			return { kind: "done" };
		},
	},
	{
		name: "leave",
		kind: "tab",
		summary: "leave the conversation you are in",
		usage: "/leave",
		aliases: ["part"],
		run(_rest, powers, conv) {
			if (conv === null) return { kind: "refused", why: "There is nothing open to leave." };
			powers.leaveHere();
			return { kind: "done" };
		},
	},
	{
		name: "msg",
		kind: "tab",
		summary: "open a direct line to someone",
		usage: "/msg alice",
		needsArgument: true,
		aliases: ["query", "dm"],
		run(rest, powers) {
			const who = rest.trim().split(/\s+/)[0] ?? "";
			if (who === "") return { kind: "refused", why: "Use /msg followed by who to message." };
			powers.directMessage(who.replace(/^@/, ""));
			return { kind: "done" };
		},
	},
	{
		name: "members",
		kind: "tab",
		summary: "show or hide who is here",
		usage: "/members",
		aliases: ["names", "who"],
		run(_rest, powers, conv) {
			if (conv?.type !== "room") return { kind: "refused", why: "Only a room has a member list." };
			powers.showRoster(true);
			return { kind: "done" };
		},
	},
	{
		name: "theme",
		kind: "tab",
		summary: "switch between light and syrup",
		usage: "/theme light or /theme dark",
		needsArgument: true,
		run(rest, powers) {
			const want = rest.trim().toLowerCase();
			if (want !== "light" && want !== "dark") {
				return { kind: "refused", why: "Use /theme light or /theme dark." };
			}
			powers.setTheme(want);
			return { kind: "done" };
		},
	},
	{
		name: "clear",
		kind: "tab",
		summary: "empty this conversation in this window",
		usage: "/clear",
		run(_rest, powers, conv) {
			if (conv === null) return { kind: "refused", why: "There is nothing open to clear." };
			powers.clearHere();
			return { kind: "done" };
		},
	},
	{
		name: "ignore",
		kind: "tab",
		summary: "stop drawing somebody's lines here, or list who you are ignoring",
		usage: "/ignore alice, or /ignore on its own",
		run(rest, powers) {
			const who = rest.trim().replace(/^@/, "").split(/\s+/)[0] ?? "";
			if (who === "") {
				const already = powers.ignored();
				powers.say(
					already.length === 0 ? "You are not ignoring anybody." : `You are ignoring ${already.join(", ")}.`,
				);
				return { kind: "done" };
			}
			powers.ignore(who);
			// Said plainly, because nothing else changes on screen except lines
			// quietly not appearing — and a silent act that quiet is one a reader
			// will later doubt they performed.
			powers.say(`Ignoring ${who} in this window. Their lines still reach the room.`);
			return { kind: "done" };
		},
	},
	{
		name: "unignore",
		kind: "tab",
		summary: "draw somebody's lines again",
		usage: "/unignore alice",
		needsArgument: true,
		run(rest, powers) {
			const who = rest.trim().replace(/^@/, "").split(/\s+/)[0] ?? "";
			if (who === "") return { kind: "refused", why: "Use /unignore followed by who to hear again." };
			powers.say(
				powers.unignore(who) ? `Drawing ${who} again.` : `You were not ignoring ${who}.`,
			);
			return { kind: "done" };
		},
	},
	{
		name: "list",
		kind: "tab",
		summary: "show the rooms this directory advertises",
		usage: "/list",
		aliases: ["rooms"],
		run(_rest, powers) {
			const rooms = [...powers.liveRooms()].sort(([a], [b]) => a.localeCompare(b));
			if (rooms.length === 0) return { kind: "refused", why: "This directory is advertising no rooms." };
			const said = rooms.map(([name, count]) => `#${name} — ${count} ${count === 1 ? "person" : "people"}`);
			powers.say(said.join("\n"));
			return { kind: "done" };
		},
	},
	{
		name: "whois",
		kind: "tab",
		summary: "what is known about somebody here",
		usage: "/whois alice",
		needsArgument: true,
		run(rest, powers) {
			const who = rest.trim().replace(/^@/, "").split(/\s+/)[0] ?? "";
			if (who === "") return { kind: "refused", why: "Use /whois followed by who to ask about." };
			const found = powers.roster().find((member) => member.name.toLowerCase() === who.toLowerCase());
			if (found === undefined) return { kind: "refused", why: `Nobody here is called ${who}.` };
			// Everything this tab actually knows, which is less than an IRC server
			// would tell you and is all of it: a name is granted by a directory for
			// as long as a connection holds it, and there is no account behind it to
			// look up.
			const here = found.away !== "" ? `away: ${found.away}` : found.online ? "here now" : "not here just now";
			powers.say(
				`${found.name} — ${here}, ` +
					`${found.reachable ? "reachable for a direct message" : "not reachable directly"}`,
			);
			return { kind: "done" };
		},
	},
	{
		name: "quit",
		kind: "tab",
		summary: "give this directory back, and everything open on it",
		usage: "/quit",
		run(_rest, powers) {
			powers.quitDirectory();
			return { kind: "done" };
		},
	},
	{
		name: "nick",
		kind: "granted",
		summary: "ask this directory for a different name",
		usage: "/nick newname",
		needsArgument: true,
		grant: "nick",
		run(rest) {
			return rest.trim() === ""
				? { kind: "refused", why: "Use /nick followed by the name to ask for." }
				: awaitingGrant("nick");
		},
	},
	{
		name: "away",
		// Yours because you are in the room. A member's own standing is theirs to
		// state, and the room writes it against the membership that called rather
		// than against a name anybody could type.
		kind: "tab",
		summary: "say you have stepped away, or that you are back",
		usage: "/away back in ten, or /away on its own once you are",
		aliases: ["brb"],
		run(rest, powers, conv) {
			if (conv?.type !== "room") return { kind: "refused", why: "Only a room has anyone to tell." };
			// Bare means back, which is what `/away` has meant in every client for
			// thirty years and is why this needs no argument: a reader typing it
			// twice steps out and comes back, and neither is a mistake.
			const why = rest.trim();
			if (why.length > MAX_AWAY) {
				return { kind: "refused", why: `A reason may be at most ${MAX_AWAY} characters.` };
			}
			return powers.setAway(why) ? { kind: "done" } : {
				kind: "refused",
				why: "There is no room to say that in.",
			};
		},
	},
	{
		name: "notice",
		// Travels in the line, the same way `/me` does, so it needs nothing from
		// the room and every client that can read a line can read one. What makes
		// it quiet is this side: a notice never raises a notification, which is
		// the whole of what a reader is asking for when they send one.
		kind: "line",
		summary: "say something that does not ping anyone",
		usage: "/notice the build is green again",
		needsArgument: true,
		run(rest) {
			const said = rest.trim();
			return said === ""
				? { kind: "refused", why: "Use /notice followed by what to say quietly." }
				: { kind: "say", text: `/notice ${said}` };
		},
	},
	{
		name: "edit",
		// Granted, and now actually granted: the room hands back a reference to
		// each line it takes, and holding one is the authority to change that line.
		// Nothing here asks whether the line is ours, because a line that is not
		// leaves us without the reference and there is nothing to ask.
		kind: "granted",
		summary: "change what your last message said",
		usage: "/edit what it should have said",
		needsArgument: true,
		run(rest, powers) {
			const said = rest.trim();
			if (said === "") return { kind: "refused", why: "Use /edit followed by what the message should say." };
			return powers.editLast(said) ? { kind: "done" } : {
				kind: "refused",
				why: "There is no message of yours here that can still be changed.",
			};
		},
	},
	{
		name: "delete",
		kind: "granted",
		summary: "withdraw your last message",
		usage: "/delete",
		aliases: ["del", "withdraw"],
		run(_rest, powers) {
			return powers.withdrawLast() ? { kind: "done" } : {
				kind: "refused",
				why: "There is no message of yours here that can still be taken back.",
			};
		},
	},
	{
		name: "topic",
		kind: "granted",
		summary: "set what this room is about",
		usage: "/topic what we are talking about, /topic to read it, or /topic - to take it down",
		grant: "topic",
		run(rest, powers, conv) {
			if (conv?.type !== "room") return { kind: "refused", why: "Only a room has a topic." };
			const said = rest.trim();
			// Written bare it reads the topic out, the way every IRC client has for
			// thirty years. Somebody who wanted to clear it can still say so.
			if (said === "") {
				powers.say(conv.topic ? `The topic is: ${conv.topic}` : "This room has no topic.");
				return { kind: "done" };
			}
			const wanted = said === "-" ? "" : said;
			if (wanted.length > MAX_TOPIC) {
				return { kind: "refused", why: `A topic may be at most ${MAX_TOPIC} characters.` };
			}
			return powers.setTopic(wanted) ? { kind: "done" } : {
				kind: "refused",
				why: "This room did not offer a topic to set.",
			};
		},
	},
	{
		name: "invite",
		kind: "granted",
		summary: "invite someone into this room",
		usage: "/invite alice",
		needsArgument: true,
		grant: "invite",
		run() {
			return awaitingGrant("invite");
		},
	},
	{
		name: "kick",
		kind: "granted",
		summary: "remove someone from this room",
		usage: "/kick alice",
		needsArgument: true,
		grant: "kick",
		run() {
			return awaitingGrant("kick");
		},
	},
];

/** The commands this reader holds, given what their conversation has handed
 * them.
 *
 * Everything that needs no reference, everything that travels in the line,
 * everything granted per line (`/edit` and `/delete`, held by having spoken),
 * and every conversation-wide grant the room actually answered with. What is
 * absent is what nothing has granted.
 *
 * The argument is the whole point of the shape: two members of one room can be
 * holding different sets, and a command arrives here by the room having given
 * it rather than by this list growing a condition. `held` reports possession,
 * it does not decide it. */
export function held(grants: ReadonlySet<string>): readonly Command[] {
	return COMMANDS.filter((command) => command.grant === undefined || grants.has(command.grant));
}

/** Every command that can be named, held or not.
 *
 * Completion offers these so a reader can discover a granted command and be
 * told what it waits for, rather than typing into silence. Knowing a name is
 * not holding the reference, which is exactly the distinction this app is
 * built on. */
export function known(): readonly Command[] {
	return COMMANDS;
}

/** The action a line carries, or null when it carries none.
 *
 * The reading half of the `line` kind. A `/me` travels as text, so this is how
 * every client — including ones that have never heard of this registry — meets
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
 * name; what it gives up is the notification, which is why a reader sends one. */
export function noticeIn(text: string): string | null {
	const named = commandIn(text);
	if (named === null || named.command.name !== "notice") return null;
	const outcome = named.command.run(named.rest, NO_POWERS, null);
	return outcome.kind === "say" ? outcome.text.replace(/^\/notice /, "") : null;
}

/** Whether a line arriving in a room should pull a reader back to it.
 *
 * One authority for that question, because it is answered in two moods: a
 * mention asks for you, and a notice is the one line that can name you without
 * asking. Left as a conjunction at the call site, removing either half still
 * compiled and still passed, which is why it is a function with a test rather
 * than two conditions somebody has to keep remembering to write together. */
export function notifiesYou(text: string, nick: string): boolean {
	return noticeIn(text) === null && mentionsYou(text, nick);
}

/** A command read off the wire acts on nothing: reading a line must not join a
 * room or change a theme. Only the `line` kinds are run this way and none of
 * them reaches for a power, so every one of these throwing would be a defect
 * rather than a state to handle. */
const NO_POWERS: CommandPowers = {
	say: () => reading(),
	joinRoom: () => reading(),
	leaveHere: () => reading(),
	directMessage: () => reading(),
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
	granted: () => reading(),
	liveRooms: () => reading(),
	roster: () => reading(),
	quitDirectory: () => reading(),
};

function reading(): never {
	throw new Error("a command read off the wire tried to act");
}

/** The command a line names, or null when it names none.
 *
 * A line that opens with a slash and no command anybody knows is ordinary text:
 * a reader typing about `/etc/hosts` is not issuing an order. */
export function commandIn(text: string): { command: Command; rest: string } | null {
	const match = text.match(/^\/([\w?]+)(?:\s+([\s\S]*))?$/);
	if (match === null) return null;
	const name = match[1].toLowerCase();
	const command = COMMANDS.find((candidate) =>
		candidate.name === name || (candidate.aliases?.includes(name) ?? false)
	);
	return command === undefined ? null : { command, rest: match[2] ?? "" };
}
