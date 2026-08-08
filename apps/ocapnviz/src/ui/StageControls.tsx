/**
 * Stage camera controls — the scale, and the four ways to change it.
 *
 * Bottom-right of the stage, which is where every tool that has a canvas and a
 * zoom puts them. The readout is a button rather than a label because the thing
 * a reader wants after reading "38%" is to be back at 100%, and making the
 * number itself the way there saves them hunting for a control that says so.
 *
 * Five cells, in the order they are reached for: out, the scale, in, back to the
 * start, and Fit.
 *
 * The scale is a FIELD, not a readout. It is the one number on screen a reader
 * might want to state exactly — "show me this at 200%" — and every other way of
 * offering that is a second control saying what this one already says. It is also
 * the app's ordinary numeric field, so it drags and takes a wheel like every other
 * number here; `ZoomField` below says why that matters more than it looks.
 *
 * Both buttons can go grey, because the scale has two ends (`render/stage-view.ts`
 * argues each). A button that cannot move should not look like it can.
 *
 * Home is the middle of the world at 1:1, and an icon rather than a number because
 * it is a place: a second percentage beside the scale field would read as a second
 * scale. It is not "back to where this document opens" — that is the document
 * panel's business, since the document's opening view is a field a reader sets
 * there rather than something the camera keeps in step (`ui/DocumentFields.tsx`).
 */

import { useSyncExternalStore } from "react";
import { stageCamera } from "../render/stage-camera.ts";
import {
  DEFAULT_STAGE_VIEW,
  formatStageZoom,
  MAX_STAGE_SCALE,
  MIN_STAGE_SCALE,
  parseStageZoom,
} from "../render/stage-view.ts";
import { FitGlyph, RecenterGlyph } from "./glyphs.tsx";
import { ScrubInput } from "./Timeline/ScrubInput.tsx";
import {
  RADIUS,
  SEGMENT_CELL,
  segmentCellClass,
  SIZE,
  SPACE,
} from "./tokens.ts";

/**
 * Keep the keyboard on the stage when one of these is clicked.
 *
 * A mouse click focuses the button it lands on, and the reader's next act here is
 * to go back to the canvas — the working loop is zoom, pan, zoom. Space over the
 * stage is the pan, and pressing any key while a button holds focus is what turns
 * a plain `:focus` into `:focus-visible`, so the button lights up a ring for a
 * keystroke that was aimed at the picture. Refusing the default on pointerdown
 * means the focus never lands here in the first place.
 *
 * Only the mouse is refused. Tabbing to these still focuses them and still draws
 * the ring, which is the one case the ring is for. The same wart is reachable on
 * any button in the app — click the topbar and press space — and the general
 * version of this belongs at whatever ends up owning `.ocv-btn`; the stage
 * controls carry it here because they are the ones a reader clicks between pans.
 *
 * No test holds this. The suite calls components as the plain functions they are
 * and this one has a hook, so there is nothing here that renders a DOM to ask
 * where focus went. It was checked in a browser instead: a click leaves focus on
 * the body and still zooms, and a tab still focuses the button and still rings.
 */
const keepKeyboardOnStage = (event: React.PointerEvent) => {
  event.preventDefault();
};

export function StageControls() {
  const readout = useSyncExternalStore(
    stageCamera.subscribe,
    stageCamera.getReadout,
    stageCamera.getReadout,
  );
  return (
    <div
      style={bar}
      className="ocv-segment ocv-stage-controls"
      role="group"
      aria-label="Stage zoom"
    >
      <button
        type="button"
        className={segmentCellClass(false)}
        onPointerDown={keepKeyboardOnStage}
        onClick={() => stageCamera.send({ kind: "zoom-out" })}
        disabled={!readout.canZoomOut}
        title="Zoom out"
        aria-label="Zoom out"
      >
        &minus;
      </button>
      <ZoomField />
      <button
        type="button"
        className={segmentCellClass(false)}
        onPointerDown={keepKeyboardOnStage}
        onClick={() => stageCamera.send({ kind: "zoom-in" })}
        disabled={!readout.canZoomIn}
        title="Zoom in"
        aria-label="Zoom in"
      >
        +
      </button>
      <button
        type="button"
        className={segmentCellClass(false)}
        onPointerDown={keepKeyboardOnStage}
        onClick={() => stageCamera.send({ kind: "home" })}
        title="Back to 100%"
        aria-label="Back to 100%"
      >
        <RecenterGlyph />
      </button>
      <button
        type="button"
        className={segmentCellClass(false)}
        onPointerDown={keepKeyboardOnStage}
        onClick={() => stageCamera.send({ kind: "fit" })}
        title="Fit everything on the stage in view"
        aria-label="Fit everything in view"
      >
        <FitGlyph />
      </button>
    </div>
  );
}

