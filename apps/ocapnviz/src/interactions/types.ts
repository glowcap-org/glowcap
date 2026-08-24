/**
 * Interaction architecture — type module.
 *
 * Mirror of § 2 of `docs/interaction-model.md`. This
 * file is the SINGLE source of truth for the types that flow through
 * the gesture resolver (§ 4), pointer FSM (§ 5), selection store
 * (§ 6), and the React surface adapters (§ 8). Every other module in
 * `src/interactions/` takes its vocabulary from here, and reaches
 * outside the directory only for a spelling `src/schema/` already
 * owns.
 *
 * No React, no Pixi, no DOM. Trivially fixturable.
 *
 * `AppMode` is intentionally NOT in this file — modes are a UI
 * shortcut, not an architectural concept (§ 1.1 of the doc). The
 * resolver and FSM never read mode; they read `activeTool`.
 */

// ─────────────────────── Selection state (§ 2.1) ───────────────────────

export type LaneCategory = "peers" | "sessions" | "messages";

/** What a selection can point at.
 *
 * `endpoint` is a session's end that nothing has attributed to a peer. It is
 * selectable because a reader has to be able to ask what that end claims,
 * and it is its own kind because it is not a peer: it has no lane of its own
 * (its session's row governs it), it cannot be deleted on its own, and every
 * walk over peers has to keep missing it. Its id is `sessionId::side`. */
export type EntityKind = "peer" | "endpoint" | "session" | "message";

export type EntityRef = { kind: EntityKind; id: string };

/** Encoded form used as a Set key — JS Sets can't dedupe object
 *  refs by value, so we serialize to `"<kind>:<id>"`. */
export type EntityRefKey = `${EntityKind}:${string}`;

export function entityKey(ref: EntityRef): EntityRefKey {
	return `${ref.kind}:${ref.id}`;
}

export function parseEntityKey(key: EntityRefKey): EntityRef {
	// Kind is one of four literals; the rest of the string is the id
	// (which may itself contain colons in pathological inputs).
	const idx = key.indexOf(":");
	if (idx <= 0) {
		throw new Error(`invalid EntityRefKey: ${key}`);
	}
	const kind = key.slice(0, idx) as EntityKind;
	const id = key.slice(idx + 1);
	return { kind, id };
}

export function entityRefsEqual(a: EntityRef, b: EntityRef): boolean {
	return a.kind === b.kind && a.id === b.id;
}

export type SelectionState = {
	/** Inspector follow target. The current entity moves to the most
	 *  recent selection member and is null when nothing is selected.
	 *  Null when nothing is anchored (selection size 0 implies
	 *  anchor null; selection size ≥ 1 implies anchor set). */
	anchor: EntityRef | null;
	/** THE selection. The set of entities the user has selected;
	 *  property edits, group delete, group drag, group nudge all
	 *  operate on this set. Heterogeneous: peers, sessions, and
	 *  messages may coexist. There is no separate "multi" — a
	 *  selection of size 1 is still the selection. */
	selection: ReadonlySet<EntityRefKey>;
};

export const EMPTY_SELECTION: SelectionState = {
	anchor: null,
	selection: new Set(),
};

/** The identity side of a document: which entities it declares, by kind and id.
 *
 *  Named on its own because the one question it answers — does this document
 *  still hold this entity — is asked from outside the store too, and a caller
 *  with a document in hand can ask it directly (`documentHolds`). */
export type DeclaredEntities = {
	peers?: Readonly<Record<string, unknown>> | undefined;
	sessions?: Readonly<Record<string, unknown>> | undefined;
	messages?: Readonly<Record<string, unknown>> | undefined;
} | undefined;

