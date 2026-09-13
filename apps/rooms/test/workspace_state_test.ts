// Workspace persistence admits only reconstructible, bounded, bearer-safe state under its current schema.
/// <reference lib="dom" />
import "./support/browser_application.ts";
import { roomAuthorityToken, workspaceStorageKey } from "../web/ui/application.ts";

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
	retainSessionState,
	setWorkspaceControllerSelection,
	parseWorkspaceState,
	setWorkspaceControllerAndSession,
	workspaceStateOf,
} = await import("../web/ui/workspace_state.ts");
const { exportWorkspaceState, importWorkspaceState, restoreWorkspaceState } = await import(
	"../web/ui/workspace/bundle.ts"
);
const { RoomsPage } = await import("../web/ui/page.ts");
type RoomsSessionState = import("../lib/rooms_state.ts").RoomsSessionState;
const { parseRoomsSessionStateValue, redactWorkspaceCapabilities, sharedRoomsSession } = await import(
	"../lib/rooms_state.ts"
);
const store = await import("../web/ui/store.ts");
const { dirId } = await import("../web/ui/types.ts");
const { fixtureSturdyref, workspaceFixture: valid } = await import("./support/workspace.ts");
const { bridgeFormSecretIds, splitBridgeSubmission } = await import("../lib/bridge/form.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

function freshPage() {
	memory.clear();
	return new RoomsPage();
}

Deno.test("workspace state keeps reconstructible user choices under stable conversation ids", () => {
	const parsed = parseWorkspaceState(JSON.stringify(valid()));
	assert(parsed !== null, "a valid workspace document was refused");
	assert(parsed.session.active === "dm-id", "the active conversation identity moved");
	assert(parsed.session.conversations[0].id === "room-id", "the room identity moved");
	assert(
		parsed.session.conversations[0].kind === "room" &&
			parsed.session.conversations[0].steward != null,
		"the held room moderator authority was lost",
	);
	assert(parsed.session.conversations[1].id === "dm-id", "the direct identity moved");
	assert(
		parsed.session.conversations[0].kind === "room" &&
			parsed.session.conversations[0].bridgeIntent?.answers["account"] === "acct",
		"the room IRC identity intent moved",
	);
});

Deno.test("a fresh browser has no implicit session controller", () => {
	const page = freshPage();
	assert(
		workspaceStateOf(page, page.projection.get()).controller.kind === "none",
		"fresh state silently established a local session",
	);
	assert(sharedRoomsSession({ kind: "none" }) === null, "an unestablished controller looked shared");
	assert(sharedRoomsSession({ kind: "local" }) === null, "a local controller looked shared");
	const attached = {
		kind: "attached" as const,
		sturdyref: fixtureSturdyref("ocapn://session.iroh", "shared-session"),
	};
	assert(sharedRoomsSession(attached) === attached, "an attached controller was not shared");
	const hosted = { kind: "hosted" as const, sturdyref: fixtureSturdyref("ocapn://session.iroh", "hosted-session") };
	assert(sharedRoomsSession(hosted) === hosted, "a hosted controller was not shared");
	assert(
		parseWorkspaceState(JSON.stringify({ ...valid(), controller: { kind: "none" } }))?.controller.kind === "none",
		"the session-establishment state was refused",
	);
});

Deno.test("attached session adoption retains the complete shared capability and peering projection", () => {
	const page = freshPage();
	const attached = valid().session as unknown as RoomsSessionState;
	attached.peering = [{ id: "publication", destination: "destination", source: "room-id", name: "general" }];
	retainSessionState(page, attached);
	assert(
		page.workspace.retained.peering[0]?.id === "publication",
		"attached session adoption dropped shared peering intent",
	);
	assert(
		page.workspace.retained.archivePeer === attached.capabilities.archivePeer,
		"attached session adoption left archive selection behind in browser storage",
	);
	attached.peering = [];
	retainSessionState(page, attached);
});

Deno.test("controller selection and its verified session cache persist as one document", () => {
	const page = freshPage();
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
	assert(importWorkspaceState(page, JSON.stringify(reset)) === "", "the controller fixture was not installed");
	const controller = {
		kind: "attached" as const,
		sturdyref: fixtureSturdyref("ocapn://session.iroh", "shared-session"),
	};
	const targetSession = { ...reset.session, standing: "the target session" };
	assert(
		setWorkspaceControllerAndSession(page, controller, targetSession),
		"the attached controller selection was not saved",
	);
	const saved = parseWorkspaceState(memory.get(workspaceStorageKey()) ?? null);
	assert(saved?.session.standing === "the target session", "the new controller retained the prior session cache");
	const complete = JSON.parse(exportWorkspaceState(page, true));
	const ordinary = JSON.parse(exportWorkspaceState(page, false));
	assert(complete.controller.sturdyref === controller.sturdyref, "complete export lost the attached controller");
	assert(ordinary.controller.kind === "local", "ordinary export retained attached controller authority");
	assert(importWorkspaceState(page, JSON.stringify(reset)) === "", "the controller test did not restore local state");
});

Deno.test("ordinary state export removes every retained bearer", () => {
	const complete = parseWorkspaceState(JSON.stringify(valid()));
	assert(complete != null, "the complete fixture was refused");
	const redacted = redactWorkspaceCapabilities(complete);
	const room = redacted.session.conversations.find((conversation) => conversation.kind === "room");
	assert(room?.kind === "room" && room.steward == null && room.link == null, "room authority survived redaction");
	assert(room?.kind === "room" && room.bridgeIntent == null, "IRC identity credentials survived redaction");
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
		controller: { kind: "attached", sturdyref: fixtureSturdyref("ocapn://session.iroh", "shared-session") },
	};
	const parsed = parseWorkspaceState(JSON.stringify(attached));
	assert(parsed?.controller.kind === "attached", "a valid attached session selector was refused");
	assert(
		redactWorkspaceCapabilities(parsed!).controller.kind === "local",
		"ordinary export retained session authority",
	);
	const hosted = {
		...valid(),
		controller: { kind: "hosted", sturdyref: fixtureSturdyref("ocapn://session.iroh", "hosted-session") },
	};
	const hostedParsed = parseWorkspaceState(JSON.stringify(hosted));
	assert(hostedParsed?.controller.kind === "hosted", "a valid hosted session selector was refused");
	assert(
		redactWorkspaceCapabilities(hostedParsed!).controller.kind === "local",
		"ordinary export retained hosted session authority",
	);
	const invalid = { ...valid(), controller: { kind: "attached", sturdyref: "not-a-sturdyref" } };
	assert(parseWorkspaceState(JSON.stringify(invalid)) === null, "an invalid attached session selector was accepted");
	const obsoleteSession = { ...valid().session, version: 2 };
	assert(parseRoomsSessionStateValue(obsoleteSession) === null, "an obsolete session version was accepted");
	const incompleteSession = { ...valid().session } as Partial<RoomsSessionState>;
	delete incompleteSession.peering;
	assert(parseRoomsSessionStateValue(incompleteSession) === null, "an incomplete current session was accepted");
	const leaked = valid();
	const leakedRoom = leaked.session.conversations[0];
	if (leakedRoom.kind === "room" && leakedRoom.bridgeIntent != null) {
		(leakedRoom.bridgeIntent as unknown as Record<string, string>).password = "must-not-persist";
	}
	assert(parseWorkspaceState(JSON.stringify(leaked)) === null, "a persisted IRC password was accepted");
});

