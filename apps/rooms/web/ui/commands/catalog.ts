// The commands this client knows, and which of them a reader holds here.
//
// Possession is the list: a command is here because this conversation handed
// it, not because a role check passed.

import { askedJoin } from "../joining.ts";
import type { Conv } from "../types.ts";
import { MAX_AWAY, PLAIN_AWAY } from "../../../lib/limits.ts";
import type { Command, CommandHere, CommandOutcome, CommandPowers, HeldDirectory } from "./types.ts";
import { ROOM_COMMANDS } from "./room.ts";
import { addressesEveryone, DIRECT_NOT_SELF } from "./targets.ts";

/** Commit a fallible tab act: the power either possessed the handle or named
 * why it did not. The catalog is the only result the composer reads. */
function committed(why: string | null, retires?: "conversation" | "directory"): CommandOutcome {
	if (why != null) return { kind: "refused", why };
	return retires == null ? { kind: "done" } : { kind: "done", retires };
}

/** Say what a directory is advertising, the answer `/list` gives about whichever
 * directory it was asked about. */
function sayRooms(powers: CommandPowers, whose: string, rooms: ReadonlyMap<string, number | null>): CommandOutcome {
	if (rooms.size === 0) return { kind: "refused", why: `${whose} is advertising no rooms.` };
	const said = [...rooms].sort(([a], [b]) => a.localeCompare(b))
		.map(([name, count]) =>
			count === null ? `#${name}: occupancy unknown` : `#${name}: ${count} ${count === 1 ? "person" : "people"}`
		);
	powers.say(said.join("\n"));
	return { kind: "done" };
}

/** Whether `who` is this reader, compared the way the directory grants names. */
function namesYou(who: string, powers: CommandPowers): boolean {
	const you = powers.you();
	return you !== "" && who.toLowerCase() === you.toLowerCase();
}

/** The one directory `asked` names, or the sentence saying why it named none.
 *
 * Matched on what a reader can see: the name the rail shows, or the locator they
 * pasted, either in part. An ambiguous answer lists the candidates rather than
 * picking one, because these are different places and guessing between them
 * would show somebody the wrong one without saying so. */
function pickDirectory(powers: CommandPowers, asked: string): HeldDirectory | string {
	const wanted = asked.toLowerCase();
	const held = powers.directories();
	const hit = held.filter((dir) =>
		dir.name.toLowerCase().includes(wanted) || dir.locator.toLowerCase().includes(wanted)
	);
	if (hit.length === 1) return hit[0];
	if (hit.length === 0) {
		return held.length === 0
			? "This tab holds no directory."
			: `No directory here is called "${asked}". This tab holds ${held.map((dir) => dir.name).join(", ")}.`;
	}
	return `"${asked}" names more than one: ${hit.map((dir) => dir.name).join(", ")}.`;
}