export type SelectionAction =
	// selection (THE set; size 0+; uniform vocabulary)
	| { kind: "set-selection"; entities: ReadonlySet<EntityRefKey> }
	| { kind: "add-to-selection"; entities: ReadonlySet<EntityRefKey> }
	| { kind: "remove-from-selection"; entities: ReadonlySet<EntityRefKey> }
	// Drop whatever the document no longer holds. Undo and redo move
	// ids under the selection — a rename taken back leaves it pointing
	// at a name nothing answers to — and this is how it catches up.
	// `undoWithSelection` / `redoWithSelection` in `builder/selection-history.ts`
	// are what dispatch it, and the top bar and the Cmd-Z binding both
	// take history back through them.
	| { kind: "reconcile-with-doc"; entities: DeclaredEntities }
	// Surgical id rewrite after a rename — see `selection-store.ts`
	// for why this is distinct from `set-selection`.
	| {
		kind: "rename-entity";
		entityKind: EntityKind;
		oldId: string;
		newId: string;
	}
	| { kind: "clear-all" }
	| { kind: "clear-on-empty-click" };

// ─────────────────────── Pointer & keyboard input (§ 2.2) ───────────────

export type ModifierSet = {
	shift: boolean;
	cmd: boolean;
	alt: boolean;
};

export const NO_MODIFIERS: ModifierSet = {
	shift: false,
	cmd: false,
	alt: false,
};

export type PointerSnapshot = {
	clientX: number;
	clientY: number;
	/** Bitmask: 1 = primary, 2 = secondary, 4 = middle. */
	buttons: number;
	modifiers: ModifierSet;
	timestampMs: number;
};

// ─────────────────────── Hit-test result (§ 2.3) ────────────────────────

export type Hit =
	| { surface: "stage-empty" }
	| { surface: "stage-peer"; peerId: string }
	| { surface: "stage-endpoint"; endpointId: string }
	| { surface: "stage-edge"; sessionId: string }
	| { surface: "stage-message"; messageId: string }
	| { surface: "timeline-overview"; t: number }
	/** A grip on one end of the overview's visible-window rect. Its own
	 *  surface, not a flag on `timeline-overview`, for the same reason a lane
	 *  event edge is its own: the resolver branches on `surface`. */
	| { surface: "timeline-overview-edge"; edge: "start" | "end"; t: number }
	| { surface: "timeline-ruler"; t: number }
	| { surface: "timeline-lane-empty"; t: number }
	| {
		surface: "timeline-lane-event";
		/** The observation event the pill paints, or null when the pill is the
		 *  entity's own span and no observation names it. An authored peer or
		 *  session is the second case: the engine retimes it by entity rather
		 *  than by event, and the pointer picks it exactly the same way. */
		eventId: string | null;
		entityRef: EntityRef;
	}
	| {
		surface: "timeline-lane-event-edge";
		eventId: string | null;
		entityRef: EntityRef;
	}
	/** The draggable seam between the row gutter and the plot area. Its own
	 *  surface because the drag it starts resizes the gutter and nothing else,
	 *  and it takes precedence over whatever row it crosses. */
	| { surface: "timeline-gutter-edge" }
	| { surface: "timeline-gutter-chevron"; category: LaneCategory }
	| { surface: "timeline-gutter-eyeball"; scope: VisibilityScope }
	| {
		surface: "timeline-gutter-label";
		category: LaneCategory;
		entityId: string;
	};

/**
 * The rows a gutter eyeball governs.
 *
 * A row's own eyeball, a category header's, and the overview's all-rows
 * eyeball are one control repeated down one column, so they are one surface
 * and this is the part of the picture a click acts on.
 */
export type VisibilityScope =
	| { kind: "row"; category: LaneCategory; entityId: string }
	| { kind: "category"; category: LaneCategory }
	| { kind: "all" };

export type SurfaceId = Hit["surface"];

/**
 * The Stage's own surfaces, which are the surfaces a build tool can act on.
 *
 * The build tools exist only in Build mode and every one of them acts on the
 * canvas: `add-peer` on empty space, the two-click tools on a peer or a session
 * end. Nothing any of them does lands on the Timeline, so the Timeline's
 * surfaces are not in this set and cannot be talked about in a build tool's
 * terms.
 *
 * It is the whole family and not just the surfaces a tool has a verb for,
 * because a tool's resting cursor is its statement of which tool is active and
 * has to hold across the canvas rather than blink out when the pointer crosses
 * an edge or a message.
 *
 * Written out rather than tested by name prefix: the prefix is a naming
 * convention and this is a claim about what a tool can reach, so a surface
 * added to one family without a thought about the other should be a decision
 * somebody makes here.
 */
