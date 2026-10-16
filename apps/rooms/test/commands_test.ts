// What the command registry declares about itself, held against what its
// commands actually do.
//
// Two of a command's fields are read by the interface rather than by the
// command: `needsArgument` decides whether the completion list keeps the Enter
// key, `grant` decides whether a conversation that can run it lists it, and
// `place` decides whether this conversation can run it at all.
// Rust owns the metadata and interpretation. The browser gesture adapter could
// still disagree with the displayed affordance, and
// a disagreement is silent, a command wrongly marked as needing an argument
// stops running on Enter, which looks like a dead key rather than like
// a wrong flag. So each is asked of every command here.

import { type Command, type CommandHere, type CommandPowers, held, hereOf, known } from "../web/ui/commands.ts";
import { NO_DIRECTORY_TO_GIVE_BACK, NOT_ON_A_DIRECTORY } from "../web/ui/commands/targets.ts";
import { prepareComposerSend } from "../web/ui/composer/send.ts";
import type { ComposerDraft } from "../web/ui/composer/send.ts";
import type { Conv } from "../web/ui/types.ts";
import {
	SESSION_COMMAND_REQUIREMENTS,
	SESSION_CONTENT,
	SESSION_METHOD_REQUIREMENTS,
} from "../lib/session_content_data.ts";

import { initializeApplication } from "./support/application.ts";
await initializeApplication();
const DIRECTORY_NO_CHAT = "This view does not carry messages. Use a command.";

function fail(message: string): never {
	throw new Error(message);
}

Deno.test("session content metadata keeps workspace, custody and target powers separate", () => {
	const { participation, custody } = SESSION_CONTENT.groups;
	const fields = new Set<string>([...participation, ...custody]);
	if (fields.size !== participation.length + custody.length) fail("preset groups overlap");
	if (
		SESSION_CONTENT.presets.administrator.values.some((permission: string) =>
			participation.some((field: string) => field === permission)
		)
	) {
		fail("custody preset acquired participation");
	}
	if (SESSION_METHOD_REQUIREMENTS.roomBridgeForm.workspace.join() !== "observeWorkspace") {
		fail("form inspection widened");
	}
	if (!SESSION_METHOD_REQUIREMENTS.command.targets.some((target) => target === "nestedCommand")) {
		fail("command target missing");
	}
	if (SESSION_METHOD_REQUIREMENTS.facet !== null || SESSION_METHOD_REQUIREMENTS.revoke !== null) {
		fail("legacy lifecycle admitted");
	}
	if (SESSION_COMMAND_REQUIREMENTS.linkRoom !== null) fail("plan builder became a callable command");
	for (const name of ["selectArchive", "dropRoomManager", "dropRoomModerator"] as const) {
		if (!SESSION_COMMAND_REQUIREMENTS[name].workspace.some((permission) => permission === "manageCustody")) {
			fail(`${name} lost custody requirement`);
		}
	}
	for (const name of ["leaveDirectory", "leaveConversation", "closeDirect"] as const) {
		if (SESSION_COMMAND_REQUIREMENTS[name].targets.length) fail(`${name} cannot release unavailable custody`);
	}
});

/** Read-only context is available. Reaching an effect before required input
 * is admitted fails loudly. Rust interpretation cannot act through this port. */
const TRAP: CommandPowers = new Proxy({}, {
	get(_target, verb) {
		if (verb === "you" || verb === "standingHere") return () => "";
		return () => fail(`a command reached for ${String(verb)} when it should have refused`);
	},
}) as CommandPowers;

const NO_GRANTS: ReadonlySet<string> = new Set();
const ROOM = { type: "room", lineBytes: 8192, grants: NO_GRANTS } as Conv;

function draft(text: string, files: readonly File[] = []): ComposerDraft {
	return { text, files, previews: [] };
}

