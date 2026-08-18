/**
 * Scrubber press and teardown: what pointer-down arms, and what
 * release (or a lost capture) commits.
 *
 * Move/hover live in `move.ts`. The React hook in
 * `use-scrubber-pointers.ts` holds the lease and the live host
 * object these functions read.
 */

import type { PointerEvent } from "react";
import { entityKey } from "../../../interactions/types.ts";
import { type SelectMode, selectModeFromModifiers } from "../../../render/types.ts";
import { clampRectToBounds, rectFromCorners } from "../../../render/geometry.ts";
import { iterateRows, LANE_GAP, RULER_HEIGHT, scrubberPlotBounds } from "../row-layout.ts";
import { canvasPxToT, gutterWidthOf } from "../state.ts";
import { entitiesInRect, GUTTER_DRAG_GRAB_PX, hitTestGutter } from "../hit-test.ts";
import { hitTestEvents } from "../event-hit.ts";
import { eventIdOfPlan } from "../scrubber-drag.ts";
import type { ScrubberPointerHost } from "./types.ts";

export function onScrubberPointerDown(
  h: ScrubberPointerHost,
  e: PointerEvent<HTMLDivElement>,
): void {
  const {
    surface,
    dragRef,
    inFlightRef,
    view,
    expandedLanes,
    expandedCategories,
    orderedEntities,
    rowHidden,
    laneHeight,
    scrollYRef,
    toggleCategory,
    cycleCategoryVisibility,
    cycleRowVisibility,
    hoverTRef,
    events,
    doc,
    onSelectEvent,
    onMoveEvent,
    selectionSetRef,
    disabledScrub,
    onScrubStart,
    onSeek,
  } = h;
  if (e.button !== 0) return; // left mouse only
  // Cross-surface lock — bail if another surface (e.g. Stage)
  // owns the gesture. The root guard normally suppresses this
  // event before it reaches us, but defending here costs
  // nothing and keeps invariants honest under tests.
  if (!surface.claim(e.currentTarget, e.pointerId)) return;
  e.preventDefault();
  e.currentTarget.setPointerCapture(e.pointerId);
  const rect = e.currentTarget.getBoundingClientRect();
  const px = e.clientX - rect.left;
  const py = e.clientY - rect.top;

  const gutter = gutterWidthOf(view);

  // 0) Gutter-edge drag handle: a few pixels straddling the
  // gutter's right edge resize the gutter live. Pre-empts
  // everything below — the user explicitly grabbed the seam.
  if (Math.abs(px - gutter) <= GUTTER_DRAG_GRAB_PX) {
    dragRef.current = {
      kind: "gutter-resize",
      startClientX: e.clientX,
      startGutterWidth: gutter,
    };
    inFlightRef.current = {
      surface: "timeline-gutter-edge",
      verb: { kind: "resize-gutter" },
    };
    return;
  }

  // Walk the same row stack the renderer paints. Shared by the
  // gutter hit-test and the event hit-test below (both must agree
  // with the painter's row geometry). Add `scrollY` to `py` at
  // each call so hits land on the unscrolled row coords.
  const rows = [...iterateRows(
    expandedLanes,
    expandedCategories,
    orderedEntities,
    rowHidden,
    laneHeight,
  )];
  // 1) Gutter check first (px < gutterWidth). The chevron /
  // eyeball / row-drag gestures all live in the gutter; they
  // pre-empt event hit-tests and the scrub / pan branches below.
  if (px < gutter) {
    const gutterHit = hitTestGutter(
      px,
      py + scrollYRef.current,
      rows,
      gutter,
    );
    if (gutterHit?.kind === "chevron") {
      toggleCategory?.(gutterHit.category);
      return;
    }
    if (gutterHit?.kind === "category-eyeball") {
      cycleCategoryVisibility?.(gutterHit.category);
      return;
    }
    if (gutterHit?.kind === "eyeball") {
      cycleRowVisibility?.(gutterHit.category, gutterHit.entityId);
      return;
    }
    if (gutterHit?.kind === "row-drag") {
      // The order of THIS category — captured at drag-start
      // so a mid-drag prop change doesn't drift the math.
      const startOrder = [...orderedEntities[gutterHit.category]];
      const startIndex = startOrder.indexOf(gutterHit.entityId);
      if (startIndex === -1) return;
      dragRef.current = {
        kind: "row-drag",
        category: gutterHit.category,
        entityId: gutterHit.entityId,
        startIndex,
        startOrder,
        startClientY: e.clientY,
        rowPitchPx: gutterHit.rowHeight + LANE_GAP,
        moved: false,
        finalIndex: startIndex,
      };
      inFlightRef.current = {
        surface: "timeline-gutter-label",
        verb: {
          kind: "reorder-row",
          category: gutterHit.category,
          entityId: gutterHit.entityId,
        },
      };
      return;
    }
    // Gutter click but not on a control → no-op (don't
    // treat as scrub; that would seek to t=null).
    return;
  }

  const t = canvasPxToT(px, rect.width, view);
  if (t === null) return; // shouldn't happen post-gutter check, defensive
  hoverTRef.current = null;
  // Entity hit-test wins over EVERY non-gutter branch — pan, scrub,
  // rubber-band all only fire if the pointer didn't land on a pill.
  // Routing this first means shift/alt/cmd-click on a pill always
  // reach the selection-mode resolution below; they no longer get
  // hijacked into pan (which broke shift-to-add) or scrub.
  const hit = hitTestEvents(
    px,
    py,
    rect.width,
    rect.height,
    view,
    events,
    rows,
    doc,
    scrollYRef.current,
  );
  if (hit && (onSelectEvent || onMoveEvent)) {
    // Gate drag-to-move on prior selection for body translates.
    // Clicking an unselected entity is a select-only intent: the
    // gesture captures the hit so endDrag can dispatch the select
    // on release, but the move handler ignores displacement so an
    // unselected pill body cannot translate. The user must click a
    // second time once the entity is selected to drag — matches
    // the "select then act" convention used across the Inspector
    // and Stage halo. Add/remove/toggle gestures skip this gate: a
    // modifier-click is unambiguously a selection-set edit, not a
    // drag intent, so it doesn't need to wait for a prior
    // single-select.
    const hitEntityKey = entityKey(hit.entity);
    // One selection grammar across surfaces: the stage's
    // modifier map (shift = add, shift+option = remove).
    const selectMode: SelectMode = selectModeFromModifiers(e);
    // `drag === null` = no observation event to retime. The
    // gesture must remain select-only regardless of selection
    // state, otherwise the move handler would have no plan.
    // Precise hotspots bypass the "click first to select" gate
    // so a user can grab a 6px edge or diamond and start retiming
    // in one motion (and discover the affordance via the cursor
    // without first having to click). Modifier gestures stay
    // select-only: a modifier-click is a selection-set edit, not
    // authoring.
    const isDirectActPlan = hit.drag?.kind === "span-edge" ||
      hit.drag?.kind === "entity-span-edge" ||
      hit.drag?.kind === "message-edge" ||
      hit.drag?.kind === "moment";
    const selectOnly = hit.drag === null ||
      selectMode !== "replace" ||
      (!isDirectActPlan && !selectionSetRef.current.has(hitEntityKey));
    dragRef.current = {
      kind: "event",
      hit,
      startClientX: e.clientX,
      moved: false,
      txOpen: false,
      selectMode,
      selectOnly,
    };
    // A select-only press moves nothing, so it names no gesture: the
    // pill's own cursor stays the honest answer until the release.
    inFlightRef.current = selectOnly ? null : {
      surface: isDirectActPlan && hit.drag?.kind !== "moment"
        ? "timeline-lane-event-right-edge"
        : "timeline-lane-event",
      verb: isDirectActPlan && hit.drag?.kind !== "moment"
        ? {
          kind: "drag-event-right-edge",
          eventId: eventIdOfPlan(hit),
          entityRef: hit.entity,
        }
        : {
          kind: "select-or-drag-event",
          eventId: eventIdOfPlan(hit),
          entityRef: hit.entity,
        },
    };
    return;
  }
  // No entity under the pointer. Alt alone = pan the whole
  // strip (time + lane scroll); a shifted gesture falls through
  // to the rubber-band branch, where the stage's modifier map
  // decides the commit (shift = add, shift+option = remove).
  // Pan losing the bare-shift modifier is the price of giving
  // shift back to "add to selection" — alt alone is the
  // timeline's pan key.
  if (e.altKey && !e.shiftKey) {
    dragRef.current = {
      kind: "pan",
      lastClientX: e.clientX,
      lastClientY: e.clientY,
    };
    inFlightRef.current = {
      surface: "timeline-lane-empty",
      verb: { kind: "pan-view" },
    };
    return;
  }
  // Empty area branch. Scrub zone = ruler band PLUS the empty
  // space between the bottom of the last entity row and the
  // top of the ruler — same idea the user described as
  // "expand the ruler container as high as it can go". Lane
  // area (where rows actually paint) keeps the rubber-band
  // gesture. With this split, the dead vertical gap left by
  // the panel auto-grow becomes a useful playhead-scrub
  // strip instead of a marquee start that always selects
  // nothing.
  // `lanesBottomY` is the painted (scrolled) bottom of the
  // last row — `py` is in painted coords too, so subtract
  // `scrollY` once here instead of adding to py everywhere.
  const lanesBottomY = (rows.length > 0
    ? rows[rows.length - 1]!.y +
      rows[rows.length - 1]!.height
    : 0) - scrollYRef.current;
  const rulerTopY = rect.height - RULER_HEIGHT;
  const inScrubZone = py >= rulerTopY || py >= lanesBottomY;
  if (inScrubZone) {
    // Live mode (`disabledScrub`) bails the scrub gesture
    // entirely — clicking the ruler or the empty zone below
    // the rows does nothing instead of trying to seek a
    // forward-only feed. Wheel zoom / pan still work
    // (separate native listener), and the rubber-band
    // gesture below this branch isn't reached because the
    // inScrubZone short-circuit ran.
    if (disabledScrub) return;
    dragRef.current = { kind: "scrub", lastClientX: e.clientX };
    inFlightRef.current = {
      surface: "timeline-ruler",
      verb: { kind: "scrub" },
    };
    onScrubStart();
    onSeek(t);
    return;
  }
  // Rubber-band. Sub-threshold release is treated as
  // "clear selection" (matching today's empty-area click
  // behavior at the App level).
  const mode = selectModeFromModifiers(e);
  dragRef.current = {
    kind: "rubber-band",
    startClientX: e.clientX,
    startClientY: e.clientY,
    currentClientX: e.clientX,
    currentClientY: e.clientY,
    mode,
    moved: false,
  };
  // The empty lane's own default verb (§ 4.5) — the same marquee the
  // empty stage sweeps, carrying the mode this drag latched, so the
  // cursor names the gesture this handler is actually running.
  inFlightRef.current = {
    surface: "timeline-lane-empty",
    verb: { kind: "rubber-band", mode },
  };
}