export const STAGE_SURFACES: ReadonlySet<SurfaceId> = new Set<SurfaceId>([
	"stage-empty",
	"stage-peer",
	"stage-endpoint",
	"stage-edge",
	"stage-message",
]);

/** Whether this surface is one the Stage owns, and so one a build tool may
 *  speak about. */
export function isStageSurface(surface: SurfaceId): boolean {
	return STAGE_SURFACES.has(surface);
}

/**
 * The Stage hit that names `ref`, for the four stage surfaces.
 *
 * The Stage needs it because its hover is an entity and the resolver speaks
 * `Hit`s: an affordance can only ask what a click would do by handing over the
 * hit that click would produce. Here rather than in the Stage so a new entity
 * kind has one exhaustive place to acquire its surface vocabulary.
 */
export function stageHitFor(ref: EntityRef): Hit {
	switch (ref.kind) {
		case "peer":
			return { surface: "stage-peer", peerId: ref.id };
		case "endpoint":
			return { surface: "stage-endpoint", endpointId: ref.id };
		case "session":
			return { surface: "stage-edge", sessionId: ref.id };
		case "message":
			return { surface: "stage-message", messageId: ref.id };
	}
}

// ─────────────────────── Gesture context (§ 2.4) ────────────────────────

/** Modifier-resolved intent of a selection gesture (click or
 * marquee), one grammar across every surface — stage sprites, stage
 * marquee, timeline pills, timeline marquee — so the same modifier
 * combo means the same thing wherever the user selects:
 *   plain          → replace   (selection becomes the hits)
 *   shift          → add       (already-in is a no-op)
 *   shift+option   → remove    (not-in is a no-op)
 *   option alone   → reserved  (a surface may bind it locally,
 *                    e.g. the timeline's pan)
 * The interpretation of a mode against the selection also has one
 * home: `selection-store.ts`'s `selectionActionFor`. */
export type SelectMode = "replace" | "add" | "remove";

/** Map a captured modifier snapshot to a {@link SelectMode}. */
export function selectModeFromModifiers(
	m: { shiftKey: boolean; altKey: boolean },
): SelectMode {
	if (m.shiftKey && m.altKey) return "remove";
	if (m.shiftKey) return "add";
	return "replace";
}

/**
 * The tools that mean something on every surface, because both are about
 * getting around rather than about authoring: Select picks what is under the
 * pointer, and Hand moves the view.
 */
export type NavigationTool = "select" | "hand";

/**
 * The tools that build a document, all of which act on the Stage and only
 * there: `add-peer` on empty canvas, the two-click tools on a peer or a session
 * end. `STAGE_SURFACES` is the set they can reach.
 */
export type AuthoringTool = "add-peer" | "open-session" | "send-message";

export type BuilderTool = NavigationTool | AuthoringTool;

/**
 * The navigational half of a tool, which is all a surface outside the Stage can
 * act on.
 *
 * An authoring tool answers `select` rather than being refused, because that is
 * what those surfaces already do: the Timeline's hosts never read the active
 * tool on the way to a click, so a lane click selects whatever tool is chosen.
 * Naming that here makes the Timeline's cursor agree with the Timeline's click
 * in both directions — no build-tool cursor promising something a lane cannot
 * do, and no missing selection preview under a modifier the lane does honour.
 */
export function navigationToolOf(tool: BuilderTool): NavigationTool {
	return tool === "hand" ? "hand" : "select";
}