Deno.test("composer commits the exact non-removed preview selection", () => {
	const prepared = prepareComposerSend(ROOM, {
		text: "https://one.example https://two.example",
		files: [],
		previews: [
			{
				id: 1,
				url: "https://one.example/",
				state: "ready",
				attempt: 0,
				metadata: { requestedUrl: "https://one.example/", url: "https://one.example/", images: [] },
			},
			{ id: 2, url: "https://two.example/", state: "removed", attempt: 0 },
		],
	}, QUIET);
	if (prepared.kind !== "send" || prepared.previewUrls.join() !== "https://one.example/") {
		fail(`the composer did not preserve its exact preview intent: ${JSON.stringify(prepared)}`);
	}
});

Deno.test("command names and aliases identify exactly one command", () => {
	const owner = new Map<string, string>();
	for (const command of known()) {
		for (const name of [command.name, ...command.aliases ?? []]) {
			const key = name.toLowerCase();
			const previous = owner.get(key);
			if (previous !== undefined) {
				fail(`/${name} identifies both /${previous} and /${command.name}`);
			}
			owner.set(key, command.name);
		}
	}
});

Deno.test("the shared composer pipeline interprets slash commands before any controller sends", () => {
	const literal = prepareComposerSend(ROOM, draft(" /me waves "), QUIET);
	if (literal.kind !== "send" || literal.text !== " /me waves " || literal.original !== " /me waves ") {
		fail(`the shared composer changed literal spaced text: ${JSON.stringify(literal)}`);
	}
	const action = prepareComposerSend(ROOM, draft("/me waves"), QUIET);
	if (action.kind !== "send" || action.text !== "/me waves" || action.original !== "/me waves") {
		fail(`the shared composer did not prepare /me: ${JSON.stringify(action)}`);
	}
	const trailing = prepareComposerSend(ROOM, draft("ordinary words "), QUIET);
	if (trailing.kind !== "send" || trailing.text !== "ordinary words ") {
		fail(`the shared composer changed trailing whitespace: ${JSON.stringify(trailing)}`);
	}
	const shrug = prepareComposerSend(ROOM, draft("/shrug shared command"), QUIET);
	if (shrug.kind !== "send" || shrug.text !== "shared command ¯\\_(ツ)_/¯") {
		fail(`the shared composer did not prepare /shrug: ${JSON.stringify(shrug)}`);
	}
	let theme = "";
	const themed = prepareComposerSend(ROOM, draft("/theme dark"), { ...QUIET, setTheme: (next) => theme = next });
	if (themed.kind !== "handled" || theme !== "dark") fail("the shared composer did not run a tab command");
	const unknown = prepareComposerSend(ROOM, draft("/etc/hosts"), QUIET);
	if (unknown.kind !== "send" || unknown.text !== "/etc/hosts") fail("unknown slash text stopped being chat text");
});

/** Powers that answer without acting, for running every command to see what it
 * says. Each returns the empty answer held by a fresh window. */
const QUIET: CommandPowers = {
	say: () => {},
	joinRoom: () => NOT_ON_A_DIRECTORY,
	joinLink: () => null,
	leaveHere: () => {},
	directMessage: () => NOT_ON_A_DIRECTORY,
	you: () => "",
	setTheme: () => {},
	clearHere: () => {},
	ignore: () => {},
	unignore: () => false,
	ignored: () => [],
	editLast: () => false,
	withdrawLast: () => false,
	setSubject: () => true,
	setAway: () => true,
	invite: () => true,
	kick: () => true,
	steward: () => true,
	roomLink: () => true,
	standingHere: () => "",
	directories: () => [],
	granted: () => NO_GRANTS,
	showRoster: () => {},
	liveRooms: () => new Map(),
	roster: () => [],
	quitDirectory: () => NO_DIRECTORY_TO_GIVE_BACK,
	aboutConversation: () => {},
};

/** A plausible argument, so a command that wants one is not refused merely for
 * being handed nothing. What it names does not exist, which is fine: this asks
 * what a command *says*, not whether it found anything. */
function someArgument(command: Command): string {
	return command.name === "theme" ? "dark" : "alice";
}

Deno.test("a command that says it needs an argument refuses when given none", () => {
	const needy = known().filter((command) => command.needsArgument === true);
	if (needy.length === 0) fail("no command declares that it needs an argument");
	for (const command of needy) {
		const outcome = command.run("", TRAP, null);
		if (outcome.kind !== "refused") {
			fail(`/${command.name} says it needs an argument but did something without one: ${outcome.kind}`);
		}
	}
});

