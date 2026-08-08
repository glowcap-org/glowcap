/**
 * What the stage writes beside a node or along an edge, and how much room
 * that writing takes.
 *
 * One home for readers that have to agree. `render-frame.ts` sets the type
 * and paints the pill behind it, `engine/systems/keyframe-layout-system.ts`
 * reserves a box for that pill before anything is drawn, and
 * `draw-helpers.ts` staggers a bundle's chips far enough apart that two of
 * them clear. A label drawn at one size and separated at another is a gap no
 * reader could explain, so the sizes are stated once here rather than at each
 * site.
 *
 * A leaf: it imports no renderer and no engine, so either may read it.
 *
 * Everything here is world units at 100% zoom. Labels are counter-scaled as
 * the stage zooms (`renderFrame`'s `counterScale`), so a label holds a fixed
 * SCREEN size while the layout solves once in world units. The two therefore
 * agree at zoom 1 and the label grows relative to the graph as the reader
 * zooms out; one solve cannot hold separation at every zoom, and
 * `endpointLabelText` bounding the worst-case width is what keeps the zoomed
 * out picture readable instead.
 */

import { UNNAMED_END_LABEL } from "../schema/topology.ts";
import { elideIdentifier } from "../ui/elide.ts";

/** A label's type size and the pill drawn behind it. */
export type LabelPill = {
  /** Size the renderer sets the text at. */
  fontPx: number;
  /** Empty space either side of the text, inside the pill. */
  padX: number;
  /** Empty space above and below the text, inside the pill. */
  padY: number;
};

/** The padding a small chip carries. One value because the edge chip and the
 *  message label are one size of pill: they are the two captions that ride a
 *  moving thing rather than sitting under a body, and a reader who noticed
 *  them differing would be noticing a mistake. */
const CHIP_PAD = { padX: 8, padY: 3 } as const;

/** The caption under a peer or a session end. */
export const NODE_LABEL: LabelPill = { fontPx: 11, padX: 10, padY: 4 };

/** The `codec · captp` chip that rides a session's edge. Tiny, and mono
 *  because it is a composite of two wire words. */
export const EDGE_CHIP_LABEL: LabelPill = { fontPx: 9, ...CHIP_PAD };

/** The payload preview that rides a message dot. Smaller than a node's
 *  caption because messages cluster and tile across the stage. */
export const MESSAGE_LABEL: LabelPill = { fontPx: 10, ...CHIP_PAD };

/** How far below a node's body its caption hangs. */
export const NODE_LABEL_GAP_PX = 8;

/** How far below a message dot its preview hangs. */
export const MESSAGE_LABEL_GAP_PX = 6;

/**
 * Average glyph advance as a fraction of the font size, one per family the
 * stage labels with.
 *
 * These are an estimate, and they have to be: the layout runs with no text
 * metrics at all — no Pixi context, no DOM — and it must produce the same
 * numbers in a test process as in a browser, so measuring is not available to
 * it even in principle. Character count times an average advance is sound
 * here because each family is used for what it measures well. A designator is
 * drawn monospaced, where every glyph really is 0.6 em and the estimate is
 * exact. A peer's display name is drawn proportionally, where the average
 * over mixed-case Latin text lands within about a tenth of the true width:
 * measured against real Pixi text at 11px, `Carol (exporter)` renders 83 px
 * wide and `Bob (receiver)` 73 px, or 5.2 and 5.1 px per character.
 *
 * Being a tenth out costs a tenth of a label's worth of daylight, never an
 * overlap, because `LayoutConfig.nodeSpacing` adds several times that much
 * room on top of the estimate.
 */
export const SANS_ADVANCE = 0.5;
export const MONO_ADVANCE = 0.6;

/** How tall one line of text stands as a share of its font size. An estimate
 *  of the line box Pixi computes from the font's own metrics, for the same
 *  reason the advances above are estimates: the solver has no font to ask. */
const LINE_BOX_RATIO = 1.25;

/** The line box one line of `fontPx` text occupies. */
export function lineBoxPx(fontPx: number): number {
  return Math.round(fontPx * LINE_BOX_RATIO);
}

/** How large a pill holding `chars` characters comes out, in world units at
 *  100% zoom. `mono` picks the family the text is set in, which is the only
 *  thing that changes how wide a character is. */
export function pillSize(
  chars: number,
  pill: LabelPill,
  mono: boolean,
): { width: number; height: number } {
  const advance = (mono ? MONO_ADVANCE : SANS_ADVANCE) * pill.fontPx;
  return {
    width: chars * advance + pill.padX * 2,
    height: lineBoxPx(pill.fontPx) + pill.padY * 2,
  };
}

/**
 * What the stage writes under a session end: the name it claims, or a plain
 * word for claiming nothing.
 *
 * Never the stage id — `s1::b` names the slot, and a reader who wanted the
 * slot's name can select it and read it in the Inspector.
 *
 * A claim is a designator, which is a string the network chose and can run to
 * sixty-four characters of hex. Shown whole it draws a pill several times
 * wider than the graph it is part of, and a hub's ends then cannot fan onto
 * one ring at all. It is shortened the same way the Inspector and the Sidebar
 * shorten one, so the same identifier reads the same everywhere and the whole
 * value stays one selection away.
 */
export function endpointLabelText(designator: string | undefined): string {
  return designator === undefined
    ? UNNAMED_END_LABEL
    : elideIdentifier(designator);
}

/**
 * What the stage writes under a peer: the caption it wears, shortened when
 * it is too long to draw.
 *
 * The same shortening a session end's claim gets, and for the same reason —
 * a pill wider than the graph it belongs to pushes every neighbor away and
 * leaves the picture unreadable at the zoom that would show all of it.
 *
 * The middle is what goes here too, even though this caption is a peer's
 * NAME rather than a wire identifier. Three things decide it:
 *
 * A peer with no stated name wears its id (`PEER_TRAJECTORY.label`'s
 * fallback), so this string is a name or an identifier and nothing on the
 * stage can tell which — the world entity carries the resolved caption, not
 * where it came from. Clipping the tail off an identifier is the one
 * treatment `ui/identifier.tsx` argues against, because two ids sharing a
 * prefix then draw as the same node, and the stage is where several are read
 * side by side.
 *
 * The names this app is given put their discriminating word at the end
 * ("Carol (exporter)" beside "Carol (receiver)"), so a name's tail carries
 * information as much as an identifier's does.
 *
 * And a name long enough to reach the threshold is past the length anyone
 * reads off a node anyway; the whole caption is one selection away in the
 * Inspector, which shows it in a row that can clip it against a real box.
 *
 * `entityLabel` in `ui/inspector/SelectionPanel.tsx` shortens a peer's
 * caption the same way, for the same reason, where it has to sit inside a
 * running sentence.
 */
export function peerLabelText(label: string): string {
  return elideIdentifier(label);
}
