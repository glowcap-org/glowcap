import { assertEquals } from "@std/assert";
import {
  APP_STATE_STORAGE_KEY,
  type AppMode,
  type AppState,
  makeInitialAppState,
  reducer,
  toolsForMode,
} from "./app-state.ts";

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
    const next = reducer(seed({ mode }), { type: "set-tool", tool: "hand" });
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

Deno.test("persistence migration: legacy liveMode=true maps to mode=live", () => {
  // Pre-three-mode shape had `mode: "play" | "build"` plus an
  // orthogonal `liveMode: boolean`. Any persisted state with
  // `liveMode: true` should become `mode: "live"` on load (even
  // if `mode: "build"` was stored — the half-degenerate cell
  // collapses to Live, the only meaningful interpretation).
  const stored = {
    mode: "play" as const,
    liveMode: true,
    liveSturdyref: "ocapn://x.tcp/s/trace",
    scenarioId: "fixture-a",
    tool: "select" as const,
    firstPickNodeId: null,
  };
  globalThis.localStorage?.setItem(
    APP_STATE_STORAGE_KEY,
    JSON.stringify(stored),
  );
  try {
    const init = makeInitialAppState();
    assertEquals(init.mode, "live");
    assertEquals(init.liveSturdyref, "ocapn://x.tcp/s/trace");
    // Legacy `liveMode` field should NOT survive on the new shape.
    assertEquals(
      (init as unknown as { liveMode?: boolean }).liveMode,
      undefined,
    );
  } finally {
    globalThis.localStorage?.removeItem(APP_STATE_STORAGE_KEY);
  }
});

Deno.test("persistence migration: legacy liveMode=false respects stored mode", () => {
  const stored = {
    mode: "build" as const,
    liveMode: false,
    liveSturdyref: "ocapn://x.tcp/s/trace",
    scenarioId: "fixture-a",
    tool: "select" as const,
    firstPickNodeId: null,
  };
  globalThis.localStorage?.setItem(
    APP_STATE_STORAGE_KEY,
    JSON.stringify(stored),
  );
  try {
    const init = makeInitialAppState();
    assertEquals(init.mode, "build");
  } finally {
    globalThis.localStorage?.removeItem(APP_STATE_STORAGE_KEY);
  }
});