export function endScrubberDrag(h: ScrubberPointerHost): void {
  const {
    surface,
    inFlightRef,
    dragRef,
    onScrubEnd,
    endEdit,
    onEditSelection,
    onSelectEvent,
    onFocusEvent,
    snapLineRef,
    commitRowReorder,
    rubberBandRef,
    hostRef,
    propsRef,
    regionSizeRef,
    scrollYRef,
    orderedEntities,
  } = h;
  // Always release the gesture-router lock first — pointerdown
  // may have claimed without ever setting `dragRef` (e.g.
  // pointer landed on a non-actionable region). Releasing
  // before the early-return keeps the lock honest.
  surface.release();
  inFlightRef.current = null;
  const drag = dragRef.current;
  if (!drag) return;
  if (drag.kind === "scrub") onScrubEnd();
  if (drag.kind === "event") {
    // No movement = treat as click. Modifier-resolved selectMode
    // steers the click into one of four selection-set edits.
    // Plain "replace" also sets the single selection (Inspector
    // follow); the other three only edit the multi-set so the
    // user can grow / shrink it without losing single-select
    // focus elsewhere.
    if (drag.txOpen) endEdit?.();
    else {
      const key = entityKey(drag.hit.entity);
      // The mode's set arithmetic lives in `selectionActionFor`;
      // this surface only forwards the hit. The replace arm keeps
      // its surface extras: Inspector follow, and sub-selection
      // focus (#16) — a glyph (moment) hit parks focus on the
      // keyframe, body / edge hits reset it.
      onEditSelection(new Set([key]), drag.selectMode);
      if (drag.selectMode === "replace") {
        onSelectEvent?.(drag.hit.entity);
        if (onFocusEvent) {
          const plan = drag.hit.drag;
          onFocusEvent(plan?.kind === "moment" ? plan.eventId : null);
        }
      }
    }
    snapLineRef.current = null;
  }
  if (drag.kind === "row-drag") {
    if (drag.moved) {
      // Commit the reorder. Empty-or-noop is filtered at the
      // engine layer via `isNoOpIntent`.
      const next = [...drag.startOrder];
      const from = drag.startIndex;
      const to = Math.max(0, Math.min(next.length - 1, drag.finalIndex));
      if (from !== to) {
        const [moved] = next.splice(from, 1);
        if (moved !== undefined) next.splice(to, 0, moved);
        commitRowReorder?.(drag.category, next);
      }
    } else {
      // Tap-to-select on the entity row label — the previously
      // dead spot in the gutter. Picks the parent entity so the
      // click has a visible effect (Inspector follows + stage
      // halo lights up) and matches what clicking the entity
      // anywhere else does.
      const kind = drag.category === "peers" ? "peer" : drag.category === "sessions" ? "session" : "message";
      onSelectEvent?.({ kind, id: drag.entityId });
    }
  }
  if (drag.kind === "rubber-band") {
    rubberBandRef.current = null;
    if (!drag.moved) {
      // Click-no-drag on empty plot: the interpreter owns the
      // semantics (plain click clears with timeline empty-space
      // rules; a modifier click preserves the selection).
      onEditSelection(new Set(), drag.mode);
      if (drag.mode === "replace") {
        onSelectEvent?.(null);
        onFocusEvent?.(null);
      }
    } else {
      // Commit: every event whose pill intersects the rect
      // contributes its OWNING ENTITY's ref to the selection.
      // Pair-ends naturally fold into one ref (peer-joined and
      // peer-left both map to the same {kind:"peer", id}), so
      // a band that sweeps a span lights up the entity once,
      // not twice.
      const host = hostRef.current;
      if (host) {
        const hostRect = host.getBoundingClientRect();
        // Clamp to the SAME plot bounds the paint loop uses
        // (`scrubberPlotBounds`) so the committed selection rect
        // is pixel-identical to the marching-ants band the user
        // saw — gutter, left pad, right pad, and ruler are all
        // dead zone for the marquee. Then shift y by `scrollY` so
        // the rect lands in unscrolled row coords (rows from
        // `iterateRows` are unscrolled).
        const view = propsRef.current.view;
        // Bounds use the SAME rounded region size the paint loop
        // clamped the visible marching-ants band to (written into
        // `regionSizeRef` by `handleRegionRect`). Reading from
        // `hostRect.width/height` directly would drift by ≤1 px on
        // fractional DPR, silently letting the committed rect
        // include or exclude pills the user couldn't see lit up.
        const region = regionSizeRef.current;
        const bounds = scrubberPlotBounds(view, region.width, region.height);
        const raw = rectFromCorners(
          drag.startClientX - hostRect.left,
          drag.startClientY - hostRect.top,
          drag.currentClientX - hostRect.left,
          drag.currentClientY - hostRect.top,
        );
        const clamped = clampRectToBounds(raw, bounds);
        const sy = scrollYRef.current;
        const rect = {
          x: clamped.x,
          y: clamped.y + sy,
          width: clamped.width,
          height: clamped.height,
        };
        const rows = [...iterateRows(
          propsRef.current.expandedLanes,
          propsRef.current.expandedCategories,
          orderedEntities,
          propsRef.current.rowHidden,
          propsRef.current.laneHeight,
        )];
        const entityHits = entitiesInRect(
          rect,
          propsRef.current.doc,
          propsRef.current.events,
          propsRef.current.view,
          region.width,
          rows,
        );
        onEditSelection(entityHits, drag.mode);
      }
    }
  }
  dragRef.current = null;
}

export function onScrubberPointerUp(
  h: ScrubberPointerHost,
  e: PointerEvent<HTMLDivElement>,
): void {
  try {
    e.currentTarget.releasePointerCapture(e.pointerId);
  } catch {
    // capture may already be released
  }
  endScrubberDrag(h);
}
