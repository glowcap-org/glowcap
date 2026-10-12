// The two things that pop up over the field: the emoji tray and the
// completion list. Each is a row of buttons that puts something into the
// draft, and each keeps the caret where it is, so pressing a row never
// collapses the selection the row is about to replace.
//
// Beside the composer rather than inside it because neither holds state of
// its own: what is open, what is picked, and what a press does are the
// composer's, handed in as props, and the composer stays the one owner of
// the caret these rows must not move.

import type { Candidate } from "../complete.ts";
import { PICKER } from "../text.ts";
import { completionsLabel, emojiLabel } from "../../../lib/text/controls.ts";

/** The emoji tray: the picker's glyphs, one button each. */
export function EmojiTray({ open, onPick }: { open: boolean; onPick: (glyph: string) => void }) {
	return (
		<div
			id="emojiPop"
			className={open ? "emoji-pop show" : "emoji-pop"}
			role="group"
			aria-label={emojiLabel}
		>
			{PICKER.map((glyph) => (
				<button
					key={glyph}
					type="button"
					// Keep the field focused: a mousedown here would otherwise
					// collapse the caret and land the emoji at the end.
					onMouseDown={(e) => e.preventDefault()}
					onClick={() => onPick(glyph)}
				>
					{glyph}
				</button>
			))}
		</div>
	);
}

/** The completion list under a half-typed token: commands, names, rooms,
 * shortcodes. `pick` is the row the keyboard is on. A pointer moving onto
 * a row takes the pick, and a press accepts the row under it. */
export function CompletionList(
	{ candidates, pick, onPick, onAccept }: {
		candidates: readonly Candidate[];
		pick: number;
		onPick: (index: number) => void;
		onAccept: (candidate: Candidate) => void;
	},
) {
	return (
		<div id="completePop" className="complete-pop" role="listbox" aria-label={completionsLabel}>
			{candidates.map((candidate, i) => (
				<button
					key={candidate.kind + candidate.label}
					id={`complete-${i}`}
					type="button"
					role="option"
					tabIndex={-1}
					aria-selected={i === pick}
					// Said the way a reader would say it. The row draws its three
					// parts with space between them, and space drawn by a layout is
					// nothing to software that reads the text: without this the
					// option announces as "/awaysay you have stepped away".
					aria-label={[candidate.label, candidate.hint].filter(Boolean).join(", ")}
					className={i === pick ? "complete-row picked" : "complete-row"}
					// Keep the field focused, same rule as the emoji tray.
					onMouseDown={(e) => e.preventDefault()}
					// A pointer that moves onto a row picks it. Entering is not
					// enough: the list opens under wherever the pointer last
					// came to rest, and a row arriving under a parked pointer
					// would steal the pick from the row the typing narrowed to.
					onMouseMove={() => {
						if (i !== pick) onPick(i);
					}}
					onClick={() => onAccept(candidate)}
				>
					{candidate.glyph ? <span className="complete-glyph">{candidate.glyph}</span> : null}
					<span className="complete-label">{candidate.label}</span>
					{candidate.hint === undefined ? null : <span className="complete-hint">{candidate.hint}</span>}
				</button>
			))}
		</div>
	);
}
