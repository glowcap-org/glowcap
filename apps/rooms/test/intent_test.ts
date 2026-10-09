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
// about the surfaces: `web/routes_test.ts` drives it through a real page.
//
// Run: `deno test --allow-read apps/rooms/test/intent_test.ts`.

/// <reference lib="dom" />

const { initializeApplication } = await import("./support/application.ts");
await initializeApplication();
const intent = await import("../web/ui/intent.ts");
const joining = await import("../web/ui/joining.ts");
const joinNick = await import("../web/ui/join_nick.ts");
// Asserted against the catalog rather than against a string spelled here: what
// these prove is which lead the card reaches for, and a needle copied out of
// the copy turns every wording change into a red test that has caught nothing.
const text = await import("../lib/text/join.ts");
const types = await import("../web/ui/types.ts");
const { dirId } = types;
const { implied, named, settle } = intent;

const HOME = dirId("ocapn://home.iroh");
const AWAY = "ocapn://elsewhere.iroh";
const HOME_CONTEXT: import("../web/ui/joining.ts").DirectoryDestinationContext = {
	home: HOME,
	defaultDirectory: { id: HOME, locator: HOME },
};
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
		HOME_CONTEXT,
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

Deno.test("effective nicknames are offers, not prefilled exact intent", () => {
	// A link names a room and says nothing about who the reader will be. The
	// last successful nickname is an outcome, not a new answer: the connected
	// directory may offer it as a placeholder, while the value remains empty.
	const answers = card({ source: "link", room: named("arrivals"), locator: implied("") }, {
		nick: "alice",
		room: "lobby",
	});
	assert(answers.nick.value === "", "a successful nickname outcome returned as exact intent");
	assert(answers.nick.from === "default", "an empty nickname field claimed the outcome was its answer");
	assert(answers.room.value === "arrivals", "the link's room lost to a remembered one");
});

Deno.test("the application's own defaults are not offered back as choices", () => {
	// Nobody who let the card default to `general` chose `general`, so it is
	// not held against them next time; the field stands blank and the
	// placeholder says what pressing Join would do.
	const answers = card({ source: "restore" }, { room: "general", nick: "guest" });
	assert(answers.room.value === "" && answers.room.from === "default", "a default room came back as a preference");
	assert(answers.nick.value === "" && answers.nick.from === "default", "a default name came back as a preference");
	assert(intent.keepable(" alice ", "guest") === " alice ", "a remembered name was silently trimmed");
});

Deno.test("paired room fields follow the draft destination across multiple directories", () => {
	const away = dirId(AWAY);
	const directory = (id: typeof HOME, name: string) =>
		({
			id,
			liveRooms: new Map([[name, { name }]]),
		}) as unknown as import("../web/ui/types.ts").DirView;
	const dirs = new Map([[HOME, directory(HOME, "deadnet/#nowhere")], [away, directory(away, "elsewhere")]]);
	const resolve = (locator: string) => locator === AWAY ? away : null;
	assert(
		joining.joinRoomOffers("", "deadnet", dirs, HOME_CONTEXT, resolve)[0] === "deadnet/#nowhere",
		"the linked rail offered the previous foreign directory instead of the empty locator's destination",
	);
	assert(
		joining.joinRoomOffers(AWAY, "", dirs, HOME_CONTEXT, resolve)[0] === "elsewhere",
		"the explicit foreign destination retained home offers",
	);
	assert(
		joining.joinRoomOffers("ocapn://unknown.iroh", "", dirs, HOME_CONTEXT, resolve).length === 0,
		"an unknown explicit destination claimed home offers",
	);
	const attached = { home: null, defaultDirectory: { id: away, locator: AWAY } };
	assert(
		joining.joinRoomOffers("", "", dirs, attached, resolve)[0] === "elsewhere",
		"an attached workspace ignored its default directory",
	);
});