Deno.test("workspace projection restores room and moderator capabilities together", () => {
	const page = freshPage();
	const directory = dirId("ocapn://directory.id");
	store.openDir(page.projection, directory, directory);
	store.patchDir(page.projection, directory, { requestedNick: "ada", nick: "granted-ada" });
	store.setHomeDir(page.projection, directory);
	const room = store.ensureRoom(page.projection, directory, "general");
	const roomLink = fixtureSturdyref("ocapn://directory.id", "room-link");
	const moderatorLink = fixtureSturdyref("ocapn://directory.id", "moderator-link");
	store.noteRoomSteward(page.projection, room.key, roomLink, moderatorLink);
	// Built the way the browser builds one, from everything a reader typed split
	// by IRC's own declaration of which field is a credential. Handing the
	// already-split answers in instead would prove only that this test can leave
	// a password out.
	const declared = {
		scope: "network",
		title: "IRC identity",
		said: "Choose an identity",
		fields: [
			{ kind: "text" as const, id: "nick", label: "Nick", required: true },
			{ kind: "text" as const, id: "account", label: "Account", required: false },
			{ kind: "secret" as const, id: "password", label: "Password", required: false },
		],
		actions: [{
			id: "connect",
			label: "Connect",
			busyLabel: "Connecting…",
			tone: "primary" as const,
			remembered: true,
		}],
	};
	const submission = splitBridgeSubmission(bridgeFormSecretIds(declared), {
		nick: "glowcap",
		account: "acct",
		password: "hunter2",
	});
	const saved = valid();
	const savedRoom = saved.session.conversations[0];
	assert(savedRoom.kind === "room", "fixture must contain a room");
	savedRoom.link = roomLink;
	savedRoom.steward = moderatorLink;
	savedRoom.bridgeIntent = {
		scope: "Libera",
		action: "link",
		answers: submission.answers,
		secretsGiven: Object.keys(submission.secrets).length > 0,
	};
	saved.session.invitations = [{
		kind: "room-link",
		id: "saved-invite",
		directory: "ocapn://target.id",
		locator: "ocapn://target.id",
		nick: "ada",
		label: "quiet room",
		from: "bo",
		link: fixtureSturdyref("ocapn://target.id", "invited-room"),
	}];
	assert(parseWorkspaceState(JSON.stringify(saved)) != null, JSON.stringify(saved));
	memory.set(workspaceStorageKey(), JSON.stringify(saved));
	const persisted = memory.get(workspaceStorageKey())!;
	assert(!persisted.includes("hunter2"), "a secret answer entered browser storage");
	assert(persisted.includes("glowcap"), "the remembered answers did not reach browser storage");
	store.dropInvite(page.projection, "saved-invite");
	store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
	restoreWorkspaceState(page, (locator) => locator === directory ? directory : null);
	const restored = store.getConv(page.projection, room.key);
	assert(restored?.type === "room", "the room record was not restored");
	assert(restored.membership === "unavailable", "workspace reconstruction invented a live membership");
	assert(restored.linkToken === roomAuthorityToken(roomLink), "the room capability was not restored");
	assert(restored.stewardToken === roomAuthorityToken(moderatorLink), "the moderator capability was not restored");
	assert(restored.bridgeIntent?.answers["nick"] === "glowcap", "the room IRC identity intent was lost");
	assert(
		page.projection.get().dirs.get(directory)?.requestedNick === "ada",
		"the requested nickname intent was lost",
	);
	assert(
		page.projection.get().dirs.get(directory)?.nick === "",
		"workspace reconstruction invented a live nickname grant",
	);
	assert(
		page.projection.get().dirs.get(directory)?.reached === false,
		"workspace reconstruction invented a successful dial",
	);
	assert(
		page.projection.get().dirs.get(directory)?.session === "connecting",
		"an unreached restore claimed the directory had been live",
	);
	store.clearRoomBridgeIntent(page.projection, room.key);
	const clearedRoom = store.getConv(page.projection, room.key);
	assert(
		clearedRoom?.type === "room" && clearedRoom.bridgeIntent === null,
		"the Rooms-only IRC choice was not retained",
	);
	const roomsOnly = saved;
	savedRoom.bridgeIntent = null;
	assert(
		roomsOnly.session.conversations[0]?.kind === "room" && roomsOnly.session.conversations[0].bridgeIntent === null,
		"workspace projection dropped the explicit Rooms-only IRC choice",
	);
	memory.set(workspaceStorageKey(), JSON.stringify(roomsOnly));
	store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
	restoreWorkspaceState(page, (locator) => locator === directory ? directory : null);
	const restoredRoomsOnly = store.getConv(page.projection, room.key);
	assert(
		restoredRoomsOnly?.type === "room" && restoredRoomsOnly.bridgeIntent === null,
		"workspace reconstruction silently re-enabled the automatic IRC seat",
	);
	assert(
		page.projection.get().invites.some((invitation) => invitation.id === "saved-invite"),
		"the room-link invitation was lost",
	);
	const restoredInvite = page.projection.get().invites.find((invitation) => invitation.id === "saved-invite");
	assert(restoredInvite?.locator === "ocapn://target.id", "the invitation target route was lost");
	assert(restoredInvite?.nick === "ada", "the invitation requested nickname was lost");
	store.dropInvite(page.projection, "saved-invite");
	store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
	memory.delete(workspaceStorageKey());
});

