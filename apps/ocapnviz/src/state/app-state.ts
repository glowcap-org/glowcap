/**
 * App-level state — types, reducer, persistence. UI state only;
 * the engine owns timeline / world state via its own observers.
 *
 * Selection lives in the selection-store (interactions/selection-store.ts),
 * NOT here. This reducer owns mode / tool / pane sizes / the live trace sturdyref.
 * The store's `anchor` slot is the single source of truth for the
 * "Inspector follow" entity; consumers that previously read
 * `state.selection` now read `storeSelection.anchor`.
 */

import type { StageVisibility } from "../render/types.ts";
import { scenarios } from "../fixtures/index.ts";
import type { LaneKind } from "../ui/Timeline/state.ts";
import { loadStoredValue, persistStoredValue } from "./storage.ts";

/** Three sibling modes operating on one in-memory document buffer.
 * `live` — the feed connects on entry, and nothing renders until
 * Record, which starts the capture; Stop claims the recording as the
 * buffer source and lands in Play.
 * `play` — replay the buffer (fixture / file / recording).
 * `build` — edit the buffer with authoring tools. */
export type AppMode = "live" | "play" | "build";

/** The tool vocabulary is owned by the interaction layer (the
 * resolver and FSM act on tools, never on modes); re-exported here
 * so app-level consumers keep one import site for UI state. */
export type { BuilderTool } from "../interactions/types.ts";
import type { BuilderTool } from "../interactions/types.ts";

/** Which tools a mode offers. Select and Hand are observation
 * affordances — inspecting and panning mutate nothing — so every
 * mode carries them. The authoring tools mint entities, and only
 * Build holds mutation authority. The reducer enforces this; the
 * palette and keyboard shortcuts render/route from the same list. */
export function toolsForMode(mode: AppMode): readonly BuilderTool[] {
	return mode === "build" ? ALL_TOOLS : OBSERVATION_TOOLS;
}
const OBSERVATION_TOOLS: readonly BuilderTool[] = ["select", "hand"];
const ALL_TOOLS: readonly BuilderTool[] = [
	"select",
	"hand",
	"add-peer",
	"open-session",
	"send-message",
];

/** Provenance of the document buffer — what the Source panel says
 * the buffer IS. Exactly one of these holds at a time: a built-in
 * fixture, an opened file, or a live recording; `edited` marks a
 * buffer that carries Build-mode edits on top of that source. App
 * derives this from its source states; the picker only displays
 * it. */
export type BufferSourceInfo =
	| { kind: "builtin"; id: string; title: string; edited: boolean }
	| { kind: "file"; name: string; edited: boolean }
	| { kind: "recording"; edited: boolean }
	/** Started empty here, by New. Its own kind rather than a file with no name:
	 *  the panel names the source it is playing, and a document that has never
	 *  been written has no name to give. */
	| { kind: "new"; edited: boolean };

export type AppState = {
	scenarioId: string;
	/** Persists across modes; only consumed in Live. */
	liveSturdyref: string;
	mode: AppMode;
	tool: BuilderTool;
	/** Two-click tools (open-session, send-message) park the first stage NODE
	 * here while waiting for the second. A node, not a peer: a message can name
	 * an end nothing has attributed, and the two share one id namespace, so a
	 * field called `peerId` would be holding a stage id and saying otherwise.
	 * Cleared on commit, tool change, mode change, or Escape. */
	firstPickNodeId: string | null;
	/** When true, the bottom timeline pane tracks the panel's
	 * intrinsic content height (re-fitting on lane expand/collapse
	 * and on mode switch). Cleared the moment the user begins a
	 * manual resize drag of the pane's top edge. Toggle persists. */
	autoSizeTimeline: boolean;
};

export type AppAction =
	| { type: "select-scenario"; id: string }
	| { type: "set-live-sturdyref"; sturdyref: string }
	| { type: "set-mode"; mode: AppMode }
	| { type: "set-tool"; tool: BuilderTool }
	| { type: "set-first-pick"; nodeId: string | null }
	| { type: "set-auto-size-timeline"; value: boolean };