Deno.test("an empty nickname means the granted name on the aimed connected directory", () => {
	const away = dirId(AWAY);
	const directory = (
		id: import("../web/ui/types.ts").DirId,
		nick: string,
		session: import("../web/ui/types.ts").SessionPhase,
	) => ({ id, nick, session }) as import("../web/ui/types.ts").DirView;
	const dirs = new Map([
		[HOME, directory(HOME, "home-name", "connected")],
		[away, directory(away, "away-name", "connected")],
	]);
	const resolve = (locator: string) => locator === AWAY ? away : null;
	assert(
		joining.suggestedJoinNick("", dirs, HOME_CONTEXT, resolve) === "home-name",
		"an empty home join did not reuse the name home actually granted",
	);
	const attached = { home: null, defaultDirectory: { id: away, locator: AWAY } };
	assert(
		joining.suggestedJoinNick("", dirs, attached, resolve) === "away-name",
		"an attached session's empty locator ignored its connected default directory",
	);
	assert(
		joining.suggestedJoinNick(AWAY, dirs, HOME_CONTEXT, resolve) === "away-name",
		"a join aimed elsewhere reused the wrong directory's name",
	);
	const offered = joining.suggestedJoinNick(AWAY, dirs, HOME_CONTEXT, resolve);
	const empty = joinNick.answerJoinNick("", offered, null, null, null, new Map(), new Map());
	assert(empty.request === empty.placeholder, "an empty submission did not request its placeholder");
	const chosen = joinNick.answerJoinNick("chosen-name", offered, null, null, null, new Map(), new Map());
	assert(chosen.request === "chosen-name", "an explicit nickname lost to the directory's suggestion");
	dirs.set(away, directory(away, "stale-name", "reconnecting"));
	assert(
		joining.suggestedJoinNick(AWAY, dirs, HOME_CONTEXT, resolve) === joining.JOIN_DEFAULT_NICK,
		"a disconnected directory's stale grant was offered as current",
	);
	assert(
		joining.suggestedJoinNick("ocapn://new.iroh", dirs, HOME_CONTEXT, () => null) === joining.JOIN_DEFAULT_NICK,
		"an unreached directory lost the guest fallback",
	);
});

Deno.test("room nickname availability uses only live registration or exact roster evidence", () => {
	const room = {
		type: "room",
		key: "home/general",
		id: "general",
		dir: HOME,
		membership: "joined",
		held: false,
	} as import("../web/ui/types.ts").RoomConv;
	const conversations = new Map([[room.key, room]]);
	const standing: import("../web/ui/types.ts").Standing = { online: true, away: "" };
	const members = new Map([[
		room.key,
		new Map([
			["home-name", standing],
			["Alice", standing],
			["alice-2", standing],
		]),
	]]);
	const target = { directory: HOME, link: null, room: "GENERAL" };
	assert(
		joinNick.joinNickAvailability("alice", target, "home-name", null, conversations, members).kind === "taken",
		"a folded roster collision was not known to be taken",
	);
	const taken = joinNick.joinNickAvailability("Alice", target, "home-name", null, conversations, members);
	assert(
		taken.kind === "taken" && taken.source === "room" && taken.suggestion === "Alice-3",
		"the room collision did not skip an occupied suffix",
	);
	assert(
		joinNick.joinNickAvailability("home-name", target, "home-name", null, conversations, members).kind ===
			"available",
		"the reader's own granted room seat was called a collision",
	);
	assert(
		joinNick.joinNickAvailability("new-name", target, "home-name", null, conversations, members).kind ===
			"available",
		"an absent name in a received roster was not known to be available",
	);
	assert(
		joinNick.joinNickAvailability(
			"alice",
			{ ...target, room: "elsewhere" },
			"home-name",
			null,
			conversations,
			members,
		)
			.kind === "unknown",
		"one room's roster claimed knowledge about another room",
	);
	assert(
		joinNick.joinNickAvailability("alice", target, "home-name", null, conversations, new Map()).kind === "unknown",
		"a missing roster was mistaken for an empty authoritative one",
	);
	const directoryTaken = joinNick.joinNickAvailability(
		"alice",
		{ ...target, room: "a room this tab has never joined" },
		"home-name",
		["Alice", "alice-2"],
		new Map(),
		new Map(),
	);
	assert(
		directoryTaken.kind === "taken" && directoryTaken.source === "directory" &&
			directoryTaken.suggestion === "alice-3",
		"a live directory registration did not reserve its name or skip its occupied suffix",
	);
});