/** Two-click tools maintain in-flight state: the node already picked and
 *  waiting for its partner. Null when no two-click sequence is mid-flight.
 *
 *  A node, not a peer — Send Message arms an end nothing has attributed
 *  exactly as it arms a peer, so `nodeId` may be an endpoint's stage id.
 *
 *  The host owns it: the Stage holds the armed pick in its `armedNode` prop
 *  and hands it to the cursor as `CursorContext.toolState`. The resolver is
 *  not told, because a pick resolves from the tool and the node alone. */
export type ToolState =
	| { tool: "open-session"; nodeId: string }
	| { tool: "send-message"; nodeId: string };

export type GestureContext = {
	hit: Hit;
	modifiers: ModifierSet;
	spaceHeld: boolean;
	activeTool: BuilderTool;
};

/** What a surface knows about a gesture apart from where the pointer is:
 *  the keys held now, whether Space is down, and which tool is active. It is
 *  {@link GestureContext} without the hit, so a host carrying one can answer
 *  for whatever hit the pointer finds. The App builds a single value and
 *  hands it to every host that draws a cursor. */
export type SurfaceGestureCtx = Omit<GestureContext, "hit">;

// ─────────────────────── Resolved gesture (§ 2.5) ──────────────────────

/** Modes the rubber-band drag commits in, latched at the resolver
 *  step (so the drag handler knows how to combine the rect's hits
 *  with the current multi-selection). */
export type RubberBandMode = SelectMode;

export type DefaultVerb =
	// Pointer-down verbs — resolved at pointer-down; drive both click
	// and drag effects. The FSM decides click vs drag from threshold.
	| { kind: "select-or-drag-peer"; peerId: string; entityRef: EntityRef }
	/** An unattributed end drags and selects exactly as a peer does; the verb
	 *  is separate so the handler knows which table holds its position. */
	| {
		kind: "select-or-drag-endpoint";
		endpointId: string;
		entityRef: EntityRef;
	}
	| { kind: "select-edge"; sessionId: string; entityRef: EntityRef }
	| { kind: "select-message"; messageId: string; entityRef: EntityRef }
	/** Sweep a rectangle and commit what it covers into the selection. Two
	 *  surfaces start one — the empty stage and an empty timeline lane — so the
	 *  verb names the gesture and the hit says where it happened. */
	| { kind: "rubber-band"; mode: RubberBandMode }
	| { kind: "scrub" }
	| { kind: "pan-view" } // overview drag
	/** `eventId` is null for a pill no observation names — see the hit's own
	 *  note in § 2.3's union above. */
	| {
		kind: "select-or-drag-event";
		eventId: string | null;
		entityRef: EntityRef;
	}
	| {
		kind: "drag-event-edge";
		eventId: string | null;
		entityRef: EntityRef;
	}
	| { kind: "toggle-category"; category: LaneCategory }
	| { kind: "toggle-row-visibility"; scope: VisibilityScope }
	| { kind: "reorder-row"; category: LaneCategory; entityId: string }
	/** Drag the gutter/plot seam sideways, widening or narrowing the gutter. */
	| { kind: "resize-gutter" }
	/** Drag one end of the overview's visible-window rect, widening or
	 *  narrowing the window the Scrubber shows. */
	| { kind: "resize-time-window"; edge: "start" | "end" };

/**
 * A tool that picks two nodes in turn: one click arms a node, the next names
 * its partner. One list, so a third such tool is added in one place — and
 * `isTwoClickTool` is its runtime reading, for the surfaces that hold a
 * `BuilderTool` and need to know which kind they have.
 */
export type TwoClickTool = "open-session" | "send-message";

export function isTwoClickTool(tool: BuilderTool): tool is TwoClickTool {
	return tool === "open-session" || tool === "send-message";
}

export type ToolCreateVerb =
	| { kind: "create-peer-at"; t: number }
	| {
		kind: "two-click-pick";
		tool: TwoClickTool;
		/** The stage node picked. A peer, or — for `send-message` — an end
		 *  nothing has attributed; the two share one node namespace.
		 *
		 *  First-pick vs second-pick disambiguated by the adapter via
		 *  `toolState` — when null this is the first pick; when non-
		 *  null with matching tool this is the second. */
		nodeId: string;
	};