export function reducer(state: AppState, action: AppAction): AppState {
	switch (action.type) {
		case "select-scenario":
			return {
				...state,
				scenarioId: action.id,
				firstPickNodeId: null,
			};
		case "set-live-sturdyref":
			return { ...state, liveSturdyref: action.sturdyref };
		case "set-mode":
			// A tool the new mode doesn't offer resets to Select; the
			// observation tools (Select / Hand) survive the transition.
			return {
				...state,
				mode: action.mode,
				tool: toolsForMode(action.mode).includes(state.tool) ? state.tool : "select",
				firstPickNodeId: null,
			};
		case "set-tool":
			// A tool the current mode doesn't offer is refused here, at
			// the one authority, so neither a keyboard shortcut nor a
			// stray dispatch can arm an authoring tool outside Build.
			if (!toolsForMode(state.mode).includes(action.tool)) return state;
			// Tool change wipes in-progress two-click flow — a stale
			// first-pick from one tool would be nonsense for another.
			return { ...state, tool: action.tool, firstPickNodeId: null };
		case "set-first-pick":
			return { ...state, firstPickNodeId: action.nodeId };
		case "set-auto-size-timeline":
			if (state.autoSizeTimeline === action.value) return state;
			return { ...state, autoSizeTimeline: action.value };
	}
}

// ─────────────────────── pane size geometry ───────────────────────

export const TOP_BAR_HEIGHT = 44;

export const LEFT_PANE_MIN = 200;
export const LEFT_PANE_MAX = 480;
// Sized just over the `.ocv-legend-grid` container-query breakpoint
// (280px) so users see the 2-column layout out of the box instead of
// having to drag the pane wider.
export const LEFT_PANE_DEFAULT = 320;

export const RIGHT_PANE_MIN = 220;
export const RIGHT_PANE_MAX = 520;
// Inspector pane needs enough width that the Details kv grid's
// value column can comfortably hold an editable label / profile
// dropdown / public-identifier input without crowding the keys.
export const RIGHT_PANE_DEFAULT = 320;

// Bottom timeline pane. MAX keeps a stale persisted value from
// shoving the pane off the viewport on smaller displays; MIN is
// the smallest height that lets the Scrubber's bottom-anchored
// ruler sit flush against the Overview's bottom edge — control
// row (~40) + Overview (26) + ruler (22) + RULER_TOP_PAD (4) +
// 1px panel border = 93. Below that, the ruler paints with its
// top above the Scrubber's top and bleeds behind the Overview.
// At exactly the minimum the lane area collapses to zero rows
// (which is what the user wants — Overview edge touching ruler
// edge), and any extra height becomes lane space. The control
// row can wrap on narrow widths; in that corner case the floor
// is slightly tight, but the common case is the right place to
// optimize for.
export const BOTTOM_PANE_MIN = 93;
export const BOTTOM_PANE_MAX = 600;
export const BOTTOM_PANE_DEFAULT = 220;

export const RESIZE_HANDLE_THICKNESS = 6;

export type LayoutSizes = {
	leftPaneWidth: number;
	rightPaneWidth: number;
	bottomPaneHeight: number;
};

export const DEFAULT_SIZES: LayoutSizes = {
	leftPaneWidth: LEFT_PANE_DEFAULT,
	rightPaneWidth: RIGHT_PANE_DEFAULT,
	bottomPaneHeight: BOTTOM_PANE_DEFAULT,
};

export const DEFAULT_VISIBILITY: StageVisibility = {
	peers: true,
	connections: true,
	messages: true,
	labels: true,
};

export function clamp(n: number, min: number, max: number): number {
	return Math.max(min, Math.min(max, n));
}

export function clampSizes(s: LayoutSizes): LayoutSizes {
	return {
		leftPaneWidth: clamp(s.leftPaneWidth, LEFT_PANE_MIN, LEFT_PANE_MAX),
		rightPaneWidth: clamp(s.rightPaneWidth, RIGHT_PANE_MIN, RIGHT_PANE_MAX),
		bottomPaneHeight: clamp(
			s.bottomPaneHeight,
			BOTTOM_PANE_MIN,
			BOTTOM_PANE_MAX,
		),
	};
}

// ─────────────────────── persistence ───────────────────────

