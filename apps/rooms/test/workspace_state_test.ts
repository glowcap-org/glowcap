/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const memory = new Map<string, string>();
Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: {
		getItem: (key: string) => memory.get(key) ?? null,
		setItem: (key: string, value: string) => memory.set(key, value),
		removeItem: (key: string) => memory.delete(key),
	},
});

const {
	adoptAttachedSessionState,
	clearWorkspaceState,
	exportWorkspaceState,
	importWorkspaceState,
	installWorkspaceStatePersistence,
	parseWorkspaceState,
	rememberedWorkspaceArchivePeer,
	rememberedWorkspaceOperation,
	restoreWorkspaceState,
	setRememberedWorkspaceOperations,
	setRememberedWorkspaceOperation,
	setWorkspaceControllerSelection,
	workspaceStateOf,
	WORKSPACE_STATE_KEY,
} = await import("../web/ui/workspace_state.ts");
type RoomsSessionState = import("../lib/rooms_state.ts").RoomsSessionState;
const {
	MAX_WORKSPACE_DIRECTORIES,
	parseRoomsSessionStateValue,
	redactWorkspaceCapabilities,
} = await import("../lib/rooms_state.ts");
const { LS } = await import("../web/ui/storage.ts");
const store = await import("../web/ui/store.ts");
const { dirId } = await import("../web/ui/types.ts");
const { registrationId } = await import("./support/registration.ts");
const { workspaceFixture: valid } = await import("./support/workspace.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("workspace state keeps reconstructible user choices under stable conversation ids", () => {
	const parsed = parseWorkspaceState(JSON.stringify(valid()));
	assert(parsed !== null, "a valid workspace document was refused");
	assert(parsed.session.active === "dm-id", "the active conversation identity moved");
	assert(parsed.session.conversations[0].id === "room-id", "the room identity moved");
	assert(
		parsed.session.conversations[0].kind === "room" &&
			(parsed.session.conversations[0].steward?.includes("moderator") ?? false),
		"the held room moderator authority was lost",
	);
	assert(parsed.session.conversations[1].id === "dm-id", "the direct identity moved");
	assert(
		parsed.session.conversations[0].kind === "room" && parsed.session.conversations[0].irc?.password === "secret",
		"the room IRC identity intent moved",
	);
});

Deno.test("a fresh browser has no implicit session controller", () => {
	assert(
		workspaceStateOf(store.get()).controller.kind === "none",
		"fresh state silently established a local session",
	);
	assert(
		parseWorkspaceState(JSON.stringify({ ...valid(), controller: { kind: "none" } }))?.controller.kind === "none",
		"the session-establishment state was refused",
	);
});

Deno.test("attached session adoption retains the complete shared capability and peering projection", () => {
	const attached = valid().session as unknown as RoomsSessionState;
	attached.peering = [{ id: "publication", destination: "destination", source: "room-id", name: "general" }];
	adoptAttachedSessionState(attached);
	assert(
		workspaceStateOf(store.get()).session.peering[0]?.id === "publication",
		"attached session adoption dropped shared peering intent",
	);
	assert(
		rememberedWorkspaceArchivePeer() === attached.capabilities.archivePeer,
		"attached session adoption left archive selection behind in browser storage",
	);
	attached.peering = [];
	adoptAttachedSessionState(attached);
});

Deno.test("controller selection persists once and redacts from ordinary export", () => {
	const base = valid();
	const reset = {
		...base,
		session: {
			...base.session,
			directories: [],
			conversations: [],
			invitations: [],
			active: null,
			capabilities: { operations: [], archivePeer: null },
		},
	};
	assert(importWorkspaceState(JSON.stringify(reset)) === "", "the controller fixture was not installed");
	const controller = { kind: "attached" as const, sturdyref: "ocapn://session.iroh/s/shared-session" };
	assert(setWorkspaceControllerSelection(controller), "the attached controller selection was not saved");
	const complete = JSON.parse(exportWorkspaceState(true));
	const ordinary = JSON.parse(exportWorkspaceState(false));
	assert(complete.controller.sturdyref === controller.sturdyref, "complete export lost the attached controller");
	assert(ordinary.controller.kind === "local", "ordinary export retained attached controller authority");
	assert(importWorkspaceState(JSON.stringify(reset)) === "", "the controller test did not restore local state");
});