/**
 * The scale, as a value a reader can read, drag, wheel and type.
 *
 * It is a `ScrubInput` — the app's numeric field — rather than a second numeric
 * field written here. Every number in this app is scrubbed the same way: press and
 * drag to change it live, wheel over it for the same thing, click without dragging
 * to type an exact one, double-click to put it back. A control that looked like the
 * others and answered only to typing would be the one number in the app that does
 * not, and a reader has no way to tell which it is until they try.
 *
 * Being a cell of a segmented row is the other half, and the two are separate
 * modifiers on one field family: `is-numeric` is what it does, `is-segment` is
 * where it sits. So it keeps the row's seam, height and focus mark, and takes the
 * row's own type rather than the numeric pill's mono — `style` overrides after the
 * component's own, which is what that prop is for.
 *
 * The camera is the value. `readView` is read at the moment a gesture starts, so a
 * drag multiplies from the true scale; the camera's store only decides when to
 * re-render, and `formatStageZoom` is what both it and this show.
 *
 * Zoom is logarithmic, which is why nothing here says `linear`: a step of "twice as
 * close" means the same thing at 20% as at 400%, where a step of "plus ten percent"
 * does not.
 */
function ZoomField() {
  return (
    <ScrubInput
      value={readStageZoom}
      onChange={(zoom) => stageCamera.send({ kind: "zoom-to", zoom })}
      min={MIN_STAGE_SCALE}
      max={MAX_STAGE_SCALE}
      format={formatStageZoom}
      // What is shown is what is edited, and `parseStageZoom` takes the percent
      // sign back — a reader who selects the value and retypes it usually types it.
      formatInput={formatStageZoom}
      parse={parseStageZoom}
      defaultValue={DEFAULT_STAGE_VIEW.zoom}
      label="Stage zoom"
      className={SEGMENT_CELL}
      style={zoomCell}
    />
  );
}

/** The camera's live scale, or 1:1 when there is no stage attached to ask. Named
 *  rather than inline so the identity is stable across renders. */
function readStageZoom(): number {
  return stageCamera.readView()?.zoom ?? DEFAULT_STAGE_VIEW.zoom;
}

const bar = {
  position: "absolute",
  right: SPACE.md,
  bottom: SPACE.md,
  zIndex: 2,
  // The stage slot is pointer-events: none so clicks reach the canvas; these
  // are controls, so they take them back.
  pointerEvents: "auto",
  // Rounded for the shadow's sake, because the cells round their own outer ends
  // and a square shadow behind them would show at the corners. Deliberately NOT
  // clipped: `.ocv-btn` draws its focus mark as an outline OUTSIDE the box, so
  // `overflow: hidden` here cropped the ring down to the one edge that fell
  // inside the container, which read as a stray line between two buttons.
  borderRadius: RADIUS.md,
  boxShadow: "0 2px 8px rgba(0,0,0,0.08)",
} satisfies React.CSSProperties;

/** The zoom cell is the only one that changes width as it counts, and a bar that
 *  resized itself while a reader zoomed would move the buttons out from under the
 *  pointer. Wide enough for the longest reading either bound can produce, `9999%`
 *  and `1.0%`, and centered because it reads as a value rather than as text someone
 *  is composing.
 *
 *  The type is the row's, not the numeric pill's. `ScrubInput` is mono at one notch
 *  down because it usually sits in a dense key/value row; here its neighbours are
 *  `−` and `+` in the app's own face, and a mono cell among them reads as belonging
 *  to something else. Everything else about the box — height, inset, the seam, the
 *  focus mark — comes from `.ocv-input.is-segment`, which is why there is so little
 *  here. */
const zoomCell = {
  width: 60,
  fontFamily: "inherit",
  fontSize: SIZE.base,
  textAlign: "center",
} satisfies React.CSSProperties;