export const THEME_STORAGE_KEY = "ocapnviz:theme";
export const SIZES_STORAGE_KEY = "ocapnviz:layout-sizes";
export const VISIBILITY_STORAGE_KEY = "ocapnviz:stage-visibility";
export const APP_STATE_STORAGE_KEY = "ocapnviz:app-state";
export const TIMELINE_VIEW_STORAGE_KEY = "ocapnviz:timeline-view";

/** Timeline view state persisted across sessions. Document-relative
 * state (window start/end, hover) is NOT included — it depends on
 * the loaded doc's duration. What IS included is durable user
 * preference: which lanes are visible, which categories are
 * drilled-down, the gutter width. Sets are serialized as arrays. */
export type PersistedTimelineView = {
	expandedLanes?: LaneKind[];
	expandedCategories?: Array<Exclude<LaneKind, "ruler">>;
	gutterWidth?: number;
};

export function loadPersistedTimelineView(): PersistedTimelineView | null {
	const raw = loadStoredValue(TIMELINE_VIEW_STORAGE_KEY);
	if (!raw) return null;
	try {
		const parsed = JSON.parse(raw) as PersistedTimelineView;
		// Defensive shape check — drop malformed fields rather than
		// letting a bad stored value crash the panel.
		return {
			...(Array.isArray(parsed.expandedLanes) ? { expandedLanes: parsed.expandedLanes } : {}),
			...(Array.isArray(parsed.expandedCategories) ? { expandedCategories: parsed.expandedCategories } : {}),
			...(typeof parsed.gutterWidth === "number" ? { gutterWidth: parsed.gutterWidth } : {}),
		};
	} catch {
		return null;
	}
}

export function savePersistedTimelineView(v: PersistedTimelineView): void {
	persistStoredValue(TIMELINE_VIEW_STORAGE_KEY, JSON.stringify(v));
}

/** Live mode accepts the durable trace capability announced by rooms. */
export const DEFAULT_LIVE_STURDYREF = "";

/** Honor `?live=<sturdyref>` (or empty `?live=` for no selected capability)
 * so deep links / headless browsers jump straight into Live mode.
 * Returns null when the query didn't request Live, or when we're
 * in a non-browser environment without `location` (Deno tests). */
export function readLiveOverride(): { liveSturdyref: string } | null {
	const loc = (globalThis as { location?: { search?: string } }).location;
	if (!loc?.search) return null;
	const params = new URLSearchParams(loc.search);
	if (!params.has("live")) return null;
	return {
		liveSturdyref: params.get("live") || DEFAULT_LIVE_STURDYREF,
	};
}

/** Read persisted `AppState`. Returns `null` on missing or
 * malformed input; the caller falls back to defaults. Checks for
 * `localStorage` directly (not `window`) so this works in both
 * browser and Deno test environments. */
export function loadPersistedAppState(): Partial<AppState> | null {
	const raw = loadStoredValue(APP_STATE_STORAGE_KEY);
	if (!raw) return null;
	try {
		return JSON.parse(raw) as Partial<AppState>;
	} catch {
		return null;
	}
}

/**
 * Compose the initial reducer state. Precedence (highest first):
 *   1. `?live=<sturdyref>` query string ⇒ Live mode + capability (intent is a
 *      one-shot deep link; persisted state shouldn't override).
 *   2. localStorage-persisted previous session.
 *   3. Hardcoded defaults.
 */
export function makeInitialAppState(): AppState {
	const persisted = loadPersistedAppState();
	const live = readLiveOverride();
	const persistedMode = persisted?.mode;
	const initialMode: AppMode = live !== null ? "live" : (persistedMode ?? "play");
	return {
		scenarioId: persisted?.scenarioId ?? scenarios[0]?.id ?? "",
		mode: initialMode,
		tool: persisted?.tool ?? "select",
		liveSturdyref: live?.liveSturdyref ??
			persisted?.liveSturdyref ??
			DEFAULT_LIVE_STURDYREF,
		// Don't restore in-flight two-click state across reloads —
		// tools are stateless across sessions.
		firstPickNodeId: null,
		// Default ON so first mount fits to content. User opts out by dragging the
		// resize handle, which trips the auto-disable.
		autoSizeTimeline: persisted?.autoSizeTimeline ?? true,
	};
}