Deno.test("ordinary state export removes every retained bearer", () => {
	const complete = parseWorkspaceState(JSON.stringify(valid()));
	assert(complete != null, "the complete fixture was refused");
	const redacted = redactWorkspaceCapabilities(complete);
	const room = redacted.session.conversations.find((conversation) => conversation.kind === "room");
	assert(room?.kind === "room" && room.steward == null && room.link == null, "room authority survived redaction");
	assert(room?.kind === "room" && room.irc == null, "IRC identity credentials survived redaction");
	assert(redacted.session.capabilities.operations.length === 0, "operations authority survived redaction");
	assert(redacted.session.capabilities.archivePeer == null, "archive authority survived redaction");
	assert(redacted.session.invitations.length === 0, "pending room-link authority survived redaction");
});

Deno.test("workspace and session parsers accept only their current prerelease schemas", () => {
	for (const version of [2, 3, 4, 5, 6, 7]) {
		assert(
			parseWorkspaceState(JSON.stringify({ ...valid(), version })) === null,
			`obsolete workspace version ${version} was accepted`,
		);
	}
	const attached = {
		...valid(),
		controller: { kind: "attached", sturdyref: "ocapn://session.iroh/s/shared-session" },
	};
	const parsed = parseWorkspaceState(JSON.stringify(attached));
	assert(parsed?.controller.kind === "attached", "a valid attached session selector was refused");
	assert(
		redactWorkspaceCapabilities(parsed!).controller.kind === "local",
		"ordinary export retained session authority",
	);
	const invalid = { ...valid(), controller: { kind: "attached", sturdyref: "not-a-sturdyref" } };
	assert(parseWorkspaceState(JSON.stringify(invalid)) === null, "an invalid attached session selector was accepted");
	const obsoleteSession = { ...valid().session, version: 2 };
	assert(parseRoomsSessionStateValue(obsoleteSession) === null, "an obsolete session version was accepted");
	const incompleteSession = { ...valid().session } as Partial<RoomsSessionState>;
	delete incompleteSession.peering;
	assert(parseRoomsSessionStateValue(incompleteSession) === null, "an incomplete current session was accepted");
});

Deno.test("workspace projection restores room and moderator capabilities together", () => {
	const directory = dirId("ocapn://directory.id");
	store.openDir(directory, directory);
	store.patchDir(directory, { requestedNick: "ada", nick: "granted-ada" });
	store.setHomeDir(directory);
	const room = store.ensureRoom(directory, "general");
	store.noteRoomSteward(
		room.key,
		"ocapn://directory.id/s/room-link",
		"ocapn://directory.id/s/moderator-link",
	);
	store.setRoomIrcIdentity(room.key, { nick: "pancake", account: "acct", password: "secret" });
	store.addInvite({
		id: "saved-invite",
		dir: dirId("ocapn://target.id"),
		way: "link",
		label: "quiet room",
		from: "bo",
		link: "ocapn://target.id/s/invited-room",
		locator: "ocapn://target.id",
		nick: "ada",
	});
	memory.set(WORKSPACE_STATE_KEY, JSON.stringify(workspaceStateOf(store.get())));
	store.dropInvite("saved-invite");
	store.forgetConv(room.key);
	store.forgetDir(directory);
	restoreWorkspaceState((locator) => locator === directory ? directory : null);
	const restored = store.getConv(room.key);
	assert(restored?.type === "room", "the room record was not restored");
	assert(restored.link?.endsWith("room-link") ?? false, "the room capability was not restored");
	assert(restored.steward?.endsWith("moderator-link") ?? false, "the moderator capability was not restored");
	assert(restored.irc?.nick === "pancake", "the room IRC identity intent was lost");
	assert(store.get().dirs.get(directory)?.requestedNick === "ada", "the requested nickname intent was lost");
	assert(store.get().dirs.get(directory)?.nick === "", "workspace reconstruction invented a live nickname grant");
	store.disconnectRoomIrcIdentity(room.key);
	const clearedRoom = store.getConv(room.key);
	assert(clearedRoom?.type === "room" && clearedRoom.irc === null, "the Rooms-only IRC choice was not retained");
	const roomsOnly = workspaceStateOf(store.get());
	assert(
		roomsOnly.session.conversations[0]?.kind === "room" && roomsOnly.session.conversations[0].irc === null,
		"workspace projection dropped the explicit Rooms-only IRC choice",
	);
	memory.set(WORKSPACE_STATE_KEY, JSON.stringify(roomsOnly));
	store.forgetConv(room.key);
	store.forgetDir(directory);
	restoreWorkspaceState((locator) => locator === directory ? directory : null);
	const restoredRoomsOnly = store.getConv(room.key);
	assert(
		restoredRoomsOnly?.type === "room" && restoredRoomsOnly.irc === null,
		"workspace reconstruction silently re-enabled the automatic IRC seat",
	);
	assert(
		store.get().invites.some((invitation) => invitation.id === "saved-invite"),
		"the room-link invitation was lost",
	);
	const restoredInvite = store.get().invites.find((invitation) => invitation.id === "saved-invite");
	assert(restoredInvite?.locator === "ocapn://target.id", "the invitation target route was lost");
	assert(restoredInvite?.nick === "ada", "the invitation requested nickname was lost");
	store.dropInvite("saved-invite");
	store.forgetConv(room.key);
	store.forgetDir(directory);
	memory.delete(WORKSPACE_STATE_KEY);
});

