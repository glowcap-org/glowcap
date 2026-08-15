/**
 * Floating banner at the top of the stage telling the user where
 * they are in the active tool's gesture flow. Rendered in every
 * mode: the space-pan notice applies wherever Space pans (any
 * mode, over the stage), while the two-click flow cases only speak
 * for authoring tools, which only exist in Build. Mirrors the
 * "context bar" idiom from design tools (Figma/Sketch top-of-canvas
 * prompt).
 *
 * Scope is gesture state only — NOT pan/multi-select modifier
 * feedback (the cursor change already covers space-pan; shift is a
 * common modifier the user is expected to know). Configured tool
 * values live in the ToolOptionsBar; this banner is the "what
 * happens next" surface.
 *
 * Every message is the tool's name, then ONE imperative saying what to click
 * next, and nothing else. This sits over the stage, so a hint long enough to
 * need reading covers the thing the reader is trying to look at — which is what
 * it did while it also explained what clicking empty canvas would do instead.
 * That detail, and the way out of a part-finished gesture, belong to the tool
 * options bar above: it has room, and unlike this banner it can hold a button.
 *
 * Cases, in priority order:
 *
 *   1. Armed two-click — "Open session — click a second node (from alice)"
 *   2. Pre-armed two-click — "Open session — click the first node"
 *   3. Add peer — "Add peer — click empty canvas"
 *   4. Select / others — null (no banner)
 */

import type { BuilderTool } from "../state/app-state.ts";
import { c, RADIUS, SIZE, SPACE, WEIGHT } from "./tokens.ts";

export function ToolHint(
  { tool, armedNodeLabel, spaceHeld }: {
    tool: BuilderTool;
    /** Display label of the armed node (peer or loose end) when in
     *  the two-click ARMED state for open-session / send-message;
     *  null when unarmed or when the tool has no two-click flow. */
    armedNodeLabel: string | null;
    /** Whether the spacebar is currently held — overrides the
     *  tool's normal gesture cue with the pan announcement. */
    spaceHeld: boolean;
  },
) {
  if (spaceHeld) {
    return <div style={banner} aria-hidden>Pan — release space to resume</div>;
  }
  let message: React.ReactNode = null;
  if (tool === "open-session") {
    message = armedNodeLabel === null ? "Open session — click the first node" : (
      <>
        Open session — click a second node <span style={accent}>(from {armedNodeLabel})</span>
      </>
    );
  } else if (tool === "send-message") {
    message = armedNodeLabel === null ? "Send message — click the sender" : (
      <>
        Send message — click the receiver <span style={accent}>(from {armedNodeLabel})</span>
      </>
    );
  } else if (tool === "add-peer") {
    message = "Add peer — click empty canvas";
  } else {
    return null;
  }
  return <div style={banner} aria-hidden>{message}</div>;
}

const banner = {
  position: "absolute",
  top: 12,
  left: "50%",
  transform: "translateX(-50%)",
  zIndex: 2,
  pointerEvents: "none",
  background: c.surface,
  color: c.textMuted,
  border: `1px solid ${c.border}`,
  borderRadius: RADIUS.pill,
  paddingInline: SPACE.md,
  paddingBlock: SPACE.sm,
  fontSize: SIZE.xs,
  fontWeight: WEIGHT.medium,
  letterSpacing: 0.4,
  textTransform: "uppercase",
  boxShadow: "0 2px 8px rgba(0,0,0,0.08)",
  whiteSpace: "nowrap",
} satisfies React.CSSProperties;

const accent = {
  color: c.accent,
  fontWeight: WEIGHT.semibold,
  textTransform: "none",
  letterSpacing: 0,
} satisfies React.CSSProperties;
