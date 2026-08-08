/**
 * Gesture resolver — implements § 4 of the interaction model.
 *
 * Pure. Deterministic. Total (every `GestureContext` resolves to
 * exactly one `ResolvedGesture`). This is THE place where the
 * precedence ladder is encoded; no surface adapter or component
 * may resolve gestures inline.
 *
 * Called at TWO moments per gesture (§ 4.2):
 *   - At pointer-down — determines the in-flight verb.
 *   - At pointer-up if no drag occurred — re-resolves the click
 *     verb with the up-time modifier set (D — modifier-at-up
 *     wins for click; modifier-at-drag-start wins for drag).
 */

import {
  type BuilderTool,
  type DefaultVerb,
  type EntityKind,
  type EntityRef,
  type GestureContext,
  type Hit,
  isTwoClickTool,
  type ResolvedGesture,
  stageHitFor,
  type SurfaceId,
  type ToolCreateVerb,
} from "./types.ts";

// ─────────────────────── Resolver entrypoint (§ 4.2) ──────────────────

export function resolveGesture(ctx: GestureContext): ResolvedGesture {
  // 1. Space wins — Adobe convention, P1.
  if (ctx.spaceHeld) {
    return { tier: "space-pan", verb: { kind: "pan-surface" } };
  }
  // 2. Hand tool wins next (sticky Space, also P1).
  if (ctx.activeTool === "hand") {
    return { tier: "hand-tool", verb: { kind: "pan-surface" } };
  }
  // 3. Tool override (tier 3) — Add Peer / Open Session / Send
  //    Message intercept their target surfaces. Tool overrides
  //    DO NOT apply when any modifier is held (R4); modifier-
  //    augmented clicks always carry global meanings (P3).
  if (!anyModifier(ctx)) {
    const toolVerb = toolOverride(ctx);
    if (toolVerb !== null) return { tier: "tool-create", verb: toolVerb };
    // A two-click tool that did not take a stage NODE is declining it, not
    // ignoring it. Falling through here would hand the node its ordinary
    // select-or-drag meaning, so the tool would quietly do something else
    // instead of saying it cannot do this. Surfaces the tool has no opinion
    // about — empty stage, edges, the timeline — fall through as before.
    if (
      isStageNode(ctx.hit.surface) &&
      acceptsSurface(ctx.activeTool, ctx.hit.surface) === "refuses"
    ) {
      return { tier: "tool-refuses" };
    }
  }
  // 4. Surface default.
  const defaultVerb = surfaceDefault(ctx.hit);
  // 5. Resolution-time modifier overrides (§ 4.6a).
  if (ctx.modifiers.shift) {
    const swapped = modifiedShift(defaultVerb);
    if (swapped !== null) {
      return { tier: "modifier", modifier: "shift", verb: swapped };
    }
  }
  if (ctx.modifiers.cmd) {
    const swapped = modifiedCmd(defaultVerb);
    if (swapped !== null) {
      return { tier: "modifier", modifier: "cmd", verb: swapped };
    }
  }
  // Alt: no resolution-time swaps in v1; reserved for clone verbs.
  return { tier: "default", verb: defaultVerb };
}

function anyModifier(ctx: GestureContext): boolean {
  return ctx.modifiers.shift || ctx.modifiers.cmd || ctx.modifiers.alt;
}

/** The stage's two node surfaces. A peer and an end nothing has attributed
 *  occupy the same place on the stage and are picked the same way, so a tool
 *  that works on nodes has an opinion about both. */
function isStageNode(surface: SurfaceId): boolean {
  return surface === "stage-peer" || surface === "stage-endpoint";
}

/** The stage node kinds, which are the two surfaces above seen from the
 *  selection's side rather than the pointer's. */
export type NodeKind = "peer" | "endpoint";

/** A picked entity as a node, or `null` when what is picked is not one. The
 *  node-taking tools all ask this of a selection before doing anything with it,
 *  and `EntityRef` cannot answer it by narrowing: its `kind` is one field over
 *  every kind rather than a discriminant per case, so a check on the field
 *  narrows the field and leaves the ref as wide as it was. */
export function asNodeRef(
  ref: { kind: EntityKind; id: string } | null,
): { kind: NodeKind; id: string } | null {
  if (ref === null) return null;
  if (ref.kind !== "peer" && ref.kind !== "endpoint") return null;
  return { kind: ref.kind, id: ref.id };
}

/**
 * What a tool does with a node of this kind. THE statement of it, because
 * four surfaces need the same answer and they must not drift: the resolver
 * turns it into a pick or a refusal, the cursor draws it, the hover ring
 * obeys it, and the click path acts on it.
 *
 * That drift is what this replaces. The rule used to live in the resolver
 * for the cursor and the ring, and separately in the click path, which is
 * how a node could read not-allowed and still be armed by clicking it — the
 * picture and the act disagreeing about one question.
 *
 *   - `takes` — the tool picks this node.
 *   - `refuses` — the tool works on nodes and will not take this one. It
 *     says so under the pointer and does nothing at all on click.
 *   - `ignores` — the tool has no opinion, so the node keeps its ordinary
 *     meaning and can still be selected and dragged.
 */