Deno.test("workspace restore preserves actual reach evidence without inventing it", () => {
	const page = freshPage();
	page.projection.reset();
	const reached = dirId("ocapn://reached.id");
	const route = "ocapn://reached.iroh";
	store.openDir(page.projection, reached, route);
	store.markDirReached(page.projection, reached);
	const saved = valid();
	saved.controller = page.workspace.retained.controller;
	saved.session.directories = [{
		id: reached,
		locator: route,
		home: true,
		nick: "ada",
		standing: null,
		reached: true,
	}];
	saved.session.capabilities.operations = [];
	saved.session.conversations = [];
	saved.session.invitations = [];
	saved.session.active = null;
	assert(parseWorkspaceState(JSON.stringify(saved)) != null, JSON.stringify(saved));
	memory.set(workspaceStorageKey(), JSON.stringify(saved));
	store.forgetDir(page.projection, reached);
	restoreWorkspaceState(page, (locator) => locator === route ? reached : null);
	assert(
		page.projection.get().dirs.get(reached)?.reached === true,
		"restore discarded a successful prior connection",
	);
	assert(
		page.projection.get().dirs.get(reached)?.session === "reconnecting",
		"a previously reached restore did not say the directory was coming back",
	);
	page.projection.reset();
});

Deno.test("an attached restore does not present directories as a dropped live connection", () => {
	const page = freshPage();
	page.projection.reset();
	const reached = dirId("ocapn://reached.id");
	const route = "ocapn://reached.iroh";
	store.openDir(page.projection, reached, route);
	store.markDirReached(page.projection, reached);
	page.workspace.retained = {
		...page.workspace.retained,
		controller: {
			kind: "attached",
			sturdyref: fixtureSturdyref("ocapn://session.iroh", "attached-restore"),
		},
	};
	const saved = valid();
	saved.controller = page.workspace.retained.controller;
	saved.session.directories = [{
		id: reached,
		locator: route,
		home: true,
		nick: "ada",
		standing: null,
		reached: true,
	}];
	saved.session.capabilities.operations = [];
	saved.session.conversations = [];
	saved.session.invitations = [];
	saved.session.active = null;
	assert(parseWorkspaceState(JSON.stringify(saved)) != null, JSON.stringify(saved));
	memory.set(workspaceStorageKey(), JSON.stringify(saved));
	store.forgetDir(page.projection, reached);
	restoreWorkspaceState(page, (locator) => locator === route ? reached : null);
	assert(
		page.projection.get().dirs.get(reached)?.reached === false,
		"an attached restore treated a prior connection as this tab's live reach",
	);
	assert(
		page.projection.get().dirs.get(reached)?.session === "connecting",
		"an attached restore said the directory was coming back before CapTP existed",
	);
	page.projection.reset();
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
	(mismatchedInvitation.session.invitations[0] as { link: string }).link = fixtureSturdyref(
		"ocapn://elsewhere.id",
		"invited-room",
	);
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
	(mismatchedRoomLink.session.conversations[0] as { link?: string }).link = fixtureSturdyref(
		"ocapn://elsewhere.id",
		"room-link",
	);
	assert(parseWorkspaceState(JSON.stringify(mismatchedRoomLink)) === null, "a foreign room link was accepted");
	const mismatchedModerator = valid();
	(mismatchedModerator.session.conversations[0] as { steward?: string }).steward = fixtureSturdyref(
		"ocapn://elsewhere.id",
		"moderator",
	);
	assert(parseWorkspaceState(JSON.stringify(mismatchedModerator)) === null, "a foreign moderator was accepted");
	const mismatchedManager = valid();
	(mismatchedManager.session.conversations[0] as { manager?: string }).manager = fixtureSturdyref(
		"ocapn://elsewhere.id",
		"manager",
	);
	assert(parseWorkspaceState(JSON.stringify(mismatchedManager)) === null, "a foreign room manager was accepted");
	const malformedManager = valid();
	(malformedManager.session.conversations[0] as { manager?: string }).manager = "ocapn://directory.id/s/";
	assert(parseWorkspaceState(JSON.stringify(malformedManager)) === null, "a malformed room manager was accepted");
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
		link: fixtureSturdyref("ocapn://directory.id", "other-room-link"),
		steward: fixtureSturdyref("ocapn://directory.id", "other-moderator"),
		bridgeIntent: {
			scope: "Libera",
			action: "link",
			answers: { nick: "glowcap", account: "acct" },
			secretsGiven: true,
		},
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

Deno.test("a local fork of an attached session drops directory names and keeps rooms unreadied", () => {
	const page = freshPage();
	const directory = dirId("ocapn://fork.id");
	store.openDir(page.projection, directory, directory);
	store.patchDir(page.projection, directory, { requestedNick: "ada", nick: "ada" });
	store.remember(page.projection, { nick: "ada" });
	const room = store.ensureRoom(page.projection, directory, "general", {
		publicationId: "bridge-gen",
		reconnect: "manual",
	});
	const attached = valid();
	attached.controller = { kind: "attached", sturdyref: fixtureSturdyref("ocapn://session.iroh", "fork") };
	attached.session.directories = [{ id: directory, locator: directory, home: true, nick: "ada", standing: null }];
	attached.session.conversations = [{
		kind: "room",
		id: "fork-room",
		directory,
		name: "general",
		held: false,
		standing: null,
		draft: "",
		publicationId: "bridge-gen",
		reconnect: "manual",
	}];
	attached.session.invitations = [];
	attached.session.active = "fork-room";
	attached.session.capabilities.operations = [];
	assert(parseWorkspaceState(JSON.stringify(attached)) != null, "fork fixture is invalid");
	memory.set(workspaceStorageKey(), JSON.stringify(attached));
	restoreWorkspaceState(page, (locator) => locator === directory ? directory : null);
	const originalWrite = localStorage.setItem;
	localStorage.setItem = () => {
		throw new Error("storage full");
	};
	try {
		assert(!setWorkspaceControllerSelection(page, { kind: "local" }), "a refused fork was committed");
		assert(
			page.projection.get().dirs.get(directory)?.requestedNick === "ada",
			"a refused fork mutated nickname intent",
		);
		assert(memory.get(workspaceStorageKey()) === JSON.stringify(attached), "a refused fork changed durable state");
	} finally {
		localStorage.setItem = originalWrite;
	}
	assert(setWorkspaceControllerSelection(page, { kind: "local" }), "the fork did not commit");
	store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
	restoreWorkspaceState(page, (locator) => locator === directory ? directory : null);
	const restored = store.getConv(page.projection, room.key);
	assert(restored?.type === "room", "the copied room was not restored: " + memory.get(workspaceStorageKey()));
	assert(restored.membership === "unavailable", "the copied room reconstructed as already joining");
	assert(restored.reconnect === "manual", "explicit rejoin intent was lost");
	assert(restored.publicationId === "bridge-gen", "the bridge publication identity was lost");
	assert(
		page.projection.get().dirs.get(directory)?.requestedNick === "",
		"reconstruction restored a nickname the fork had dropped",
	);
	store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
});
