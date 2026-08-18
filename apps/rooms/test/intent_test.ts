// What the reader meant, and what the join card shows because of it.
//
// The whole model is a precedence over evidence, so this drives the order
// itself rather than any one screen: which tier wins, what an act naming an
// empty value beats, and when the reader's own typing stops applying. Each of
// these was a way the card got an answer wrong before there was a model to get
// it right, and the first of them is the one anybody could see: following a
// link to a room in this page's directory put up a gate offering to join it
// somewhere else, because the locator field still held the last address that
// had been typed and nothing in the link contradicted it.
//
// Validated by breaking what it covers, since a suite that has only ever run
// green has shown nothing. Weighing what this browser remembers above what the
// act said — the original defect, exactly — fails five of these; letting an
// override outlive the act it was made under fails the sixth. What is not
// covered here is which act each surface files, because that is a question
// about the surfaces: `web_routes_test.ts` drives it through a real page.
//
// Run: `deno test --allow-read apps/rooms/test/intent_test.ts`.

/// <reference lib="dom" />

const intent = await import("../web/ui/intent.ts");
const joining = await import("../web/ui/joining.ts");
const types = await import("../web/ui/types.ts");
const { dirId } = types;
const { implied, named, settle } = intent;

const HOME = dirId("ocapn://home.iroh");
const AWAY = "ocapn://elsewhere.iroh";
const NOTHING: import("../web/ui/intent.ts").Remembered = { room: "", locator: "", nick: "" };

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

/** The card, answered. `edits` defaults to the act's own, which is the state
 * every act starts in. */
function card(
	act: Omit<import("../web/ui/intent.ts").Act, "seq"> & { seq?: number },
	memory: Partial<import("../web/ui/intent.ts").Remembered> = {},
	edits: Partial<import("../web/ui/intent.ts").Edits> = {},
) {
	const seq = act.seq ?? 1;
	return joining.joinAnswers(
		{ ...act, seq },
		{ seq, ...edits },
		{ ...NOTHING, ...memory },
		HOME,
	);
}

Deno.test("evidence is weighed in one order, strongest first", () => {
	assert(settle("typed", named("link"), "last", "").from === "edited", "typing lost to the link that asked");
	assert(settle(undefined, named("link"), "last", "").from === "named", "a named value lost to a habit");
	assert(settle(undefined, implied("here"), "last", "").from === "implied", "an implied value lost to a habit");
	assert(settle(undefined, undefined, "last", "").from === "recent", "what was used last was not offered");
	assert(settle(undefined, undefined, undefined, "fallback").from === "default", "nothing fell back to nothing");
	assert(settle(undefined, undefined, undefined, "fallback").value === "fallback", "the fallback was not the value");
});

Deno.test("an act naming an empty value still outranks what was used last", () => {
	// The one that mattered. An act that says "here" says it by naming the
	// empty field, and an empty field carrying an answer has to beat a
	// remembered address, or every link to a room on this page offers to join
	// it on the last directory anybody visited.
	const answers = card({ source: "link", room: named("arrivals"), locator: implied("") }, { locator: AWAY });
	assert(answers.locator.value === "", "a link to a room here offered another directory");
	assert(answers.locator.from === "implied", "the link's own directory was not the reason for the field");
	assert(answers.room.value === "arrivals", "the link did not name its room");
});

Deno.test("a link that gates a room here reads as this directory, however it says so", () => {
	// The route hands over the directory's dialable address rather than the
	// empty field, because it is naming a place rather than describing a form.
	// Reading every tier through "this page's own directory is the empty field"
	// is what makes the two the same answer.
	const byAddress = card({ source: "link", room: named("arrivals"), locator: implied(HOME as string) }, {
		locator: AWAY,
	});
	assert(byAddress.locator.value === "", "the page's own address was offered as a foreign directory");
	assert(byAddress.locator.from === "implied", "naming home by address lost the link's own evidence");
});

Deno.test("a link that names a directory is answered there, whatever was used last", () => {
	const answers = card({ source: "link", room: named("arrivals"), locator: named(AWAY) }, {
		locator: "ocapn://third.iroh",
	});
	assert(answers.locator.value === AWAY, "the link's directory lost to a remembered one");
	assert(answers.locator.from === "named", "a directory the link named did not read as named");
});