Deno.test("an occupied default nickname advances the placeholder and empty request together", () => {
	const target = { directory: HOME, link: null, room: "general" };
	const answer = joinNick.answerJoinNick(
		"",
		joining.JOIN_DEFAULT_NICK,
		target,
		null,
		["guest", "guest-2"],
		new Map(),
		new Map(),
	);
	assert(answer.placeholder === "guest-3", "the empty field did not offer the first available guest name");
	assert(answer.request === "guest-3", "the empty field submitted a different name than it displayed");
	assert(answer.availability.kind === "unknown", "an unobserved room was called available");
	const afterRefusal = joinNick.answerJoinNick(
		"",
		joining.JOIN_DEFAULT_NICK,
		target,
		null,
		null,
		new Map(),
		new Map(),
		{ suggestion: "guest-2" },
	);
	assert(afterRefusal.placeholder === "guest-2", "a refused default did not advance the empty placeholder");
	assert(afterRefusal.request === "guest-2", "the next empty submission ignored the refused default's suggestion");
	const explicit = joinNick.answerJoinNick(
		"guest",
		joining.JOIN_DEFAULT_NICK,
		target,
		null,
		null,
		new Map(),
		new Map(),
		{ suggestion: "guest-2" },
	);
	assert(explicit.request === "guest", "a refusal silently replaced an explicitly typed nickname");
});

