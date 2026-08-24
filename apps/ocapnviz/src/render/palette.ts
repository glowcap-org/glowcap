import type { BuiltinCodec, CaptpVersion, Codec, PeerProfile, SessionState } from "../schema/topology.ts";
import { KNOWN_PROFILES } from "../schema/topology.ts";

/** Per-state segment fill colors for the Scrubber's session pills.
 *  The labels overlaid on segments are painted in white, so each entry
 *  is a deep, saturated tone with luminance well below the white text
 *  — bright themed.positive / themed.warning would wash out the text.
 *  Theme-independent because both themes render white labels on top. */
const SESSION_STATE_SEGMENT_COLORS: Record<SessionState, number> = {
	open: 0x047857, // emerald-700
	negotiating: 0xb45309, // amber-700
	draining: 0xc2410c, // orange-700
	closed: 0x374151, // gray-700
};

export function sessionStateColors(
	_themed: ThemedColors,
): Record<SessionState, number> {
	return SESSION_STATE_SEGMENT_COLORS;
}
import type { Theme } from "../ui/tokens.ts";

/**
 * Visual encoding palette. Three categorical encodings on edges
 * (line style, line color, thickness + alpha) and one on nodes
 * (color). That is the legibility cap, so adding a fourth means
 * removing one. `docs/design-principles.md` carries the reasoning,
 * under "The vocabulary".
 */

/** A color for each profile the schema declares. Typed by
 *  `KNOWN_PROFILES`, so a profile added there without a color fails
 *  the build rather than quietly painting as the fallback. A feed may
 *  still report a profile this build has never heard of — that is
 *  what `PROFILE_FALLBACK_COLOR` is for. */
export const PROFILE_COLORS: Record<typeof KNOWN_PROFILES[number], number> = {
	pancake: 0xf59e0b,
	goblins: 0x8b5cf6,
};

export const PROFILE_FALLBACK_COLOR = 0x94a3b8;

export function colorForProfile(profile: PeerProfile): number {
	// A profile is an open string, so the lookup widens once here
	// rather than every caller carrying the fallback.
	const known: { readonly [name: string]: number | undefined } = PROFILE_COLORS;
	return known[profile] ?? PROFILE_FALLBACK_COLOR;
}

/** The two tones a glyph painted ON a filled pill can take. Near-
 *  black and near-white, so whichever one `glyphOnFill` picks is the
 *  most readable mark available on that fill. */
const GLYPH_INK = 0x101828;
const GLYPH_PAPER = 0xffffff;