export function toolAcceptsNode(
  tool: BuilderTool,
  kind: NodeKind,
): "takes" | "refuses" | "ignores" {
  switch (tool) {
    // A new session mints its own two ends, so an end that already belongs
    // to one has nothing to be here. See `advanceTwoClick` for why two
    // sessions must not share an end.
    case "open-session":
      return kind === "peer" ? "takes" : "refuses";
    // Either kind. A message can name an end nothing has attributed — that
    // is what the wire looks like before anything proves who answered.
    case "send-message":
      return "takes";
    // These do not pick nodes at all, so a node under them is untouched.
    case "select":
    case "hand":
    case "add-peer":
      return "ignores";
    default:
      return assertNever(tool);
  }
}

/** The same question the pointer asks, from a surface rather than a kind. */
function acceptsSurface(tool: BuilderTool, surface: SurfaceId) {
  return toolAcceptsNode(tool, surface === "stage-peer" ? "peer" : "endpoint");
}

/** The node a hit on a stage node names. The two surfaces carry the id under
 *  different field names, and this is the only place that has to know which. */
function nodeIdOfHit(hit: Hit): string | null {
  if (hit.surface === "stage-peer") return hit.peerId;
  if (hit.surface === "stage-endpoint") return hit.endpointId;
  return null;
}

// ─────────────────────── Tool override table (§ 4.4) ──────────────────

/**
 * The verb a tool intercepts this surface with, or null when it has none.
 *
 * Over a stage node the answer is `toolAcceptsNode`'s, turned into a verb:
 * `takes` picks the node, and `refuses` and `ignores` alike hand nothing back
 * — the caller tells those two apart by asking the same question again, and a
 * pick is the only thing this returns. Deriving it is the whole point of that
 * table: encoding the same rows here by hand is how a tool came to take a kind
 * of node in one place and not in the other, and the click then neither picked
 * nor refused it.
 *
 * `add-peer` is what is left over, and it is a different shape: it acts on
 * empty canvas rather than on a node, so it is stated here and nowhere else.
 */
function toolOverride(ctx: GestureContext): ToolCreateVerb | null {
  const tool = ctx.activeTool;
  if (tool === "add-peer") {
    if (ctx.hit.surface !== "stage-empty") return null;
    // `t` is "now" from the engine, supplied by the host adapter via a
    // separate effect routing — the verb itself doesn't carry it. (Adapter
    // consults clock.t when the tool-create effect lands.) We encode t=0 as a
    // sentinel; the adapter MUST override.
    return { kind: "create-peer-at", t: 0 };
  }
  if (!isTwoClickTool(tool)) return null;
  const nodeId = nodeIdOfHit(ctx.hit);
  if (nodeId === null) return null;
  if (acceptsSurface(tool, ctx.hit.surface) !== "takes") return null;
  return { kind: "two-click-pick", tool, nodeId };
}

// ─────────────────────── Surface default table (§ 4.5) ────────────────

export function surfaceDefault(hit: Hit): DefaultVerb {
  switch (hit.surface) {
    case "stage-empty":
      return { kind: "rubber-band", mode: "replace" };
    case "stage-peer":
      return {
        kind: "select-or-drag-peer",
        peerId: hit.peerId,
        entityRef: { kind: "peer", id: hit.peerId },
      };
    case "stage-endpoint":
      return {
        kind: "select-or-drag-endpoint",
        endpointId: hit.endpointId,
        entityRef: { kind: "endpoint", id: hit.endpointId },
      };
    case "stage-edge":
      return {
        kind: "select-edge",
        sessionId: hit.sessionId,
        entityRef: { kind: "session", id: hit.sessionId },
      };
    case "stage-message":
      return {
        kind: "select-message",
        messageId: hit.messageId,
        entityRef: { kind: "message", id: hit.messageId },
      };
    case "timeline-overview":
      return { kind: "pan-view" };
    case "timeline-overview-edge":
      return { kind: "resize-time-window", edge: hit.edge };
    case "timeline-ruler":
      return { kind: "scrub" };
    // The Scrubber's press on an empty lane sweeps a selection marquee —
    // the same gesture the empty stage starts, committed through the same
    // `SelectMode` grammar. The verb says so, so a modifier held over the
    // lane previews the selection edit the release will make.
    case "timeline-lane-empty":
      return { kind: "rubber-band", mode: "replace" };
    case "timeline-lane-event":
      return {
        kind: "select-or-drag-event",
        eventId: hit.eventId,
        entityRef: hit.entityRef,
      };
    case "timeline-lane-event-right-edge":
      return {
        kind: "drag-event-right-edge",
        eventId: hit.eventId,
        entityRef: hit.entityRef,
      };
    case "timeline-gutter-edge":
      return { kind: "resize-gutter" };
    case "timeline-gutter-chevron":
      return { kind: "toggle-category", category: hit.category };
    case "timeline-gutter-eyeball":
      return { kind: "toggle-row-visibility", scope: hit.scope };
    case "timeline-gutter-label":
      return {
        kind: "reorder-row",
        category: hit.category,
        entityId: hit.entityId,
      };
    default:
      return assertNever(hit);
  }
}

