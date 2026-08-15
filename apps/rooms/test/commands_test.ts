// What the command registry declares about itself, held against what its
// commands actually do.
//
// Two of a command's fields are read by the interface rather than by the
// command: `needsArgument` decides whether the completion list keeps the Enter
// key, and `grant` decides whether a conversation lists the command at all.
// Both are written by hand next to a `run` that could disagree with them, and
// a disagreement is silent — a command wrongly marked as needing an argument
// simply stops running on Enter, which looks like a dead key rather than like
// a wrong flag. So each is asked of every command here.

import { type Command, type CommandPowers, held, known } from "../web/ui/commands.ts";

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
	say: () => {},
	joinRoom: () => {},
	leaveHere: () => {},
	directMessage: () => {},
	setTheme: () => {},
	clearHere: () => {},
	ignore: () => {},
	unignore: () => false,
	ignored: () => [],
	editLast: () => false,
	withdrawLast: () => false,
	setTopic: () => true,
	setAway: () => true,
	granted: () => NO_GRANTS,
	showRoster: () => {},
	liveRooms: () => new Map(),
	roster: () => [],
	quitDirectory: () => {},
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
	const names = (grants: string[]) => held(new Set(grants)).map((command) => command.name);
	// Editing and withdrawing are granted commands that are genuinely granted:
	// the room answers each post with a reference to the line, so a reader holds
	// the authority for their own lines as a matter of course, with nothing
	// conversation-wide to wait for.
	for (const name of ["edit", "delete", "help", "me"]) {
		if (!names([]).includes(name)) fail(`/${name} works but is not among the commands /help lists`);
	}
	// And what nothing has handed over is absent until it is handed over. This is
	// the whole shape in two lines: the same registry, two members, two lists.
	if (names([]).includes("topic")) fail("/topic is listed before any room has offered one");
	if (!names(["topic"]).includes("topic")) fail("a room that handed over its topic did not put /topic on the list");
	if (names(["topic"]).includes("kick")) fail("holding one grant produced another");
});