/** Relative luminance of an `0xRRGGBB` color, per sRGB (WCAG). */
function relativeLuminance(rgb: number): number {
	const channel = (c: number) => {
		const s = c / 255;
		return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
	};
	const r = channel((rgb >> 16) & 0xff);
	const g = channel((rgb >> 8) & 0xff);
	const b = channel(rgb & 0xff);
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG contrast ratio between two `0xRRGGBB` colors, 1:1 (same)
 *  to 21:1 (black on white). */
function contrastRatio(a: number, b: number): number {
	const la = relativeLuminance(a);
	const lb = relativeLuminance(b);
	return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** A glyph tone that stays readable on `fill`: whichever of ink and
 *  paper contrasts with it more. A peer's pill is a categorical
 *  encoding chosen per entity (its profile paints amber, violet, or
 *  slate), so no single glyph color reads on all of them —
 *  pancake's amber swallowed a muted grey diamond whole. Compared
 *  rather than split at a luminance threshold, because the slate
 *  fallback sits near the middle and a threshold picks it wrong.
 *  The fills are theme-independent, so this choice is too.
 *
 *  Available only where the pill has ONE fill under the glyph. A
 *  session pill does not: `buildSessionStateSegments` bands it by
 *  state, so a diamond can straddle two fills, and its tone stays
 *  the fixed categorical `warning` instead. */
export function glyphOnFill(fill: number): number {
	return contrastRatio(fill, GLYPH_INK) >= contrastRatio(fill, GLYPH_PAPER) ? GLYPH_INK : GLYPH_PAPER;
}

/** Edge color per CaptpVersion. Categorically distinct from PROFILE_COLORS. */
export const CAPTP_VERSION_COLORS: Record<CaptpVersion, number> = {
	v1_0: 0x2563eb,
	next: 0x0891b2,
	unknown: 0x64748b,
};

export const SESSION_STATE_WIDTH: Record<SessionState, number> = {
	open: 4,
	negotiating: 2,
	draining: 2,
	closed: 1,
};

export type CodecLineStyle = "solid" | "dashed" | "dotted";

/** The line style each built-in codec is drawn with, said once. The stage edge,
 *  the Inspector's session swatch and the Legend all read it, so the mark in the
 *  key is the mark on the picture. Spelled as CSS names because two of those
 *  three draw a border; the stage reads it as a drawing style. */
export const CODEC_LINE_STYLE: Record<BuiltinCodec, CodecLineStyle> = {
	capnp: "solid",
	syrup: "dashed",
};

/** The mark for a codec this viewer cannot name. It must not reuse either
 *  built-in mark: that would say "Syrup" or "Cap'n Proto" where the trace only
 *  said "not in this ABI vocabulary". */
export const CODEC_FALLBACK_LINE_STYLE: CodecLineStyle = "dotted";

export function lineStyleForCodec(codec: Codec): CodecLineStyle {
	const known: { readonly [name: string]: CodecLineStyle | undefined } = CODEC_LINE_STYLE;
	return known[codec] ?? CODEC_FALLBACK_LINE_STYLE;
}

/** Dash cadence (on, off) in world units, used for a dashed edge. */
export const DASH_PATTERN: readonly [number, number] = [12, 6];

/** Dot cadence (on, off) in world units, used for an unknown-codec edge. */
export const DOT_PATTERN: readonly [number, number] = [2, 6];

/** Light-theme message-in-flight color. The renderer goes through
 * `themedColors().messageInFlight`; the legend cites this token
 * directly (always rendered against chrome). */
export const MESSAGE_IN_FLIGHT_COLOR = 0xef4444;

/** Numeric (PixiJS) form of the theme-dependent chrome colors.
 * CSS-side equivalents live in `styles.css`. */
export type ThemedColors = {
	/** Mirrors `--ocv-canvas` in styles.css. */
	canvas: number;
	text: number;
	textSubtle: number;
	labelBg: number;
	labelBgAlpha: number;
	labelBorder: number;
	labelBorderAlpha: number;
	messageInFlight: number;
	peerStroke: number;
	accent: number;
	positive: number;
	warning: number;
};

// `themedColors(theme)` runs every frame from the Stage's ticker
// (60 Hz); per-call object literals showed up in GC profiles, so
// these are module-level frozen.
const LIGHT_COLORS: ThemedColors = Object.freeze({
	canvas: 0xffffff,
	text: 0x101828,
	textSubtle: 0x475467,
	labelBg: 0xffffff,
	labelBgAlpha: 0.94,
	labelBorder: 0x101828,
	labelBorderAlpha: 0.22,
	messageInFlight: MESSAGE_IN_FLIGHT_COLOR,
	peerStroke: 0x101828,
	accent: 0x4f46e5,
	positive: 0x10b981,
	warning: 0xc97a16,
});

const DARK_COLORS: ThemedColors = Object.freeze({
	canvas: 0x181a20,
	text: 0xe6e7ea,
	textSubtle: 0xa1a3aa,
	labelBg: 0x1a1c22,
	labelBgAlpha: 0.92,
	labelBorder: 0xffffff,
	labelBorderAlpha: 0.18,
	messageInFlight: 0xfb7185,
	peerStroke: 0x0f1115,
	accent: 0x818cf8,
	positive: 0x34d399,
	warning: 0xfbbf24,
});

export function themedColors(theme: Theme): ThemedColors {
	return theme === "dark" ? DARK_COLORS : LIGHT_COLORS;
}