export type ResolvedGesture =
	| { tier: "space-pan"; verb: { kind: "pan-surface" } }
	| { tier: "hand-tool"; verb: { kind: "pan-surface" } }
	| { tier: "tool-create"; verb: ToolCreateVerb }
	/** The active tool claims this surface and declines it — a stage node the
	 *  tool cannot use. It carries no verb because nothing happens: no ring
	 *  lights, no click acts, and the cursor says so before the click rather
	 *  than an error saying so after it.
	 *
	 *  Distinct from falling through to the surface default, which would let
	 *  the node be selected mid-gesture, and from a surface the tool simply has
	 *  no opinion about (empty stage, an edge), which keeps its ordinary
	 *  meaning. */
	| { tier: "tool-refuses" }
	| { tier: "default"; verb: DefaultVerb };

// ─────────────────────── Pointer FSM state (§ 2.6) ─────────────────────

export type FsmForeground =
	| { kind: "idle" }
	| {
		kind: "pressed";
		surface: SurfaceId;
		resolved: ResolvedGesture;
		start: PointerSnapshot;
		ctxAtDown: GestureContext;
	}
	| {
		kind: "dragging";
		surface: SurfaceId;
		resolved: ResolvedGesture;
		start: PointerSnapshot;
		current: PointerSnapshot;
	}
	| {
		kind: "paused-pan";
		/** Drag we'll resume when Space is released (if button is
		 *  still down at that time). */
		resume: {
			surface: SurfaceId;
			resolved: ResolvedGesture;
			start: PointerSnapshot;
		};
		panOrigin: PointerSnapshot;
		current: PointerSnapshot;
	};

export type PointerMachineState = {
	fsm: FsmForeground;
	/** Hover tracking — updated on every pointer-move regardless of
	 *  fsm. Read by cursor / status-hint derivations. */
	hover: { surface: SurfaceId; hit: Hit } | null;
};

export const IDLE_MACHINE: PointerMachineState = {
	fsm: { kind: "idle" },
	hover: null,
};

// ─────────────────────── Pointer events (§ 5.2) ────────────────────────

export type PointerEvent_ =
	| {
		kind: "pointer-down";
		surface: SurfaceId;
		snapshot: PointerSnapshot;
		ctx: GestureContext;
	}
	| {
		kind: "pointer-move";
		snapshot: PointerSnapshot;
		hit: Hit | null;
	}
	| {
		kind: "pointer-up";
		snapshot: PointerSnapshot;
		/** Up-time context; used to re-resolve the click verb if no
		 *  drag occurred (D — modifier-at-up wins for click). */
		ctxAtUp: GestureContext;
	}
	| { kind: "space-down" }
	| { kind: "space-up"; pointerHeld: boolean }
	| { kind: "cancel" };

// ─────────────────────── Effects (§ 5.4) ───────────────────────────────

export type Effect =
	| {
		kind: "click";
		verb: ResolvedGesture;
		hit: Hit;
		at: PointerSnapshot;
	}
	| { kind: "drag-start"; verb: ResolvedGesture; at: PointerSnapshot }
	| { kind: "drag-move"; verb: ResolvedGesture; at: PointerSnapshot }
	| { kind: "drag-end"; verb: ResolvedGesture; at: PointerSnapshot }
	| { kind: "drag-pause"; verb: ResolvedGesture; at: PointerSnapshot }
	| {
		kind: "drag-resume";
		verb: ResolvedGesture;
		carriedOrigin: PointerSnapshot;
	}
	| { kind: "drag-cancel"; verb: ResolvedGesture }
	| {
		kind: "pan-step";
		surface: SurfaceId;
		delta: { dx: number; dy: number };
	};

// ─────────────────────── FSM threshold (§ 2.6, § 5.3) ──────────────────

/** Manhattan-distance threshold for click-vs-drag. 4 px is the
 *  Figma / Adobe default. */
export const DRAG_THRESHOLD_PX = 4;
