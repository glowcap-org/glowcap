import { assertEquals } from "@std/assert";
import {
	APP_STATE_STORAGE_KEY,
	type AppMode,
	type AppState,
	loadPersistedLayoutSizes,
	loadPersistedStageVisibility,
	makeInitialAppState,
	reducer,
	SIZES_STORAGE_KEY,
	toolsForMode,
	VISIBILITY_STORAGE_KEY,
} from "./app-state.ts";
import { installMemoryStorage } from "./memory-storage.ts";

installMemoryStorage();

// A minimal seed state for tests. Skip pane-size geometry; only
// the mode-related fields exercise the reducer.
function seed(overrides: Partial<AppState> = {}): AppState {
	return {
		scenarioId: "test",
		mode: "play",
		tool: "select",
		liveSturdyref: "ocapn://localhost%3A9000.tcp/s/trace",
		firstPickNodeId: null,
		autoSizeTimeline: true,
		...overrides,
	};
}

Deno.test("AppMode includes live as a sibling mode", () => {
	const modes: AppMode[] = ["live", "play", "build"];
	assertEquals(modes.length, 3);
});

Deno.test("set-mode transitions to live and resets tool + first-pick", () => {
	const next = reducer(
		seed({ tool: "add-peer", firstPickNodeId: "p1" }),
		{ type: "set-mode", mode: "live" },
	);
	assertEquals(next.mode, "live");
	assertEquals(next.tool, "select");
	assertEquals(next.firstPickNodeId, null);
});

Deno.test("toolsForMode: observation tools everywhere, authoring in build", () => {
	// Select and Hand mutate nothing, so every mode offers them; the
	// authoring tools exist only where mutation authority lives.
	for (const mode of ["live", "play"] as const) {
		assertEquals(toolsForMode(mode), ["select", "hand"]);
	}
	assertEquals(toolsForMode("build"), [
		"select",
		"hand",
		"add-peer",
		"open-session",
		"send-message",
	]);
});

Deno.test("set-tool refuses a tool the current mode does not offer", () => {
	// The reducer is the one authority; a keyboard shortcut or stray
	// dispatch cannot arm an authoring tool outside Build.
	const next = reducer(seed({ mode: "play" }), {
		type: "set-tool",
		tool: "add-peer",
	});
	assertEquals(next.tool, "select");
});

Deno.test("set-tool accepts hand in every mode", () => {
	for (const mode of ["live", "play", "build"] as const) {
		const next = reducer(seed({ mode }), {
			type: "set-tool",
			tool: "hand",
		});
		assertEquals(next.tool, "hand");
	}
});

Deno.test("set-mode keeps an observation tool, resets an authoring one", () => {
	// Hand survives Build → Play (it exists there); Add Peer does not.
	const keptHand = reducer(
		seed({ mode: "build", tool: "hand" }),
		{ type: "set-mode", mode: "play" },
	);
	assertEquals(keptHand.tool, "hand");
	const resetPeer = reducer(
		seed({ mode: "build", tool: "add-peer" }),
		{ type: "set-mode", mode: "play" },
	);
	assertEquals(resetPeer.tool, "select");
});

Deno.test("set-live-sturdyref is independent of mode", () => {
	const next = reducer(seed({ mode: "play" }), {
		type: "set-live-sturdyref",
		sturdyref: "ocapn://other%3A9000.tcp/s/trace",
	});
	assertEquals(next.liveSturdyref, "ocapn://other%3A9000.tcp/s/trace");
	assertEquals(next.mode, "play");
});

Deno.test("the current persisted mode and live sturdyref survive reload", () => {
	const stored = {
		mode: "build" as const,
		liveSturdyref: "ocapn://x.tcp/s/trace",
		scenarioId: "fixture-a",
		tool: "select" as const,
		firstPickNodeId: null,
		autoSizeTimeline: false,
	};
	localStorage.setItem(
		APP_STATE_STORAGE_KEY,
		JSON.stringify(stored),
	);
	try {
		const init = makeInitialAppState();
		assertEquals(init.mode, "build");
		assertEquals(init.liveSturdyref, "ocapn://x.tcp/s/trace");
		assertEquals(init.autoSizeTimeline, false);
	} finally {
		localStorage.removeItem(APP_STATE_STORAGE_KEY);
	}
});

Deno.test("a stored app state that is not the full shape is discarded whole", () => {
	localStorage.setItem(
		APP_STATE_STORAGE_KEY,
		JSON.stringify({ mode: "build", liveSturdyref: "ocapn://x.tcp/s/trace" }),
	);
	try {
		const init = makeInitialAppState();
		assertEquals(init.mode, "play");
		assertEquals(init.liveSturdyref, "");
	} finally {
		localStorage.removeItem(APP_STATE_STORAGE_KEY);
	}
});

Deno.test("stored pane sizes and layer visibility load only as the full shape", () => {
	try {
		localStorage.setItem(SIZES_STORAGE_KEY, JSON.stringify({ leftPaneWidth: 300 }));
		localStorage.setItem(VISIBILITY_STORAGE_KEY, JSON.stringify({ peers: false }));
		assertEquals(loadPersistedLayoutSizes(), null);
		assertEquals(loadPersistedStageVisibility(), null);
		const sizes = { leftPaneWidth: 300, rightPaneWidth: 320, bottomPaneHeight: 200 };
		const visibility = { peers: false, connections: true, messages: true, labels: true };
		localStorage.setItem(SIZES_STORAGE_KEY, JSON.stringify(sizes));
		localStorage.setItem(VISIBILITY_STORAGE_KEY, JSON.stringify(visibility));
		assertEquals(loadPersistedLayoutSizes(), sizes);
		assertEquals(loadPersistedStageVisibility(), visibility);
	} finally {
		localStorage.removeItem(SIZES_STORAGE_KEY);
		localStorage.removeItem(VISIBILITY_STORAGE_KEY);
	}
});
