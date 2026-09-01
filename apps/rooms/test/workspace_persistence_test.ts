// What the browser store does when a save, a restore, or a replacement is
// refused.
//
// The scenarios next door are about what the workspace schemas accept and what
// a projection rebuilds. These are about the write path: storage that fails and
// recovers, a restore that must not overwrite intact state, and a replacement
// that has to validate before it commits. They share a browser rather than a
// subject, so each one leaves the page as it found it.

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
	installWorkspaceStatePersistence,
	parseWorkspaceState,
	rememberedWorkspaceOperation,
	setRememberedWorkspaceOperations,
	setRememberedWorkspaceOperation,
	setWorkspaceControllerSelection,
	workspaceControllerSelection,
	WORKSPACE_STATE_KEY,
} = await import("../web/ui/workspace_state.ts");
const { clearWorkspaceState, exportWorkspaceState, importWorkspaceState, restoreWorkspaceState } = await import(
	"../web/ui/workspace/bundle.ts"
);
const { MAX_WORKSPACE_DIRECTORIES } = await import("../lib/rooms_state.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { LS } = await import("../web/ui/storage.ts");
const store = await import("../web/ui/store.ts");
const { dirId } = await import("../web/ui/types.ts");
const { fixtureSturdyref, workspaceFixture: valid } = await import("./support/workspace.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("workspace persistence retries after browser storage recovers", async () => {
	const page = new RoomsPage();
	memory.delete(WORKSPACE_STATE_KEY);
	const ordinarySet = LS.set;
	let attempts = 0;
	LS.set = (key, value) => {
		attempts += 1;
		return attempts === 1 ? false : ordinarySet(key, value);
	};
	const stop = installWorkspaceStatePersistence(page);
	try {
		store.setStanding(page.projection, "first refused write");
		await new Promise((resolve) => setTimeout(resolve, 300));
		store.setStanding(page.projection, "retry proof");
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
	const page = new RoomsPage();
	const original = JSON.stringify(valid());
	memory.set(WORKSPACE_STATE_KEY, original);
	restoreWorkspaceState(page, () => {
		throw new Error("directory authority resolution is unavailable");
	});
	const stop = installWorkspaceStatePersistence(page);
	try {
		store.setStanding(page.projection, "must not replace the saved document");
		await new Promise((resolve) => setTimeout(resolve, 300));
		assert(
			memory.get(WORKSPACE_STATE_KEY) === original,
			"a refused all-or-nothing restore was overwritten from the empty runtime store",
		);
	} finally {
		stop();
		assert(
			importWorkspaceState(page, original) === "",
			"the saved workspace could not be explicitly restored after refusal",
		);
	}
});

Deno.test("state replacement validates before commit and clear cannot be resurrected", () => {
	const page = new RoomsPage();
	memory.delete(WORKSPACE_STATE_KEY);
	assert(importWorkspaceState(page, '{"version":2') !== "", "a torn import was reported as installed");
	assert(!memory.has(WORKSPACE_STATE_KEY), "a refused import changed saved state");
	assert(importWorkspaceState(page, JSON.stringify(valid())) === "", "a complete state bundle was refused");
	const beforeInvalidOverride = memory.get(WORKSPACE_STATE_KEY);
	const invalidOverride = {
		kind: "attached",
		sturdyref: "not a sturdyref",
	} as import("../lib/rooms_state.ts").RoomsControllerSelection;
	assert(
		importWorkspaceState(page, JSON.stringify(valid()), invalidOverride) !== "",
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
	assert(clearWorkspaceState(page), "the saved state could not be cleared");
	store.setStanding(page.projection, "a later store mutation");
	assert(!memory.has(WORKSPACE_STATE_KEY), "a store mutation resurrected cleared state");
});

Deno.test("explicit export refuses runtime state beyond the workspace schema", () => {
	const page = new RoomsPage();
	page.projection.reset();
	for (let at = 0; at <= MAX_WORKSPACE_DIRECTORIES; at += 1) {
		const locator = `ocapn://directory-${at}.id`;
		store.openDir(page.projection, dirId(locator), locator);
	}
	let refused = "";
	try {
		exportWorkspaceState(page);
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	} finally {
		page.projection.reset();
	}
	assert(refused.includes("not a valid state bundle"), "explicit export emitted an over-bound runtime workspace");
	// A refused save has to name its bound and the way back under it — a reader
	// met a bare "exceeds a persistence bound" once and had nothing to act on.
	assert(refused.includes("directories"), `the refusal did not name the tripped bound: ${refused}`);
	assert(refused.includes(String(MAX_WORKSPACE_DIRECTORIES)), `the refusal did not name the limit: ${refused}`);
});

Deno.test("explicit controller selection replaces protected obsolete state", () => {
	const page = new RoomsPage();
	memory.set(WORKSPACE_STATE_KEY, JSON.stringify({ ...valid(), version: 7 }));
	restoreWorkspaceState(page, () => null);
	const controller = {
		kind: "attached" as const,
		sturdyref: fixtureSturdyref("ocapn://session.iroh", "recovered"),
	};
	assert(
		setWorkspaceControllerSelection(page, controller),
		"explicit attachment did not replace obsolete browser state",
	);
	const saved = parseWorkspaceState(memory.get(WORKSPACE_STATE_KEY) ?? null);
	assert(
		saved?.controller.kind === "attached" && saved.controller.sturdyref === controller.sturdyref,
		"the recovered controller selection was not durable",
	);
});

Deno.test("a hosted session selector becomes local on restore", () => {
	const page = new RoomsPage();
	const hosted = {
		...valid(),
		controller: {
			kind: "hosted" as const,
			sturdyref: fixtureSturdyref("ocapn://session.iroh", "hosted-session"),
		},
	};
	memory.set(WORKSPACE_STATE_KEY, JSON.stringify(hosted));
	restoreWorkspaceState(page, (locator) => dirId(locator));
	assert(
		workspaceControllerSelection(page).kind === "local",
		"hosted sharing survived a new tab",
	);
	const saved = parseWorkspaceState(memory.get(WORKSPACE_STATE_KEY) ?? null);
	assert(saved?.controller.kind === "local", "hosted sharing was left in storage");
});

Deno.test("a refused credential update keeps the prior bearer authoritative", () => {
	const page = new RoomsPage();
	assert(importWorkspaceState(page, JSON.stringify(valid())) === "", "the credential fixture was not installed");
	const ordinarySet = LS.set;
	LS.set = () => false;
	try {
		assert(
			!setRememberedWorkspaceOperation(page, "operator", "ocapn://directory.id", null),
			"a refused credential deletion reported success",
		);
		assert(
			rememberedWorkspaceOperation(page, "operator", "ocapn://directory.id") === "operator-swiss",
			"a refused deletion changed in-memory authority",
		);
	} finally {
		LS.set = ordinarySet;
		clearWorkspaceState(page);
	}
});

Deno.test("an explicit capability-set save replaces protected invalid workspace state", () => {
	const page = new RoomsPage();
	const directory = dirId("ocapn://capability-recovery.id");
	store.openDir(page.projection, directory, directory);
	store.setHomeDir(page.projection, directory);
	memory.set(WORKSPACE_STATE_KEY, '{"version":2');
	restoreWorkspaceState(page, () => null);
	const ordinarySet = LS.set;
	let writes = 0;
	LS.set = (key, value) => {
		writes += 1;
		return ordinarySet(key, value);
	};
	let saved = false;
	try {
		saved = setRememberedWorkspaceOperations(page, [{
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
	clearWorkspaceState(page);
	store.forgetDir(page.projection, directory);
});

Deno.test("capability replacement removes dependent peering intent in the same workspace commit", () => {
	const page = new RoomsPage();
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
	assert(importWorkspaceState(page, JSON.stringify(document)) === "", "the peering workspace fixture was refused");
	restoreWorkspaceState(page, (locator) => dirId(locator));
	assert(
		setRememberedWorkspaceOperations(
			page,
			document.session.capabilities.operations.filter((entry) => entry.capability !== "peering"),
		),
		"removing the peering capability could not commit its dependent cleanup",
	);
	assert(
		parseWorkspaceState(memory.get(WORKSPACE_STATE_KEY) ?? null)?.session.peering.length === 0,
		"the capability replacement retained peering intent without its authority",
	);
	clearWorkspaceState(page);
	for (const conversation of [...page.projection.get().convs.keys()]) store.forgetConv(page.projection, conversation);
	for (const directory of [...page.projection.get().dirs.keys()]) store.forgetDir(page.projection, directory);
});