// ─────────────────────── Modifier overrides (§ 4.6a) ──────────────────

function modifiedShift(verb: DefaultVerb): DefaultVerb | null {
  switch (verb.kind) {
    case "select-or-drag-peer":
    case "select-or-drag-endpoint":
    case "select-edge":
    case "select-message":
    case "select-or-drag-event":
      return { kind: "extend-selection-range", toEntity: verb.entityRef };
    case "rubber-band":
      return { kind: "rubber-band", mode: "add" };
    default:
      return null;
  }
}

function modifiedCmd(verb: DefaultVerb): DefaultVerb | null {
  switch (verb.kind) {
    case "select-or-drag-peer":
    case "select-or-drag-endpoint":
    case "select-edge":
    case "select-message":
    case "select-or-drag-event":
      return { kind: "toggle-in-selection", entity: verb.entityRef };
    case "rubber-band":
      return { kind: "rubber-band", mode: "toggle" };
    default:
      return null;
  }
}

// ─────────────────────── Exhaustiveness helper ────────────────────────

function assertNever(x: never): never {
  throw new Error(`unhandled discriminant: ${JSON.stringify(x)}`);
}

// ─────────────────────── Helpers for tests / adapters ─────────────────

/** All surface ids — used by exhaustive-switch totality tests. */
export const ALL_SURFACES: ReadonlySet<SurfaceId> = new Set<SurfaceId>([
  "stage-empty",
  "stage-peer",
  "stage-endpoint",
  "stage-edge",
  "stage-message",
  "timeline-overview",
  "timeline-overview-edge",
  "timeline-ruler",
  "timeline-lane-empty",
  "timeline-lane-event",
  "timeline-lane-event-right-edge",
  "timeline-gutter-edge",
  "timeline-gutter-chevron",
  "timeline-gutter-eyeball",
  "timeline-gutter-label",
]);

/** All tools — used by exhaustive-switch totality tests. */
export const ALL_TOOLS: readonly BuilderTool[] = [
  "select",
  "hand",
  "add-peer",
  "open-session",
  "send-message",
];

/** Construct a minimal valid `Hit` for a given surface id. Test
 *  helper — production code uses surface-specific hit-testers. */
export function dummyHit(
  surface: SurfaceId,
  refs?: {
    peerId?: string;
    endpointId?: string;
    sessionId?: string;
    messageId?: string;
    eventId?: string;
    entityId?: string;
    t?: number;
    category?: "peers" | "sessions" | "messages";
  },
): Hit {
  const peerRef: EntityRef = { kind: "peer", id: refs?.peerId ?? "p1" };
  const sessRef: EntityRef = {
    kind: "session",
    id: refs?.sessionId ?? "s1",
  };
  const msgRef: EntityRef = {
    kind: "message",
    id: refs?.messageId ?? "m1",
  };
  switch (surface) {
    case "stage-empty":
      return { surface: "stage-empty" };
    // Through `stageHitFor`, so a helper that fabricates hits for the resolver's
    // own tests cannot fabricate a shape the Stage never produces.
    case "stage-peer":
      return stageHitFor(peerRef);
    case "stage-endpoint":
      return stageHitFor({
        kind: "endpoint",
        id: refs?.endpointId ?? "s1::b",
      });
    case "stage-edge":
      return stageHitFor(sessRef);
    case "stage-message":
      return stageHitFor(msgRef);
    case "timeline-overview":
      return { surface: "timeline-overview", t: refs?.t ?? 0 };
    case "timeline-overview-edge":
      return {
        surface: "timeline-overview-edge",
        edge: "start",
        t: refs?.t ?? 0,
      };
    case "timeline-ruler":
      return { surface: "timeline-ruler", t: refs?.t ?? 0 };
    case "timeline-lane-empty":
      return { surface: "timeline-lane-empty", t: refs?.t ?? 0 };
    case "timeline-lane-event":
      return {
        surface: "timeline-lane-event",
        eventId: refs?.eventId ?? "e1",
        entityRef: peerRef,
      };
    case "timeline-lane-event-right-edge":
      return {
        surface: "timeline-lane-event-right-edge",
        eventId: refs?.eventId ?? "e1",
        entityRef: msgRef,
      };
    case "timeline-gutter-edge":
      return { surface: "timeline-gutter-edge" };
    case "timeline-gutter-chevron":
      return {
        surface: "timeline-gutter-chevron",
        category: refs?.category ?? "peers",
      };
    case "timeline-gutter-eyeball":
      return {
        surface: "timeline-gutter-eyeball",
        scope: {
          kind: "row",
          category: refs?.category ?? "peers",
          entityId: refs?.entityId ?? peerRef.id,
        },
      };
    case "timeline-gutter-label":
      return {
        surface: "timeline-gutter-label",
        category: refs?.category ?? "peers",
        entityId: refs?.entityId ?? peerRef.id,
      };
    default:
      return assertNever(surface);
  }
}