Deno.test("a command that needs nothing runs on nothing", () => {
	// The other half, and the half the Enter key rests on: these are the ones a
	// reader can type in full and send, so none of them may be sitting there
	// waiting for words that the interface will never prompt for.
	for (const command of known()) {
		if (command.needsArgument === true || command.grant !== undefined) continue;
		const outcome = command.run("", QUIET, null);
		if (outcome.kind === "refused" && /^Use \//.test(outcome.why)) {
			fail(`/${command.name} asks to be written differently but does not declare needsArgument: ${outcome.why}`);
		}
	}
});

Deno.test("a command names the grant it waits on, and says so when it is missing", () => {
	// A command that waits on a membership reference has to name which one,
	// because that name is what the room's answer is matched against. One that
	// says it is granted without naming a grant would never become held however
	// much the room handed over. `/edit` and `/delete` are granted per line, so
	// they name none.
	for (const command of known()) {
		if (command.kind !== "granted") continue;
		if (command.name === "edit" || command.name === "delete") {
			if (command.grant !== undefined) {
				fail(`/${command.name} is granted per line but names a membership grant`);
			}
			continue;
		}
		if (command.grant === undefined) {
			fail(
				`/${command.name} is granted but names no grant, so /help cannot list it from what the room handed over`,
			);
		}
	}
});

Deno.test("the reader's list is what this conversation has actually handed over", () => {
	const names = (grants: string[], here: CommandHere) => held(new Set(grants), here).map((command) => command.name);
	// Editing and withdrawing are granted commands that are granted:
	// the room answers each post with a reference to the line, so a reader holds
	// the authority for their own lines as a matter of course, with nothing
	// conversation-wide to wait for.
	for (const name of ["edit", "delete", "help", "me", "details"]) {
		if (!names([], "room").includes(name)) fail(`/${name} works but is not among the commands /help lists`);
	}
	if (names([], "room").includes("subject")) fail("/subject is listed before any room has offered one");
	if (!names(["subject"], "room").includes("subject")) {
		fail("a room that handed over its subject did not put /subject on the list");
	}
	if (names(["subject"], "room").includes("kick")) fail("holding one grant produced another");
	if (!names(["steward"], "room").includes("kick")) {
		fail("a room that handed over its moderator capability did not put /kick on the list");
	}
	if (!names([], "room").includes("moderator")) {
		fail("/moderator is missing before claim, when the opener needs the affordance");
	}
	if (names([], "direct").includes("moderator")) fail("a direct line listed /moderator");
	if (!names([], "room").includes("invite")) fail("/invite is missing in a room, where handing the room over works");
	if (names([], "direct").includes("invite")) fail("a direct line listed /invite");
	if (names([], "direct").includes("members")) fail("a direct line listed /members");
	if (names(["subject"], "direct").includes("subject")) fail("a direct line listed /subject");
	if (names([], "directory").includes("me")) fail("a directory listed /me, which travels in a message");
	if (names([], "directory").includes("invite")) fail("a directory listed /invite");
	if (names([], "directory").includes("members")) fail("a directory listed /members");
	if (names(["subject"], "directory").includes("subject")) fail("a directory listed /subject");
	if (names([], "directory").includes("edit")) fail("a directory listed /edit");
	if (!names([], "directory").includes("help")) fail("a directory omitted /help");
	if (!names([], "directory").includes("join")) fail("a directory omitted /join");
	if (!names([], "directory").includes("list")) fail("a directory omitted /list");
});

Deno.test("a room-only command refuses in a direct line", () => {
	const dm = { type: "dm" } as unknown as Conv;
	const directory = { type: "directory" } as unknown as Conv;
	for (const conv of [dm, directory]) {
		for (const command of known()) {
			if (command.place !== "room") continue;
			const outcome = command.run(someArgument(command), QUIET, conv);
			if (outcome.kind !== "refused") {
				fail(`/${command.name} is room-only but ran in a ${conv.type}: ${outcome.kind}`);
			}
		}
	}
	for (const command of known()) {
		if (command.place === "room") continue;
		const outcome = command.run(someArgument(command), QUIET, dm);
		if (outcome.kind === "refused" && /only a room/i.test(outcome.why)) {
			fail(`/${command.name} refuses as room-only but does not declare place: "room"`);
		}
	}
});

