// Command vocabulary: kinds, powers, and what running one comes to.
//
// The catalog and the parser both need these; neither owns them.

import type { Conv } from "../types.ts";

/** Where a command's authority comes from. See the header. */
export type CommandKind = "tab" | "line" | "granted";

/** One directory this tab holds, as a command sees it.
 *
 * A room's worth of facts about a place, gathered where the state lives so a
 * command can answer questions about a directory the reader is not currently
 * in. `locator` is what they would hand to somebody else; `name` is what the
 * rail calls it, which is all the page's own directory ever needs. */
export interface HeldDirectory {
	locator: string;
	name: string;
	/** The name this directory granted, or empty until it has. */
	nick: string;
	/** Where the reader stands here, whichever level is answering for it. */
	standing: string;
	/** What it advertises: room name to how many are in it. */
	rooms: ReadonlyMap<string, number | null>;
	/** The rooms on it this tab is actually in, named as a reader would hear them. */
	joined: readonly string[];
	connected: boolean;
}

/** What a command may reach.
 *
 * Deliberately small and named one verb at a time rather than handing commands
 * the whole interface: the set of things a command can do should be readable in
 * one screen, and a command that wants something not here is a decision rather
 * than a reach. This is the same argument the rest of the app makes about
 * authority, applied to its own vocabulary.
 *
 * A tab act that needs a handle this window may not hold returns `null` when
 * it used it, or the sentence naming what was missing. The catalog is the
 * only result the composer reads; these powers do not explain a missing
 * handle into the log. Granted acts that share one missing-handle meaning
 * across adapters return a boolean, and the catalog names it. */
export interface CommandPowers {
	/** Say something back where the command was typed. Not sent to anyone. */
	say(text: string): void;
	/** Enter a room on the directory this conversation is on. `null` when the
	 * room was asked for. A sentence when this tab holds no directory to enter
	 * on. */
	joinRoom(name: string): string | null;
	/** Take up a room link: redeem it and enter what it opens. The link is the
	 * whole of the authority. `label` is what to call it here when the reader
	 * said one; empty means ask the room what it is called. `null` when the
	 * link was taken up. A sentence when the link is not a room entry, or this
	 * tab does not hold what it needs. */
	joinLink(link: string, label: string): string | null;
	/** Leave the conversation the command was typed in. */
	leaveHere(): void;
	/** Open a direct line to a member. `null` when the line was opened. A
	 * sentence when this tab does not hold an introduction to them. */
	directMessage(who: string): string | null;
	setTheme(theme: "light" | "dark"): void;
	/** Empty this conversation's history in this window only. */
	clearHere(): void;
	/** Stop showing lines from somebody, in this window only. */
	ignore(name: string): void;
	/** Show them again. False when they were not being ignored. */
	unignore(name: string): boolean;
	/** Everybody this window is currently ignoring. */
	ignored(): readonly string[];
	/** Change the most recent line of ours here. False when there is none this
	 * window still holds the authority for. */
	editLast(text: string): boolean;
	/** Take the most recent line of ours here back. */
	withdrawLast(): boolean;
	/** Say what this room is about. False when this membership holds no topic
	 * capability, which is what an older room leaves it with. */
	setTopic(text: string): boolean;
	/** Say you have stepped away, or `""` that you are back. Written at whichever
	 * of the three levels this reader's standing already comes from — the room,
	 * the directory, or them — so a command never quietly overrules a room they
	 * set apart. False when there is no room membership to say it about. */
	setAway(reason: string): boolean;
	/** Hand the room this was typed in to a member: the live reference crosses
	 * the direct line to them as a handoff, and they may take it up or not.
	 * Nothing durable is minted anywhere, which is what tells it apart from
	 * `roomLink`. False when there is no room membership to hand over, or when
	 * `nick` is this reader — they already hold the room. */
	invite(nick: string): boolean;
	/** Ask a member to leave the room this was typed in, through the room's
	 * steward capability. The room answers that capability only to the
	 * connection that opened it, so for everyone else the room's own refusal
	 * comes back in the conversation. False when this is not a room. */
	kick(nick: string): boolean;
	/** Claim, show, or take this room's durable steward capability. With no
	 * sturdyref, claim it if unissued or show the one this tab holds; with one,
	 * validate and take that exact room's handed-over authority. */
	steward(link?: string): boolean;
	/** The name this conversation's directory granted this reader, or empty
	 * until it has. Direct lines and invitations are toward somebody else, so a
	 * command that names this string is refused rather than opening a line to
	 * yourself. */
	you(): string;
	/** Say a link to a room back where the command was typed: durable data
	 * anybody can redeem, minted at the price of the server recording the room
	 * for good. No name is this conversation's room. A name is a listed room
	 * on this directory. False when there is no room, or no directory, to
	 * link to. */
	roomLink(name?: string): boolean;
	/** Where this reader stands in the room the command was typed in, whichever
	 * level is answering for it. Empty while they are here. */
	standingHere(): string;
	/** Every directory this tab holds, in the order it opened them. */
	directories(): readonly HeldDirectory[];
	/** The conversation-wide grants this membership holds, by name. What makes
	 * the list of commands a reader has a fact about their room. */
	granted(): ReadonlySet<string>;
	showRoster(shown: boolean): void;
	/** The rooms this directory is advertising, with how many are in each. */
	liveRooms(): ReadonlyMap<string, number | null>;
	/** Who is in this room, how each stands, and whether each is reachable
	 * directly. */
	roster(): readonly { name: string; online: boolean; away: string; reachable: boolean }[];
	/** Give this directory back: the name it granted, and everything open on it.
	 * `null` when it was given back. A sentence when this tab holds none. */
	quitDirectory(): string | null;
	/** Open the card about the conversation this was typed in. */
	aboutConversation(): void;
}