Deno.test("what an act says nothing about falls through to what was used last", () => {
	// A link names a room and says nothing about who the reader is, so their
	// name is still offered. This is the half that has to keep working: the
	// fix for a field answered too eagerly must not empty the fields that were
	// right all along.
	const answers = card({ source: "link", room: named("arrivals"), locator: implied("") }, {
		nick: "alice",
		room: "lobby",
	});
	assert(answers.nick.value === "alice", "a returning reader lost their name to a room link");
	assert(answers.nick.from === "recent", "an offered name did not say it was an offer");
	assert(answers.room.value === "arrivals", "the link's room lost to a remembered one");
});

Deno.test("the application's own defaults are not offered back as choices", () => {
	// Nobody who let the card default to `general` chose `general`, so it is
	// not held against them next time; the field stands blank and the
	// placeholder says what pressing Join would do.
	const answers = card({ source: "restore" }, { room: "general", nick: "guest" });
	assert(answers.room.value === "" && answers.room.from === "default", "a default room came back as a preference");
	assert(answers.nick.value === "" && answers.nick.from === "default", "a default name came back as a preference");
});

Deno.test("a lock is never offered from a past visit", () => {
	// A private room is minted for good on submit, so a lock remembered from
	// last week would mint one nobody asked for.
	const answers = card({ source: "restore" }, { room: "lobby" });
	assert(answers.secret.value === false, "the card opened locked with nobody having pressed it");
	assert(answers.secret.from === "default", "a lock claimed evidence behind it");
});

Deno.test("what the reader typed applies to the act they typed it under, and no other", () => {
	const gate = { source: "link" as const, room: named("arrivals"), locator: implied(""), seq: 4 };
	const mine = card(gate, {}, { seq: 4, room: "somewhere-else" });
	assert(mine.room.value === "somewhere-else", "an override of the link's room did not take");
	assert(mine.room.from === "edited", "typing did not read as the reader's own");
	// The reader goes somewhere else, which asks a different question. Nothing
	// clears the override; it simply stops being an answer to what is now
	// being asked.
	const later = card({ ...gate, room: named("departures"), seq: 5 }, {}, { seq: 4, room: "somewhere-else" });
	assert(later.room.value === "departures", "an answer to an earlier question followed the reader");
	assert(later.room.from === "named", "the new link's room did not read as named");
});

Deno.test("an override made under an older act does not ride back in on a new edit", () => {
	// Filing an act does not clear what the reader typed under the last one;
	// the act it belongs to is what makes it apply. So anything that *writes*
	// an override has to build on the ones that still apply rather than on
	// whatever is stored, or a locator typed two rooms ago comes back the
	// moment the reader touches any other field.
	const stale = { seq: 4, locator: "ocapn://somewhere-old.iroh" };
	const now = { source: "link" as const, room: named("arrivals"), locator: implied(""), seq: 7 };
	const kept = intent.current(stale, now);
	assert(kept.locator === undefined, "an override from an earlier act was carried into this one");
	assert(kept.seq === 7, "the surviving overrides were not filed against the act on the table");
	// And the ones made under this act do survive, which is the half that makes
	// the guard a rule rather than a reset.
	const mine = { seq: 7, locator: "ocapn://chosen.iroh" };
	assert(intent.current(mine, now).locator === "ocapn://chosen.iroh", "the reader's own answer was dropped");
});

Deno.test("the card says what it is for once, and only an address gets to say it", () => {
	const gate = card({ source: "link", room: named("arrivals"), locator: implied("") });
	assert(
		joining.joinLead(gate, "this page's directory").includes("#arrivals in this page's directory"),
		"a link's gate did not say what it was gating",
	);
	// A directory named with no room is still an address worth stating, and it
	// asks for the one thing it is missing.
	const toADirectory = card({ source: "link", locator: named(AWAY) });
	assert(
		joining.joinLead(toADirectory, "elsewhere").includes("Name a room to enter there"),
		"a link naming only a directory did not ask for a room",
	);
	// A press put the reader here a moment ago and they can see what they
	// pressed, so the card keeps its ordinary words.
	const pressed = card({ source: "press", room: named("arrivals"), locator: implied("") });
	assert(
		!joining.joinLead(pressed, "this page's directory").includes("This address"),
		"a room the reader just typed was described as an address they followed",
	);
	// And what this browser merely remembers is an offer, never a destination.
	const cold = card({ source: "restore" }, { room: "lobby", locator: AWAY });
	assert(
		!joining.joinLead(cold, "elsewhere").includes("This address"),
		"what was used last was described as somewhere the reader was going",
	);
});