Deno.test("workspace state preserves unnamed intent and refuses invalid authority relations", () => {
	const duplicate = valid();
	duplicate.session.directories.push({ ...duplicate.session.directories[0], home: false });
	assert(parseWorkspaceState(JSON.stringify(duplicate)) === null, "duplicate directory authority was accepted");
	const foreign = valid();
	foreign.session.conversations[0] = { ...foreign.session.conversations[0], directory: "ocapn://elsewhere.iroh" };
	assert(parseWorkspaceState(JSON.stringify(foreign)) === null, "a conversation without its directory was accepted");
	const unnamed = valid();
	unnamed.session.directories[0].nick = "";
	const parsedUnnamed = parseWorkspaceState(JSON.stringify(unnamed));
	assert(parsedUnnamed != null, "an unnamed directory lost its valid workspace intent");
	assert(parsedUnnamed.session.conversations.length === 2, "an unnamed directory discarded its saved conversations");
	assert(parseWorkspaceState('{"version":1') === null, "a torn document was accepted");
	const foreignCredential = valid();
	foreignCredential.session.capabilities.operations[0] = {
		...foreignCredential.session.capabilities.operations[0],
		scope: "ocapn://elsewhere.iroh",
	};
	assert(parseWorkspaceState(JSON.stringify(foreignCredential)) === null, "a foreign credential scope was accepted");
	const mismatchedRoute = valid();
	mismatchedRoute.session.directories[0].locator = "ocapn://elsewhere.id";
	assert(parseWorkspaceState(JSON.stringify(mismatchedRoute)) === null, "a directory route mismatch was accepted");
	const mismatchedInvitation = valid();
	(mismatchedInvitation.session.invitations[0] as { link: string }).link = "ocapn://elsewhere.id/s/invited-room";
	assert(
		parseWorkspaceState(JSON.stringify(mismatchedInvitation)) === null,
		"an invitation route mismatch was accepted",
	);
	const sturdyrefAsSwiss = valid();
	sturdyrefAsSwiss.session.capabilities.operations[0] = {
		...sturdyrefAsSwiss.session.capabilities.operations[0],
		swiss: "ocapn://directory.iroh/s/not-a-bare-swiss",
	};
	assert(parseWorkspaceState(JSON.stringify(sturdyrefAsSwiss)) === null, "a sturdyref was accepted as a bare swiss");
	const emptySwiss = valid();
	emptySwiss.session.capabilities.operations[0].swiss = "   ";
	assert(parseWorkspaceState(JSON.stringify(emptySwiss)) === null, "an empty operations credential was accepted");
	const splitSwiss = valid();
	splitSwiss.session.capabilities.operations[0].swiss = "two words";
	assert(parseWorkspaceState(JSON.stringify(splitSwiss)) === null, "a split operations credential was accepted");
	const mismatchedRoomLink = valid();
	(mismatchedRoomLink.session.conversations[0] as { link?: string }).link = "ocapn://elsewhere.id/s/room-link";
	assert(parseWorkspaceState(JSON.stringify(mismatchedRoomLink)) === null, "a foreign room link was accepted");
	const mismatchedModerator = valid();
	(mismatchedModerator.session.conversations[0] as { steward?: string }).steward = "ocapn://elsewhere.id/s/moderator";
	assert(parseWorkspaceState(JSON.stringify(mismatchedModerator)) === null, "a foreign moderator was accepted");
	const moderatorWithoutRoom = valid();
	delete (moderatorWithoutRoom.session.conversations[0] as { link?: string }).link;
	assert(
		parseWorkspaceState(JSON.stringify(moderatorWithoutRoom)) === null,
		"a moderator without its room link was accepted",
	);
	const selfDirect = valid();
	(selfDirect.session.conversations[1] as { peer: string }).peer = "ADA";
	assert(
		parseWorkspaceState(JSON.stringify(selfDirect)) === null,
		"a direct conversation with the same member was accepted",
	);
	const duplicateRoom = valid();
	duplicateRoom.session.conversations.push({
		kind: "room",
		id: "duplicate-room",
		directory: "ocapn://directory.id",
		name: "general",
		held: false,
		link: "ocapn://directory.id/s/other-room-link",
		steward: "ocapn://directory.id/s/other-moderator",
		irc: { nick: "pancake", account: "acct", password: "secret" },
		standing: null,
		draft: "",
	});
	assert(
		parseWorkspaceState(JSON.stringify(duplicateRoom)) === null,
		"a duplicate public room membership was accepted",
	);
	const duplicateDirect = valid();
	duplicateDirect.session.conversations.push({ ...duplicateDirect.session.conversations[1], id: "duplicate-direct" });
	assert(
		parseWorkspaceState(JSON.stringify(duplicateDirect)) === null,
		"a duplicate open direct conversation was accepted",
	);
});