/** What running a command comes to.
 *
 * `say` and `action` hand text back to the send path rather than sending it
 * themselves, so one place still owns what reaches a room — a command cannot
 * post something the ordinary path would have refused. */
export type CommandOutcome =
	/** Handled here. Nothing goes to the room. */
	| { kind: "done"; retires?: "conversation" | "directory" }
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
	 * so every named grant must correspond to a capability the conversation can
	 * actually hand over. */
	grant?: string;
	/** Where this command can succeed. Absent means any conversation this tab
	 * can type in. `"room"` means it would refuse in a direct line or a
	 * directory, and offering it there would only teach the refusal. A reader
	 * who wants it goes to a room; those other lists do not advertise the
	 * detour. */
	place?: "room";
	/** What an `@name` after this command completes against. Absent means the
	 * people in the conversation being typed in — a mention reaches somebody
	 * present. `"reachable"` means the directory's direct-message set instead,
	 * because the command's target is somebody to bring in or open a line to,
	 * who is by definition often not here: `/invite` and `/msg` want the people
	 * the members list leaves out, which is the opposite of a mention. Room-wide
	 * names (`here`, `room`) follow the mention path and stay off this list. */
	targets?: "reachable";
	/** What the words after this command complete as, when they are not a
	 * person. `"room"` is a listed room name, written without `#` — `/link`
	 * and `/join` take one. Absent means nothing after the name is a room. */
	argument?: "room";
	/** Other spellings that reach it. IRC clients have carried some of these for
	 * thirty years and a reader's fingers know them. */
	aliases?: readonly string[];
	run(rest: string, powers: CommandPowers, conv: Conv | null): CommandOutcome;
}

/** Which kind of conversation the reader is typing in.
 *
 * Completing and `/help` share this so a command that would refuse here is not
 * offered here. A direct line is not a room with a missing roster; a
 * directory is not a chat. They are different places. */
export type CommandHere = "room" | "direct" | "directory";
