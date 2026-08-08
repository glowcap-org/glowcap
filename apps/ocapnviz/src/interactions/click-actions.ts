/**
 * Click action map — implements § 4.7 of the interaction model.
 *
 * The pointer FSM emits a `click(verb)` effect for no-drag pointer-ups,
 * and this pure helper says what that verb means as a semantic action.
 *
 * Nothing calls it yet. `Stage.tsx` and `Timeline/Scrubber.tsx` each
 * handle their own click at the end of a drag, so the mapping this
 * module exists to hold in one place is currently spelled twice, out
 * there. Wiring both surfaces through here is the point of it, and
 * this paragraph goes when they are.
 *
 * Until then, treat a disagreement with the live path as a defect in
 * this file rather than evidence about the app: `clickActionForDefault`
 * answers a `rubber-band` with `clear-on-empty-click` whatever its
 * mode, where the live `selectionActionFor` returns null for `add` and
 * `remove`. Tested table-style against every verb kind.
 */

import {
  type DefaultVerb,
  entityKey,
  type EntityRef,
  type Hit,
  hitEntityRef,
  type LaneCategory,
  type ResolvedGesture,
  type SelectionAction,
  type SelectionDocSnapshot,
  type VisibilityScope,
} from "./types.ts";

// ─────────────────────── ClickAction type ─────────────────────────────

/** What a no-drag click commits to. Adapters switch on `kind` and
 *  route to the appropriate sink (selection store, view dispatcher,
 *  engine, view setter). Returning `null` means "click has no
 *  effect on this verb" (e.g., drag-only handles). */
export type ClickAction =
  | { kind: "selection"; action: SelectionAction }
  | { kind: "seek"; t: number }
  | { kind: "jump-window-center"; t: number }
  | { kind: "toggle-category"; category: LaneCategory }
  | { kind: "toggle-row-visibility"; scope: VisibilityScope }
  | { kind: "drill-in"; entity: EntityRef };

// ─────────────────────── Mapping helper ───────────────────────────────

/** Map a resolved `click` effect's verb + hit to a `ClickAction`.
 *  Pure. Returns null for verbs that have no click meaning.
 *  `doc` is required only for actions that need to project the
 *  document into the selection set (extend-selection-range); pass
 *  an empty doc when the verb is known not to need it. */
export function clickActionFor(
  verb: ResolvedGesture,
  hit: Hit,
  doc: SelectionDocSnapshot,
): ClickAction | null {
  // tier=space-pan / hand-tool never produce click effects in
  // practice (the FSM only emits `click` from `pressed`, and
  // pressed-with-pan-verb is suppressed at the FSM level — but
  // be defensive).
  if (verb.tier === "space-pan" || verb.tier === "hand-tool") return null;
  if (verb.tier === "tool-create") {
    // Tool-create verbs are handled directly by the host adapter
    // (advancing toolState, dispatching engine intents). They do
    // NOT pass through clickActionFor.
    return null;
  }
  // The active tool declined this node, so the click does nothing at all —
  // not even select it. Selecting it would be the tool quietly doing
  // something other than what it is for, which is what the refusal exists to
  // avoid; the cursor already said so on the way in.
  if (verb.tier === "tool-refuses") return null;
  return clickActionForDefault(verb.verb, hit, doc);
}

function clickActionForDefault(
  verb: DefaultVerb,
  hit: Hit,
  doc: SelectionDocSnapshot,
): ClickAction | null {
  switch (verb.kind) {
    case "rubber-band":
      // A marquee that never swept is an empty-space click, and it clears.
      // Each surface clears its own way — the stage keeps the time range,
      // the timeline drops it — so the hit says which one swept.
      return {
        kind: "selection",
        action: {
          kind: "clear-on-empty-click",
          surface: emptySurfaceOf(hit),
        },
      };
    case "select-or-drag-peer":
    case "select-or-drag-endpoint":
    case "select-edge":
    case "select-message":
      return {
        kind: "selection",
        action: {
          kind: "set-selection",
          entities: new Set([entityKey(verb.entityRef)]),
        },
      };
    case "select-or-drag-event":
      return {
        kind: "selection",
        action: {
          kind: "set-selection",
          entities: new Set([entityKey(verb.entityRef)]),
        },
      };
    case "drag-event-right-edge":
      return null;
    case "scrub": {
      if (hit.surface !== "timeline-ruler") return null;
      return { kind: "seek", t: hit.t };
    }
    case "pan-view": {
      // Overview no-drag click → jump window center to that t.
      if (hit.surface !== "timeline-overview") return null;
      return { kind: "jump-window-center", t: hit.t };
    }
    case "toggle-in-selection":
      return {
        kind: "selection",
        action: { kind: "toggle-in-selection", entity: verb.entity },
      };
    case "extend-selection-range":
      return {
        kind: "selection",
        action: {
          kind: "extend-selection-range",
          toEntity: verb.toEntity,
          doc,
        },
      };
    case "toggle-category":
      return { kind: "toggle-category", category: verb.category };
    case "toggle-row-visibility":
      return { kind: "toggle-row-visibility", scope: verb.scope };
    case "reorder-row":
      // Drag-only. No-drag click is no-op.
      return null;
    case "resize-gutter":
    case "resize-time-window":
      // Drag-only handles. A click that never moved changes nothing.
      return null;
    default:
      return assertNever(verb);
  }
}

/** Whose empty-space rules a marquee's click follows. Two surfaces resolve to
 *  `rubber-band` — the empty stage and an empty timeline lane — and the
 *  timeline is the one that also drops the time range. */
function emptySurfaceOf(hit: Hit): "stage" | "timeline" {
  return hit.surface === "timeline-lane-empty" ? "timeline" : "stage";
}

function assertNever(x: never): never {
  throw new Error(`unhandled discriminant: ${JSON.stringify(x)}`);
}

// ─────────────────────── Double-click → drill-in helper ───────────────

/** Translate a `double-click` FSM effect's `entity` into a
 *  `drill-in` click action. Provided here for symmetry — the host
 *  doesn't have to know that double-click maps to drill-in. */
export function drillInActionFor(entity: EntityRef): ClickAction {
  return { kind: "drill-in", entity };
}

/** Used by adapters that prefer to compute drill-in from a hit
 *  (e.g., when wiring native dblclick listeners on non-FSM surfaces). */
export function drillInFromHit(hit: Hit): ClickAction | null {
  const entity = hitEntityRef(hit);
  return entity ? drillInActionFor(entity) : null;
}