Deno.test("workspace schemas normalize capability whitespace and nullable room bearers", () => {
	const document = valid();
	document.session.capabilities.operations[0].swiss = "  listeners-swiss  ";
	const room = document.session.conversations[0] as Record<string, unknown>;
	room.link = null;
	room.steward = null;
	room.publicationId = null;
	const parsed = parseWorkspaceState(JSON.stringify(document));
	assert(parsed != null, "the compatible workspace document was refused");
	assert(
		parsed.session.capabilities.operations[0].swiss === "listeners-swiss",
		"capability whitespace was not normalized",
	);
	const normalizedRoom = parsed.session.conversations[0];
	assert(
		normalizedRoom.kind === "room" && normalizedRoom.link == null && normalizedRoom.steward == null &&
			normalizedRoom.publicationId == null,
		"nullable room bearer fields were not normalized to omission",
	);
});

Deno.test("workspace state refuses runtime-shaped and unbounded content", () => {
	const runtime = valid() as ReturnType<typeof valid> & { runtimeHandle?: unknown };
	runtime.runtimeHandle = { close() {} };
	assert(parseWorkspaceState(JSON.stringify(runtime)) === null, "runtime-shaped state was silently sanitized");
	assert(parseWorkspaceState("x".repeat(600_000)) === null, "an oversized document was accepted");
});

Deno.test("workspace state bounds reconnect and credential fan-out", () => {
	const directoryBase = valid();
	const manyDirectories = {
		...directoryBase,
		session: {
			...directoryBase.session,
			directories: Array.from({ length: 33 }, (_, at) => ({
				id: `ocapn://directory-${at}.iroh`,
				locator: `ocapn://directory-${at}.iroh`,
				home: at === 0,
				nick: "ada",
				standing: null,
			})),
			conversations: [],
			active: null,
		},
	};
	assert(
		parseWorkspaceState(JSON.stringify(manyDirectories)) === null,
		"too many directory reconnects were accepted",
	);

	const conversationBase = valid();
	const manyConversations = {
		...conversationBase,
		session: {
			...conversationBase.session,
			conversations: Array.from({ length: 257 }, (_, at) => ({
				kind: "direct",
				id: `dm-${at}`,
				directory: "ocapn://directory.iroh",
				peer: `peer-${at}`,
				peerRegistrationId: registrationId(at),
				closed: false,
				draft: at === 0 ? "x".repeat(70_000) : "",
			})),
			active: null,
		},
	};
	assert(
		parseWorkspaceState(JSON.stringify(manyConversations)) === null,
		"too many conversation replays were accepted",
	);
	const duplicateCredential = valid();
	duplicateCredential.session.capabilities.operations.push({
		...duplicateCredential.session.capabilities.operations[0],
	});
	assert(
		parseWorkspaceState(JSON.stringify(duplicateCredential)) === null,
		"duplicate bearer authority was accepted",
	);
	const duplicateVisualizer = valid();
	duplicateVisualizer.session.capabilities.operations.push({
		capability: "viz",
		scope: "wss://elsewhere.test/viz",
		swiss: "another-viz-swiss",
	});
	assert(
		parseWorkspaceState(JSON.stringify(duplicateVisualizer)) === null,
		"multiple app-wide visualizer capabilities were accepted",
	);
});