Deno.test("bare /away steps out when you are here, and comes back when you are not", () => {
	// `/away` needs no argument because typing it twice steps out and returns,
	// and it can only do the first half if it reads where the reader stands
	// rather than always meaning "back". The reader's own word for that is on
	// the conversation, whose lifetime exceeds the membership that carried it.
	const away = known().find((command) => command.name === "away") ?? fail("there is no /away command");
	const told: string[] = [];
	// Where the reader stands is the page's answer, not the command's: the room,
	// the directory, or them, whichever is speaking for this room.
	let standing = "";
	const watching: CommandPowers = {
		...QUIET,
		standingHere: () => standing,
		setAway: (why) => {
			told.push(why);
			standing = why;
			return true;
		},
	};
	// The only thing `/away` reads about where it was typed is that it is a room.
	const room = { type: "room" } as unknown as Conv;
	away.run("", watching, room);
	away.run("", watching, room);
	away.run("  lunch  ", watching, room);
	const expected = ["away", "", "lunch"];
	if (told.join("|") !== expected.join("|")) {
		fail(`/away said ${JSON.stringify(told)} where it should have said ${JSON.stringify(expected)}`);
	}
});

Deno.test("/unignore talks about ignoring, not drawing", () => {
	const said: string[] = [];
	const powers: CommandPowers = {
		...QUIET,
		unignore: () => true,
		say: (text) => {
			said.push(text);
		},
	};
	const command = known().find((entry) => entry.name === "unignore") ?? fail("there is no /unignore command");
	command.run("alice", powers, null);
	if (said[0] !== "No longer ignoring alice.") {
		fail(`/unignore said ${JSON.stringify(said[0])}`);
	}
	if (/draw/i.test(command.summary)) {
		fail(`/unignore still teaches drawing: ${JSON.stringify(command.summary)}`);
	}
	const ignore = known().find((entry) => entry.name === "ignore") ?? fail("there is no /ignore command");
	if (/draw/i.test(ignore.summary)) {
		fail(`/ignore still teaches drawing: ${JSON.stringify(ignore.summary)}`);
	}
});

Deno.test("handing a room or a line to yourself is refused before any line opens", () => {
	const room = { type: "room" } as unknown as Conv;
	let invited: string | undefined;
	let messaged: string | undefined;
	const powers: CommandPowers = {
		...QUIET,
		you: () => "Alice",
		invite: (who) => {
			invited = who;
			return true;
		},
		directMessage: (who) => {
			messaged = who;
			return null;
		},
	};
	const invite = known().find((command) => command.name === "invite") ?? fail("there is no /invite command");
	const msg = known().find((command) => command.name === "msg") ?? fail("there is no /msg command");
	const toSelf = invite.run("alice", powers, room);
	if (toSelf.kind !== "refused") fail(`/invite yourself ran: ${toSelf.kind}`);
	if (!/already hold/i.test(toSelf.why)) fail(`/invite yourself said ${JSON.stringify(toSelf.why)}`);
	if (invited !== undefined) fail("/invite yourself still handed the room over");
	const msgSelf = msg.run("@Alice", powers, room);
	if (msgSelf.kind !== "refused") fail(`/msg yourself ran: ${msgSelf.kind}`);
	if (messaged !== undefined) fail("/msg yourself still opened a line");
	const other = invite.run("bo", powers, room);
	if (other.kind !== "done" || invited !== "bo") fail("/invite somebody else did not hand the room over");
});