export const COMMANDS: readonly Command[] = [
	{
		name: "help",
		kind: "tab",
		summary: "list what you can do here",
		usage: "/help",
		aliases: ["commands", "?"],
		run(_rest, powers, conv) {
			// What a reader holds here, which is the whole of what they can do.
			// There is no second list of commands they may not use, because a
			// command they cannot use is not here.
			const lines = held(powers.granted(), hereOf(conv)).map((command) => `/${command.name}: ${command.summary}`);
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
		summary: "enter a room by name, or take up a link somebody gave you",
		usage: "/join lobby, or /join ocapn://…/s/… to take up a link",
		needsArgument: true,
		argument: "room",
		run(rest, powers) {
			// A link is the room's own authority and reaches a room no name can:
			// a private one, or a public one on a directory this tab does not
			// hold. Told apart by the swissnum path a sturdyref carries, which is
			// what makes it a way in rather than an address. This is always a
			// destination, never the conversation the command was typed in.
			const want = askedJoin(rest);
			if (want === null) return { kind: "refused", why: "Use /join followed by a room name or a link." };
			if (want.kind === "link") {
				// Anything written after the locator is the reader's own word for
				// the room. Nothing after it means the room should say what it is
				// called: a `/link` locator is to that place, and `/join` of it
				// sits there rather than under an invented name.
				return committed(powers.joinLink(want.link, want.label));
			}
			return committed(powers.joinRoom(want.name));
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
			return { kind: "done", retires: "conversation" };
		},
	},
	{
		name: "msg",
		kind: "tab",
		summary: "open a direct line to someone",
		usage: "/msg alice",
		needsArgument: true,
		targets: "reachable",
		aliases: ["query", "dm"],
		run(rest, powers) {
			const who = rest.trim().split(/\s+/)[0] ?? "";
			if (who === "") return { kind: "refused", why: "Use /msg followed by who to message." };
			const peer = who.replace(/^@/, "");
			if (addressesEveryone(peer)) {
				return { kind: "refused", why: `@${peer} is everyone in the room. A direct message needs one person.` };
			}
			if (namesYou(peer, powers)) {
				return { kind: "refused", why: DIRECT_NOT_SELF };
			}
			return committed(powers.directMessage(peer));
		},
	},
	{
		name: "members",
		kind: "tab",
		summary: "show or hide who is here",
		usage: "/members",
		place: "room",
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
		summary: "ignore somebody in this window, or list who you are ignoring",
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
			// will later doubt they performed. A name is a claim a directory grants
			// and takes back, so the one being ignored may be the reader's own
			// somewhere; their own lines are never hidden, and saying so here is
			// cheaper than them discovering the half that is.
			const yours = powers.directories().some(
				(dir) => dir.nick.toLowerCase() === who.toLowerCase(),
			);
			powers.say(
				`Ignoring ${who} in this window. Their lines still reach the room.` +
					(yours ? ` That is also your own name here, so your own messages stay shown.` : ""),
			);
			return { kind: "done" };
		},
	},
	{
		name: "unignore",
		kind: "tab",
		summary: "stop ignoring somebody here",
		usage: "/unignore alice",
		needsArgument: true,
		run(rest, powers) {
			const who = rest.trim().replace(/^@/, "").split(/\s+/)[0] ?? "";
			if (who === "") return { kind: "refused", why: "Use /unignore followed by who to hear again." };
			powers.say(
				powers.unignore(who) ? `No longer ignoring ${who}.` : `You were not ignoring ${who}.`,
			);
			return { kind: "done" };
		},
	},
	{
		name: "list",
		kind: "tab",
		summary: "show the rooms a directory advertises",
		usage: "/list, or /list annex-server to ask another one this tab holds",
		aliases: ["rooms"],
		run(rest, powers) {
			// Bare asks the directory the reader is in, which is what IRC's LIST
			// means. Named asks one of the others this tab holds, because holding
			// several is ordinary here and looking at one meant going to it.
			const asked = rest.trim();
			if (asked === "") {
				return sayRooms(powers, "This directory", powers.liveRooms());
			}
			const found = pickDirectory(powers, asked);
			if (typeof found === "string") return { kind: "refused", why: found };
			return sayRooms(powers, found.name, found.rooms);
		},
	},
	{
		name: "directories",
		kind: "tab",
		// The nearest thing IRC has is LINKS, which lists the servers on a
		// network. This is not a network — each of these was reached by an address
		// somebody pasted, and they know nothing of each other — so what it can
		// honestly say is what this tab holds.
		summary: "show every directory this tab holds, and how to reach them",
		usage: "/directories",
		aliases: ["dirs", "links"],
		run(_rest, powers) {
			const held = powers.directories();
			if (held.length === 0) return { kind: "refused", why: "This tab holds no directory." };
			const said = held.map((dir) => {
				const rooms = dir.rooms.size;
				const you = dir.nick === "" ? "no name yet" : `you: ${dir.nick}`;
				const where = dir.standing === "" ? "here" : `away: ${dir.standing}`;
				const inThem = dir.joined.length === 0 ? "in none of them" : "in " + dir.joined.join(" ");
				// The address is the point of the line, this page's own included:
				// the rail names that one rather than addressing it, because a
				// reader never chose it — but the moment they want somebody else to
				// come here, it is the thing they need and had nowhere to read.
				return `${dir.name}${dir.connected ? "" : " (not connected)"}: ${you}, ${where}` +
					`, ${rooms} ${rooms === 1 ? "room" : "rooms"} advertised, ${inThem}\n  ${dir.locator}`;
			});
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
		place: "room",
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
				`${found.name}: ${here}, ` +
					`${found.reachable ? "reachable for a direct message" : "not reachable directly"}`,
			);
			return { kind: "done" };
		},
	},
	{
		name: "details",
		kind: "tab",
		summary: "what is known about this conversation",
		usage: "/details",
		aliases: ["info"],
		run(_rest, powers, conv) {
			if (conv === null) return { kind: "refused", why: "Open a conversation first." };
			powers.aboutConversation();
			return { kind: "done" };
		},
	},
	{
		name: "quit",
		kind: "tab",
		summary: "give this directory back, and everything open on it",
		usage: "/quit",
		run(_rest, powers) {
			return committed(powers.quitDirectory(), "directory");
		},
	},
	{
		name: "away",
		// Yours because you are in the room. A member's own standing is theirs to
		// state, and the room writes it against the membership that called rather
		// than against a name anybody could type.
		kind: "tab",
		summary: "say you have stepped away, or that you are back",
		usage: "/away back in ten, or /away on its own to step out and again to return",
		place: "room",
		aliases: ["brb"],
		run(rest, powers, conv) {
			if (conv?.type !== "room") return { kind: "refused", why: "Only a room has anyone to tell." };
			const said = rest.trim();
			if (said.length > MAX_AWAY) {
				return { kind: "refused", why: `A reason may be at most ${MAX_AWAY} characters.` };
			}
			// Bare turns on the standing the reader is not in, which is why this
			// needs no argument: typing it twice steps out and comes back, and
			// neither is a mistake. Reading where they stand rather than always
			// meaning "back" is what makes the second half of that true.
			const why = said !== "" ? said : powers.standingHere() === "" ? PLAIN_AWAY : "";
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
	...ROOM_COMMANDS,
];

/** The place `conv` is, for listing commands. No conversation yet is treated
 * as a direct line: room-only commands have nowhere to run. */
export function hereOf(conv: Conv | null): CommandHere {
	if (conv?.type === "room") return "room";
	if (conv?.type === "directory") return "directory";
	return "direct";
}

/** The commands this reader holds here, given what their conversation has
 * handed them.
 *
 * Everything that needs no reference, everything that travels in the line,
 * everything granted per line (`/edit` and `/delete`, held by having spoken),
 * every conversation-wide grant the room actually answered with, and nothing
 * that only a room can do when this is not a room. A directory is a command
 * line, not a chat: it holds the tab commands that can run there, and nothing
 * that would have to travel in a message. What is absent is what nothing has
 * granted, or what this place cannot run.
 *
 * The arguments are the whole point of the shape: two members of one room can
 * be holding different sets, and a command arrives here by the room having
 * given it rather than by this list growing a condition. `held` reports
 * possession and place, it does not decide them. */
export function held(grants: ReadonlySet<string>, here: CommandHere): readonly Command[] {
	return COMMANDS.filter((command) => {
		if (command.grant !== undefined && !grants.has(command.grant)) return false;
		if (command.place === "room" && here !== "room") return false;
		if (here === "directory" && command.kind !== "tab") return false;
		return true;
	});
}

/** Every command that can be named, held or not.
 *
 * The runner answers these so a typed line still has a precise refusal. The
 * list a reader is offered is `held`, not this: a name they cannot use here
 * is not a discovery, it is an expected failure. */
export function known(): readonly Command[] {
	return COMMANDS;
}