Deno.test("workspace persistence retries after browser storage recovers", async () => {
	memory.delete(WORKSPACE_STATE_KEY);
	const ordinarySet = LS.set;
	let attempts = 0;
	LS.set = (key, value) => {
		attempts += 1;
		return attempts === 1 ? false : ordinarySet(key, value);
	};
	const stop = installWorkspaceStatePersistence();
	try {
		store.setStanding("first refused write");
		await new Promise((resolve) => setTimeout(resolve, 300));
		store.setStanding("retry proof");
		await new Promise((resolve) => setTimeout(resolve, 300));
		assert(attempts >= 2, "workspace persistence did not retry its refused write");
		assert(
			parseWorkspaceState(memory.get(WORKSPACE_STATE_KEY) ?? null)?.session.standing === "retry proof",
			"the retry did not persist current state",
		);
		const settledAttempts = attempts;
		await new Promise((resolve) => setTimeout(resolve, 800));
		assert(attempts === settledAttempts, "a successful workspace write left its older retry timer armed");
	} finally {
		stop();
		LS.set = ordinarySet;
	}
});

Deno.test("a runtime restore refusal cannot overwrite the intact saved workspace", async () => {
	const original = JSON.stringify(valid());
	memory.set(WORKSPACE_STATE_KEY, original);
	restoreWorkspaceState(() => {
		throw new Error("directory authority resolution is unavailable");
	});
	const stop = installWorkspaceStatePersistence();
	try {
		store.setStanding("must not replace the saved document");
		await new Promise((resolve) => setTimeout(resolve, 300));
		assert(
			memory.get(WORKSPACE_STATE_KEY) === original,
			"a refused all-or-nothing restore was overwritten from the empty runtime store",
		);
	} finally {
		stop();
		assert(
			importWorkspaceState(original) === "",
			"the saved workspace could not be explicitly restored after refusal",
		);
	}
});

Deno.test("state replacement validates before commit and clear cannot be resurrected", () => {
	memory.delete(WORKSPACE_STATE_KEY);
	assert(importWorkspaceState('{"version":2') !== "", "a torn import was reported as installed");
	assert(!memory.has(WORKSPACE_STATE_KEY), "a refused import changed saved state");
	assert(importWorkspaceState(JSON.stringify(valid())) === "", "a complete state bundle was refused");
	const beforeInvalidOverride = memory.get(WORKSPACE_STATE_KEY);
	const invalidOverride = {
		kind: "attached",
		sturdyref: "not a sturdyref",
	} as import("../lib/rooms_state.ts").RoomsControllerSelection;
	assert(
		importWorkspaceState(JSON.stringify(valid()), invalidOverride) !== "",
		"an invalid session override bypassed workspace validation",
	);
	assert(
		memory.get(WORKSPACE_STATE_KEY) === beforeInvalidOverride,
		"a refused session override changed the saved workspace",
	);
	assert(
		parseWorkspaceState(memory.get(WORKSPACE_STATE_KEY) ?? null) !== null,
		"the imported bundle was not committed",
	);
	assert(clearWorkspaceState(), "the saved state could not be cleared");
	store.setStanding("a later store mutation");
	assert(!memory.has(WORKSPACE_STATE_KEY), "a store mutation resurrected cleared state");
});

Deno.test("explicit export refuses runtime state beyond the workspace schema", () => {
	store.set(store.initial);
	for (let at = 0; at <= MAX_WORKSPACE_DIRECTORIES; at += 1) {
		const locator = `ocapn://directory-${at}.id`;
		store.openDir(dirId(locator), locator);
	}
	let refused = "";
	try {
		exportWorkspaceState();
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	} finally {
		store.set(store.initial);
	}
	assert(refused.includes("not a valid state bundle"), "explicit export emitted an over-bound runtime workspace");
});

