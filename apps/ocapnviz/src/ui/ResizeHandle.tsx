/**
 * Seam between two layout regions. Absolutely positioned inside its
 * parent (which must be `position: relative`); the hit-area is fatter
 * than the visible 1 px line for an easier grab. The host owns the
 * resize logic — `useResizeHandle` wires the pointer and the keyboard
 * and reports a per-axis delta.
 *
 * It is a focusable separator, which is what a splitter between two
 * panes is: Tab reaches it, the arrow keys along its axis move it, and
 * Shift makes each press coarse. A seam only a drag can move is a pane
 * a keyboard cannot resize, and the panes hold the whole app.
 */

import { c } from "./tokens.ts";
import { RESIZE_HANDLE_THICKNESS } from "../state/app-state.ts";
import { useResizeHandle } from "./useResizeHandle.ts";

export function ResizeHandle(
  { axis, edge, label, onDelta, onDoubleClick, title, style }: {
    axis: "x" | "y";
    edge: "left" | "right" | "top" | "bottom";
    /** What this seam separates, for anyone who reaches it by Tab —
     *  "Left panel width". Required, because a separator with no name
     *  is an unlabeled control in the tab order. */
    label: string;
    onDelta: (delta: number) => void;
    /** Optional double-click affordance — e.g. "snap pane to its
     * intrinsic content height". Callers wire the snap target; the
     * keyboard reaches the same verb with Enter. */
    onDoubleClick?: (() => void) | undefined;
    title?: string | undefined;
    style?: React.CSSProperties;
  },
) {
  const {
    dragging,
    onPointerDown,
    onPointerMove,
    onPointerUp,
    onPointerCancel,
    onLostPointerCapture,
    onKeyDown,
  } = useResizeHandle(axis, onDelta);
  const base: React.CSSProperties = axis === "x"
    ? {
      position: "absolute",
      top: 0,
      bottom: 0,
      width: RESIZE_HANDLE_THICKNESS,
      [edge]: -RESIZE_HANDLE_THICKNESS / 2,
      cursor: "col-resize",
    }
    : {
      position: "absolute",
      left: 0,
      right: 0,
      height: RESIZE_HANDLE_THICKNESS,
      [edge]: -RESIZE_HANDLE_THICKNESS / 2,
      cursor: "row-resize",
    };
  return (
    <div
      // The seam's own focus mark lives here, in `.ocv-handle`. Without
      // it a splitter wears the browser's default ring, which is a
      // different color and a different rectangle from every other
      // stop in the tab order.
      className="ocv-handle"
      role="separator"
      // A separator is horizontal unless it says otherwise, and this
      // one describes the seam rather than the panes: an `x` handle is
      // a vertical line between a left and a right pane.
      aria-orientation={axis === "x" ? "vertical" : "horizontal"}
      aria-label={label}
      tabIndex={0}
      style={{
        ...base,
        ...style,
        zIndex: 10,
        background: dragging ? c.accent : "transparent",
        opacity: dragging ? 0.4 : 1,
        transition: "background-color 120ms ease",
      }}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerCancel}
      onLostPointerCapture={onLostPointerCapture}
      onKeyDown={(event) => {
        // Enter is the keyboard's spelling of the double-click verb,
        // where the handle has one. Everything else is the axis move.
        if (onDoubleClick && event.key === "Enter") {
          event.preventDefault();
          onDoubleClick();
          return;
        }
        onKeyDown(event);
      }}
      {...(onDoubleClick ? { onDoubleClick } : {})}
      {...(title ? { title } : {})}
    />
  );
}