Deno.test("a room-wide word is refused as a person to message or invite", () => {
	// Completion keeps @here and its siblings off a person-target command's
	// list; typing one out by hand has to land on the same answer, or the two
	// paths teach different rules.
	const room = { type: "room" } as unknown as Conv;
	let invited: string | undefined;
	let messaged: string | undefined;
	const powers: CommandPowers = {
		...QUIET,
		invite: (who) => {
			invited = who;
			return true;
		},
		directMessage: (who) => {
			messaged = who;
			return null;
		},
	};
	const invite = known().find((command) => command.name === "invite") ?? fail("there is no /invite command");
	const msg = known().find((command) => command.name === "msg") ?? fail("there is no /msg command");
	for (const wide of ["here", "@here", "Everyone", "@room"]) {
		const handed = invite.run(wide, powers, room);
		if (handed.kind !== "refused") fail(`/invite ${wide} ran: ${handed.kind}`);
		const lined = msg.run(wide, powers, room);
		if (lined.kind !== "refused") fail(`/msg ${wide} ran: ${lined.kind}`);
	}
	if (invited !== undefined) fail("a room-wide word was handed the room");
	if (messaged !== undefined) fail("a room-wide word was opened as a line");
});

Deno.test("/details opens the conversation card rather than writing into the log", () => {
	let opened = false;
	const said: string[] = [];
	const powers: CommandPowers = {
		...QUIET,
		aboutConversation: () => {
			opened = true;
		},
		say: (text) => {
			said.push(text);
		},
	};
	const details = known().find((command) => command.name === "details") ?? fail("there is no /details command");
	const none = details.run("", powers, null);
	if (none.kind !== "refused") fail("/details with nothing open did not refuse");
	if (opened) fail("/details opened a card with nothing on screen");
	const room = { type: "room" } as unknown as Conv;
	const outcome = details.run("", powers, room);
	if (outcome.kind !== "done") fail(`/details in a room did not open the card: ${outcome.kind}`);
	if (!opened) fail("/details in a room never asked for the card");
	if (said.length > 0) fail("/details wrote into the log instead of opening the card");
});

Deno.test("/join with a room link takes it up rather than treating it as a name", () => {
	const took: { link: string; label: string }[] = [];
	let named: string | undefined;
	const powers: CommandPowers = {
		...QUIET,
		joinLink: (link, label) => {
			took.push({ link, label });
			return null;
		},
		joinRoom: (name) => {
			named = name;
			return null;
		},
	};
	const join = known().find((command) => command.name === "join") ?? fail("there is no /join command");
	const link = "ocapn://peer.tcp/s/swissnum";
	const labeled = join.run(`${link} plans`, powers, null);
	if (labeled.kind !== "done") fail(`/join a link did not take it up: ${labeled.kind}`);
	if (took[0]?.link !== link || took[0].label !== "plans") {
		fail(`/join a named link took ${JSON.stringify(took[0])}`);
	}
	if (named !== undefined) fail("/join a link entered a room by name");
	const bare = join.run(link, powers, null);
	if (bare.kind !== "done") fail(`/join a link with no label did not take it up: ${bare.kind}`);
	if (took[1]?.link !== link || took[1].label !== "") {
		fail(`/join a link with no label took ${JSON.stringify(took[1])}`);
	}
	const whole = join.run(`Anybody who holds this link can be in plans:\n  ${link}`, powers, null);
	if (whole.kind !== "done" || took[2]?.link !== link || took[2].label !== "") {
		fail(`/join of /link's whole answer took ${JSON.stringify(took[2])}`);
	}
});

Deno.test("/link is this room, or a listed name it is given", () => {
	const named: string[] = [];
	let thisRoom = 0;
	const powers: CommandPowers = {
		...QUIET,
		roomLink: (name) => {
			if (name === undefined || name === "") {
				thisRoom++;
				return true;
			}
			named.push(name);
			return true;
		},
	};
	const link = known().find((command) => command.name === "link") ?? fail("there is no /link command");
	const room = { type: "room" } as unknown as Conv;
	const bare = link.run("", powers, room);
	if (bare.kind !== "done") fail(`/link with no argument did not mint this room: ${bare.kind}`);
	if (thisRoom !== 1 || named.length !== 0) {
		fail(`/link with no argument did not mean this room: thisRoom=${thisRoom} named=${JSON.stringify(named)}`);
	}
	const hashed = link.run("#lobby", powers, room);
	if (hashed.kind !== "done" || named[0] !== "lobby") {
		fail(`/link #lobby did not name the listed room: ${JSON.stringify(named[0])}`);
	}
	const word = link.run("lobby", powers, room);
	if (word.kind !== "done" || named[1] !== "lobby") {
		fail(`/link lobby did not name the listed room: ${JSON.stringify(named[1])}`);
	}
	if (thisRoom !== 1) fail("a named /link also minted this room");
});