Deno.test("a lock is never offered from a past visit", () => {
	// A private room is minted for good on submit, so a lock remembered from
	// last week would mint one nobody asked for.
	const answers = card({ source: "restore" }, { room: "lobby" });
	assert(answers.roomPreset.value === "open", "the card opened restricted with nobody having pressed it");
	assert(answers.roomPreset.from === "default", "room access claimed evidence behind it");
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

Deno.test("a room link pasted into the join card is a link, not a directory", () => {
	const link = "ocapn://peer.tcp/s/swissnum";
	assert(joining.looksLikeRoomLink(link), "a sturdyref was not read as a room link");
	assert(!joining.looksLikeRoomLink("ocapn://peer.tcp"), "a directory locator was read as a room link");
	assert(!joining.looksLikeRoomLink("lobby"), "a room name was read as a room link");

	const fromLocator = joining.typedRoomLink(link, "plans");
	assert(
		fromLocator !== null && fromLocator.link === link && fromLocator.label === "plans",
		"a link in the locator field was not taken as one",
	);
	const exactLabel = joining.typedRoomLink(link, " plans ");
	assert(exactLabel?.label === " plans ", "a room-link label was silently trimmed");
	const unlabeled = joining.typedRoomLink(link, "");
	assert(unlabeled !== null && unlabeled.label === "", "a link with no name invented a label");
	const fromRoom = joining.typedRoomLink("", link);
	assert(
		fromRoom !== null && fromRoom.link === link && fromRoom.label === "",
		"a link in the room field was not taken as one",
	);
	assert(
		joining.typedRoomLink("ocapn://peer.tcp", "lobby") === null,
		"a directory join was classified as a room link",
	);

	const pasted = joining.joinLinkIn(
		"Anybody who holds this link can be in plans:\n  " + link,
	);
	assert(
		pasted !== null && pasted.link === link && pasted.label === "",
		"the whole /link answer was not taken as that link",
	);
	const namedJoin = joining.joinLinkIn(link + " plans");
	assert(namedJoin !== null && namedJoin.label === "plans", "/join a link with a name did not keep the name");

	const byName = joining.askedJoin("lobby");
	assert(byName !== null && byName.kind === "name" && byName.name === "lobby", "/join a name was not a name");
	const hashed = joining.askedJoin("#lobby");
	assert(hashed !== null && hashed.kind === "name" && hashed.name === "lobby", "/join #lobby kept the hash");
	const byLink = joining.askedJoin(link);
	assert(byLink !== null && byLink.kind === "link" && byLink.link === link, "/join a sturdyref was not a link");
	assert(joining.askedJoin("") === null, "an empty /join was treated as a destination");
	assert(
		joining.joinedForLink(
			[{ key: "a", held: true, id: "plans", link }],
			new Set(["a"]),
			link,
			null,
		) === "a",
		"a locator this tab already holds was not that conversation",
	);
	assert(
		joining.joinedForLink(
			[{ key: "g", held: false, id: "general" }],
			new Set(["g"]),
			"ocapn://peer.tcp/s/other",
			"general",
		) === "g",
		"a public link to a listed room this tab is in was not that room",
	);
	assert(
		joining.joinedForLink(
			[{ key: "p", held: true, id: "general" }],
			new Set(["p"]),
			"ocapn://peer.tcp/s/other",
			null,
		) === null,
		"/join of a private link treated a same-label conversation as the destination",
	);
	assert(joining.listedOccupancy(true, "general"), "a listed arrival with a name sits in that room");
	assert(!joining.listedOccupancy(false, "general"), "an unlisted arrival is not a directory name");
	assert(!joining.listedOccupancy(undefined, "general"), "an older room's silence is not a listed room");
	assert(!joining.listedOccupancy(true, ""), "a listed arrival with no name has nothing to sit in");

	const answers = card({ source: "press" }, {}, { seq: 1, locator: link, room: "plans" });
	const lead = joining.joinLead(answers, "this page's directory");
	assert(
		lead.includes(text.joinLeadLink),
		"pasting a room entry link did not change what the card said it was for",
	);
	assert(!lead.includes(text.joinLeadPlain), "a room link was offered the lead for a room the reader might create");
});

Deno.test("a private room cannot impersonate a live room label in the join UI", () => {
	assert(
		joining.privateRoomNameRefusal("Network-Channel", ["network-channel"]) !== null,
		"a case-variant private room could reuse a live publication label",
	);
	assert(
		joining.privateRoomNameRefusal("quiet-room", ["network-channel"]) === null,
		"an unrelated private room name was refused",
	);
});

Deno.test("the card says what it is for once, and only an address gets to say it", () => {
	const gate = card({ source: "link", room: named("arrivals"), locator: implied("") });
	assert(
		joining.joinLead(gate, "this page's directory").includes(
			text.joinLeadNamedRoom("arrivals", "this page's directory"),
		),
		"a link's gate did not say what it was gating",
	);
	// A directory named with no room is still an address worth stating, and it
	// asks for the one thing it is missing.
	const toADirectory = card({ source: "link", locator: named(AWAY) });
	assert(
		joining.joinLead(toADirectory, "elsewhere").includes(text.joinLeadNamedDirectory("elsewhere")),
		"a link naming only a directory did not ask for a room",
	);
	// A press that already named the room is a gate on that room: say so, and
	// ask for the name, without talking like an address they followed.
	const pressed = card({ source: "press", room: named("arrivals"), locator: implied("") });
	assert(
		!joining.joinLead(pressed, "this page's directory").includes(
			text.joinLeadNamedRoom("arrivals", "this page's directory"),
		),
		"a room the reader just typed was described as an address they followed",
	);
	assert(
		joining.joinLead(pressed, "this page's directory").includes(
			text.joinLeadPressedRoom("arrivals", "this page's directory"),
		),
		"a pressed room gate did not ask for a name",
	);
	// And what this browser merely remembers is an offer, never a destination.
	const cold = card({ source: "restore" }, { room: "lobby", locator: AWAY });
	assert(
		!joining.joinLead(cold, "elsewhere").includes(text.joinLeadNamedDirectory("elsewhere")),
		"what was used last was described as somewhere the reader was going",
	);
});

Deno.test("where a locator field is aimed is one answer, whoever is drawing it", () => {
	// The card's stripe, the card's opening line, and the rail panel's line all
	// ask this, and asking it three times is how they came to disagree while the
	// reader was typing into the one field they all answer to.
	const away = dirId(AWAY);
	const held = new Map([
		[HOME, { id: HOME, slot: null }],
		[away, { id: away, slot: 2 }],
	]) as unknown as ReadonlyMap<
		import("../web/ui/types.ts").DirId,
		import("../web/ui/types.ts").DirView
	>;
	const aimed = (locator: string, typedAs: import("../web/ui/types.ts").DirId | null) =>
		joining.destination(locator, typedAs, held, HOME_CONTEXT, "this directory");

	// The empty field is this page's own directory, and so is an address that
	// resolves to it however it was written.
	assert(aimed("", null).name === "this directory", "an empty field was not read as this page's directory");
	assert(aimed("", null).mark === "home", "this page's directory did not wear its own mark");
	const resetContext = { home: null, defaultDirectory: { id: HOME, locator: HOME } };
	assert(
		joining.destination("", null, new Map(), resetContext, "this directory").mark === "home",
		"an unheld page-default directory did not wear the home mark",
	);
	assert(
		aimed("ocapn://home.iroh?hint=1", HOME).name === "this directory",
		"a hinted route to this page's directory was read as somewhere else",
	);

	// One this tab holds is named the way its rows are named, and wears the mark
	// they wear.
	assert(aimed(AWAY, away).name === "elsewhere", "a held directory was not named the way its rows name it");
	assert(aimed(AWAY, away).mark === "2", "a held directory did not wear the mark its rows wear");

	// One it does not hold may still be a perfectly good address, so it is named
	// rather than read back as the characters somebody pasted; text that is no
	// address at all has nothing to name.
	const stranger = dirId("ocapn://stranger.iroh");
	assert(aimed("ocapn://stranger.iroh", stranger).name === "stranger", "an address in no hand was not named");
	// It wears a mark all the same, because everything the card colours reads
	// the one property that mark sets, and an unmarked card let each of those
	// choose for itself — the stripe choosing the mark this page's own
	// directory wears.
	assert(aimed("ocapn://stranger.iroh", stranger).mark === "unknown", "an unheld directory wore no mark");
	assert(aimed("not an address", null).name === "that directory", "text that names nowhere claimed a destination");
});

Deno.test("a named directory this tab has not reached is a connect", () => {
	const none = new Map() as ReadonlyMap<
		import("../web/ui/types.ts").DirId,
		import("../web/ui/types.ts").DirView
	>;
	const away = card({ source: "press" }, {}, { seq: 1, locator: AWAY });
	assert(
		joining.resolveJoin(away, none, HOME, () => null).act === "connect",
		"an address this tab has not reached was offered as a join",
	);
	assert(
		joining.resolveJoin(card({ source: "press" }), none, HOME, () => HOME).act === "join",
		"this page's own directory asked to be connected before a room could be named",
	);
});

Deno.test("past the ramp the join card stops claiming a color the rail is not showing", () => {
	// Six directories is one more than there are marks, so nothing is marked at
	// all: a color for five of them beside none for the sixth claims a sameness
	// that is not there. The card reads that same answer, because a card wearing
	// a color the rail has put away is naming a distinction nobody can see.
	const ramp = new Map(
		[1, 2, 3, 4, 5, 6].map((slot) => {
			const id = dirId(`ocapn://dir-${slot}.iroh`);
			return [id, { id, slot }];
		}),
	) as unknown as ReadonlyMap<
		import("../web/ui/types.ts").DirId,
		import("../web/ui/types.ts").DirView
	>;
	const crowded = dirId("ocapn://dir-3.iroh");
	const aimed = joining.destination("ocapn://dir-3.iroh", crowded, ramp, HOME_CONTEXT, "this directory");
	assert(aimed.name === "dir-3", "a held directory stopped being named when its color went");
	assert(aimed.mark === "unknown", `the card wore ${JSON.stringify(aimed.mark)} where the rail wears nothing`);

	// And within the ramp it still wears the slot the rail wears, so this is a
	// ceiling rather than the card giving up on color.
	const few = new Map([...ramp].slice(0, 3)) as typeof ramp;
	const inRamp = joining.destination("ocapn://dir-3.iroh", crowded, few, HOME_CONTEXT, "this directory");
	assert(inRamp.mark === "3", `a held directory within the ramp wore ${JSON.stringify(inRamp.mark)}`);
});
