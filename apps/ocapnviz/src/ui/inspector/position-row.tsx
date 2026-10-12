/**
 * The inspector's authored-position row: two coordinate scrubs and
 * a pin/unpin control, one undo step for a drag.
 */

import type { CSSProperties } from "react";
import { ClearGlyph, PinGlyph } from "../glyphs.tsx";
import { ScrubInput } from "../Timeline/ScrubInput.tsx";
import { formatCoord } from "../format.ts";
import type { EditBracket } from "./edit-bracket.ts";
import { useScrubBracket } from "./edit-bracket.ts";
import { Field } from "./fields.tsx";
import { endRowIconButtonStyle, endRowStyle, valueMono } from "./styles.tsx";

/** One coordinate scrub for the position row, `TimeScrubInput`'s
 * sibling, formatting plain numbers instead of times. Same
 * `ScrubInput` engine, same ROW_H lock via the forwarded style. */
function CoordScrubInput(
	{ value, onChange, label, onScrubStart, onScrubEnd }: {
		value: number;
		onChange: (next: number) => void;
		label: string;
		onScrubStart?: (() => void) | undefined;
		onScrubEnd?: (() => void) | undefined;
	},
) {
	return (
		<ScrubInput
			value={value}
			onChange={onChange}
			{...(onScrubStart ? { onScrubStart } : {})}
			{...(onScrubEnd ? { onScrubEnd } : {})}
			min={-100_000}
			max={100_000}
			// Full-fidelity fact display; the typed-edit seed especially
			// must round-trip, or a focus-then-blur commits the rounding
			// into the pin and cold-recomputes the layout (`format.ts`).
			format={formatCoord}
			formatInput={formatCoord}
			label={label}
			linear
			// 1px of drag ≈ 1 world unit. The stage's own scale.
			pxPerDoubling={1}
			style={{ flex: 1, minWidth: 0 }}
		/>
	);
}

// The coordinate pair is one flex item in a fixed-height row, so it has
// to be allowed to shrink; `valueMono` already clips and ellipsizes.
const positionValueStyle = {
	...valueMono,
	flex: "0 1 auto",
} satisfies CSSProperties;

/** Inspector row for a peer's placement, the position sibling of
 * `OptionalTimeRow`, built from the same row idiom (ROW_H shell,
 * square ✕, opt-in button). Two states, narrated to the user as
 * WHO owns the position, "pinned" (the user authored it) vs
 * "auto" (the system places it automatically, mechanically, the
 * force layout). "auto" is the user word: "layout" is
 * the implementation's name for the mechanism, and a UI string
 * that needs codebase knowledge to parse is an insider word in
 * pixel space.
 *
 *   - pinned ⇒ x / y coordinate scrubs when editing (each write
 *     re-pins) plus the ✕ that unpins, returning the peer to
 *     automatic placement
 *   - auto ⇒ the current coordinates read-only with a square
 *     pin-glyph opt-in (editing only), the placement's mirror of
 *     "Insert @playhead"
 *
 * "Auto" stays a first-class state, exactly like "no end" on the
 * timing rows. */
export function PositionRow(
	{
		pinned,
		at,
		editing,
		onMove,
		onClear,
		onPinHere,
		editSession,
		noun = "peer",
	}: {
		/** The authored position, or null when the layout owns the
		 *  peer's placement. */
		pinned: { x: number; y: number } | null;
		/** Where the peer sits right now (authored, or the layout's
		 *  latest placement). Null when it isn't on stage at all. */
		at: { x: number; y: number } | null;
		editing: boolean;
		onMove: ((pos: { x: number; y: number }) => void) | undefined;
		onClear: (() => void) | undefined;
		onPinHere: (() => void) | undefined;
		/** Edit-transaction brackets (`EditorBindings` subset), a
		 *  coordinate scrub becomes one undo step. Required so a call
		 *  site cannot silently ship unbracketed scrubs. Pass the
		 *  editor (undefined outside Build). */
		editSession: EditBracket | undefined;
		/** What the row is placing, for the strings a user reads. A session's
		 *  unattributed end is placed the same way and is not a peer. */
		noun?: string;
	},
) {
	const session = useScrubBracket(editSession, `Move ${noun}`);
	return (
		<Field label="position">
			<span style={endRowStyle}>
				{pinned && editing && onMove
					? (
						<>
							<CoordScrubInput
								value={pinned.x}
								onChange={(x) => onMove({ x, y: pinned.y })}
								label={`${noun} x`}
								{...session}
							/>
							<CoordScrubInput
								value={pinned.y}
								onChange={(y) => onMove({ x: pinned.x, y })}
								label={`${noun} y`}
								{...session}
							/>
							{onClear && (
								<button
									type="button"
									className="ocv-btn is-icon"
									onClick={onClear}
									title={`Unpin — return this ${noun} to automatic placement`}
									aria-label="Unpin position"
									style={endRowIconButtonStyle}
								>
									<ClearGlyph />
								</button>
							)}
						</>
					)
					: (
						<>
							<code style={positionValueStyle}>
								{at ? `${formatCoord(at.x)}, ${formatCoord(at.y)}` : "—"}{" "}
								{pinned ? "· pinned" : "· auto"}
							</code>
							{!pinned && editing && onPinHere && at && (
								<button
									type="button"
									className="ocv-btn is-icon"
									onClick={onPinHere}
									title="Pin at the current automatic position"
									aria-label="Pin at the current automatic position"
									style={endRowIconButtonStyle}
								>
									<PinGlyph />
								</button>
							)}
						</>
					)}
			</span>
		</Field>
	);
}