Deno.test("explicit controller selection replaces protected obsolete state", () => {
	memory.set(WORKSPACE_STATE_KEY, JSON.stringify({ ...valid(), version: 7 }));
	restoreWorkspaceState(() => null);
	const controller = { kind: "attached" as const, sturdyref: "ocapn://session.iroh/s/recovered" };
	assert(setWorkspaceControllerSelection(controller), "explicit attachment did not replace obsolete browser state");
	const saved = parseWorkspaceState(memory.get(WORKSPACE_STATE_KEY) ?? null);
	assert(
		saved?.controller.kind === "attached" && saved.controller.sturdyref === controller.sturdyref,
		"the recovered controller selection was not durable",
	);
});

Deno.test("a refused credential update keeps the prior bearer authoritative", () => {
	assert(importWorkspaceState(JSON.stringify(valid())) === "", "the credential fixture was not installed");
	const ordinarySet = LS.set;
	LS.set = () => false;
	try {
		assert(
			!setRememberedWorkspaceOperation("operator", "ocapn://directory.id", null),
			"a refused credential deletion reported success",
		);
		assert(
			rememberedWorkspaceOperation("operator", "ocapn://directory.id") === "operator-swiss",
			"a refused deletion changed in-memory authority",
		);
	} finally {
		LS.set = ordinarySet;
		clearWorkspaceState();
	}
});

Deno.test("an explicit capability-set save replaces protected invalid workspace state", () => {
	const directory = dirId("ocapn://capability-recovery.id");
	store.openDir(directory, directory);
	store.setHomeDir(directory);
	memory.set(WORKSPACE_STATE_KEY, '{"version":2');
	restoreWorkspaceState(() => null);
	const ordinarySet = LS.set;
	let writes = 0;
	LS.set = (key, value) => {
		writes += 1;
		return ordinarySet(key, value);
	};
	let saved = false;
	try {
		saved = setRememberedWorkspaceOperations([{
			capability: "operator",
			scope: directory,
			swiss: "  replacement-operator-swiss  ",
		}]);
	} finally {
		LS.set = ordinarySet;
	}
	assert(saved, "the explicit capability-set replacement stayed blocked by invalid saved state");
	assert(writes === 1, `the capability bundle used ${writes} storage writes instead of one`);
	const recovered = parseWorkspaceState(memory.get(WORKSPACE_STATE_KEY) ?? null);
	assert(recovered != null, "the capability-set replacement did not install a valid workspace");
	assert(
		recovered.session.capabilities.operations[0]?.swiss === "replacement-operator-swiss",
		"the recovered workspace lost the requested capability set",
	);
	clearWorkspaceState();
	store.forgetDir(directory);
});

Deno.test("capability replacement removes dependent peering intent in the same workspace commit", () => {
	const document = valid();
	document.session.directories.push({
		id: "ocapn://destination.id",
		locator: "ocapn://destination.id",
		home: false,
		nick: "ada",
		standing: null,
	});
	const peering = document.session.capabilities.operations.find((entry) => entry.capability === "peering");
	if (peering == null) throw new Error("workspace fixture has no peering credential");
	peering.scope = "ocapn://destination.id";
	document.session.peering = [{
		id: "publication",
		destination: "ocapn://destination.id",
		source: "room-id",
		name: "annex",
	}];
	assert(importWorkspaceState(JSON.stringify(document)) === "", "the peering workspace fixture was refused");
	restoreWorkspaceState((locator) => dirId(locator));
	assert(
		setRememberedWorkspaceOperations(
			document.session.capabilities.operations.filter((entry) => entry.capability !== "peering"),
		),
		"removing the peering capability could not commit its dependent cleanup",
	);
	assert(
		parseWorkspaceState(memory.get(WORKSPACE_STATE_KEY) ?? null)?.session.peering.length === 0,
		"the capability replacement retained peering intent without its authority",
	);
	clearWorkspaceState();
	for (const conversation of [...store.get().convs.keys()]) store.forgetConv(conversation);
	for (const directory of [...store.get().dirs.keys()]) store.forgetDir(directory);
});
