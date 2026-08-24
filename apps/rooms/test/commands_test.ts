// What the command registry declares about itself, held against what its
// commands actually do.
//
// Two of a command's fields are read by the interface rather than by the
// command: `needsArgument` decides whether the completion list keeps the Enter
// key, `grant` decides whether a conversation that can run it lists it, and
// `place` decides whether this conversation can run it at all.
// Both are written by hand next to a `run` that could disagree with them, and
// a disagreement is silent — a command wrongly marked as needing an argument
// simply stops running on Enter, which looks like a dead key rather than like
// a wrong flag. So each is asked of every command here.

import { type Command, type CommandPowers, held, known } from "../web/ui/commands.ts";
import type { Conv } from "../web/ui/types.ts";

function fail(message: string): never {
	throw new Error(message);
}

/** Powers that refuse to be touched, so a command that acts when it claimed to
 * need an argument fails loudly here rather than quietly acting. */
const TRAP: CommandPowers = new Proxy({}, {
	get(_target, verb) {
		return () => fail(`a command reached for ${String(verb)} when it should have refused`);
	},
}) as CommandPowers;

const NO_GRANTS: ReadonlySet<string> = new Set();

/** Powers that answer without acting, for running every command to see what it
 * says. Each returns the empty answer, which is what a fresh window holds. */
const QUIET: CommandPowers = {
	ircLogin: () => {},
	say: () => {},
	joinRoom: () => {},
	joinLink: () => {},
	leaveHere: () => {},
	directMessage: () => {},
	you: () => "",
	setTheme: () => {},
	clearHere: () => {},
	ignore: () => {},
	unignore: () => false,
	ignored: () => [],
	editLast: () => false,
	withdrawLast: () => false,
	setTopic: () => true,
	setAway: () => true,
	invite: () => true,
	roomLink: () => true,
	standingHere: () => "",
	directories: () => [],
	granted: () => NO_GRANTS,
	showRoster: () => {},
	liveRooms: () => new Map(),
	roster: () => [],
	quitDirectory: () => {},
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
	// A command that waits on a reference has to name which one, because that
	// name is what the room's answer is matched against. One that says it is
	// waiting without naming a grant would never become held however much the
	// room handed over.
	for (const command of known()) {
		const outcome = command.run(someArgument(command), QUIET, null);
		const waiting = outcome.kind === "refused" && outcome.why.includes("does not offer it yet");
		if (waiting && command.grant === undefined) {
			fail(`/${command.name} says it waits on the room but names no grant, so nothing can ever satisfy it`);
		}
	}
});

Deno.test("the reader's list is what this conversation has actually handed over", () => {
	const names = (grants: string[], here: "room" | "direct") =>
		held(new Set(grants), here).map((command) => command.name);
	// Editing and withdrawing are granted commands that are genuinely granted:
	// the room answers each post with a reference to the line, so a reader holds
	// the authority for their own lines as a matter of course, with nothing
	// conversation-wide to wait for.
	for (const name of ["edit", "delete", "help", "me", "details"]) {
		if (!names([], "room").includes(name)) fail(`/${name} works but is not among the commands /help lists`);
	}
	if (names([], "room").includes("topic")) fail("/topic is listed before any room has offered one");
	if (!names(["topic"], "room").includes("topic")) {
		fail("a room that handed over its topic did not put /topic on the list");
	}
	if (names(["topic"], "room").includes("kick")) fail("holding one grant produced another");
	if (!names([], "room").includes("invite")) fail("/invite is missing in a room, where handing the room over works");
	if (names([], "direct").includes("invite")) fail("a direct line listed /invite");
	if (names([], "direct").includes("members")) fail("a direct line listed /members");
	if (names(["topic"], "direct").includes("topic")) fail("a direct line listed /topic");
});

Deno.test("a room-only command refuses in a direct line", () => {
	const dm = { type: "dm" } as unknown as Conv;
	for (const command of known()) {
		if (command.place !== "room") continue;
		const outcome = command.run(someArgument(command), QUIET, dm);
		if (outcome.kind !== "refused") {
			fail(`/${command.name} is room-only but ran in a direct line: ${outcome.kind}`);
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
	// the conversation, which is what outlives the membership that carried it.
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
		},
		joinRoom: (name) => {
			named = name;
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