Deno.test("a directory is a command place, not a direct line", () => {
	if (hereOf({ type: "directory" } as Conv) !== "directory") {
		fail("a directory conversation listed commands as if it were a direct line");
	}
	if (hereOf({ type: "room", lineBytes: 8192 } as Conv) !== "room") fail("a room was not a room");
	if (hereOf({ type: "dm" } as Conv) !== "direct") fail("a direct line was not a direct line");
	if (hereOf(null) !== "direct") fail("no conversation was not treated as a direct line");
});

Deno.test("a directory composer runs commands and refuses chat", () => {
	const directory = { type: "directory" } as Conv;
	let joined = "";
	const joining: CommandPowers = {
		...QUIET,
		joinRoom: (name) => {
			joined = name;
			return null;
		},
	};
	const join = prepareComposerSend(directory, draft("/join lobby"), joining);
	if (join.kind !== "handled" || joined !== "lobby") {
		fail(`a directory /join did not enter the room: ${JSON.stringify(join)} joined=${joined}`);
	}
	const leave = prepareComposerSend(directory, draft("/leave"), QUIET);
	if (leave.kind !== "handled" || leave.retires !== "conversation") {
		fail(`a directory /leave did not put the view away: ${JSON.stringify(leave)}`);
	}
	const chat = prepareComposerSend(directory, draft("hello"), QUIET);
	if (chat.kind !== "refused" || chat.why !== DIRECTORY_NO_CHAT) {
		fail(`plain text on a directory did not refuse: ${JSON.stringify(chat)}`);
	}
	const action = prepareComposerSend(directory, draft("/me waves"), QUIET);
	if (action.kind !== "refused" || action.why !== DIRECTORY_NO_CHAT) {
		fail(`/me on a directory did not refuse: ${JSON.stringify(action)}`);
	}
	const unknown = prepareComposerSend(directory, draft("/etc/hosts"), QUIET);
	if (unknown.kind !== "refused" || unknown.why !== DIRECTORY_NO_CHAT) {
		fail(`unknown slash text on a directory was treated as chat: ${JSON.stringify(unknown)}`);
	}
});

Deno.test("a missing handle is a catalog refusal, not a successful command", () => {
	const join = known().find((command) => command.name === "join") ?? fail("there is no /join command");
	const entered = join.run("lobby", QUIET, null);
	if (entered.kind !== "refused") fail(`/join without a directory ran: ${entered.kind}`);
	if (entered.why !== NOT_ON_A_DIRECTORY) {
		fail(`/join without a directory said ${JSON.stringify(entered.why)}`);
	}
	const msg = known().find((command) => command.name === "msg") ?? fail("there is no /msg command");
	const lined = msg.run("alice", QUIET, null);
	if (lined.kind !== "refused") fail(`/msg without a directory ran: ${lined.kind}`);
	if (lined.why !== NOT_ON_A_DIRECTORY) {
		fail(`/msg without a directory said ${JSON.stringify(lined.why)}`);
	}
	const quit = known().find((command) => command.name === "quit") ?? fail("there is no /quit command");
	const given = quit.run("", QUIET, null);
	if (given.kind !== "refused") fail(`/quit without a directory ran: ${given.kind}`);
	if (given.why !== NO_DIRECTORY_TO_GIVE_BACK) {
		fail(`/quit without a directory said ${JSON.stringify(given.why)}`);
	}
	const holding: CommandPowers = { ...QUIET, quitDirectory: () => null };
	const retired = quit.run("", holding, null);
	if (retired.kind !== "done" || retired.retires !== "directory") {
		fail(`/quit with a directory did not retire it: ${JSON.stringify(retired)}`);
	}
});
