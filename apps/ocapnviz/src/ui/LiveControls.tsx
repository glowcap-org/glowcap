/**
 * Live-mode recording controls. Entering Live connects the feed, so
 * a reader can see one is there before deciding to record it, Live
 * renders nothing until Record because a capture is what there is to
 * render. The capture mounts at the press, on a fresh dial, so its
 * t=0 is the press and the producer's replay materializes that
 * moment's topology inside it. Stop claims the recording as the
 * unsaved buffer source and lands in Play, Discard throws it away.
 *
 * Pressing Record when the buffer has content asks first, through the
 * app's own dialog (`ui/confirm.ts`), the same way switching source
 * does, Stop needs no prompt, consent was given at the press.
 */

import { type ConfirmRequest, requestConfirm } from "./confirm.ts";
import { c } from "./tokens.ts";

const RECORD_CONFIRM: ConfirmRequest = {
	title: "Discard the loaded document?",
	detail: "Stopping this recording replaces what is loaded, so anything " +
		"unsaved in it goes.",
	confirmLabel: "Record",
};

export function LiveControls({
	recording,
	bufferHasContent,
	onStart,
	onStop,
	onDiscard,
}: {
	recording: boolean;
	/** Drives the discard-warning gate on Record. True iff the
	 * buffer has any events (fixture loaded, file opened, prior
	 * recording present). */
	bufferHasContent: boolean;
	onStart: () => void;
	/** Claim the recording and land in Play. */
	onStop: () => void;
	/** Throw the recording away, staying in Live. */
	onDiscard: () => void;
}) {
	if (recording) {
		return (
			<>
				<button
					type="button"
					className="ocv-btn is-active"
					onClick={onStop}
					title="Stop and review the recording in Play"
					aria-label="Stop recording"
				>
					<span style={dotStyle} />
					<span>Stop</span>
				</button>
				<button
					type="button"
					className="ocv-btn is-ghost"
					onClick={onDiscard}
					title="Discard the recording"
					aria-label="Discard recording"
				>
					Discard
				</button>
			</>
		);
	}
	return (
		<button
			type="button"
			className="ocv-btn"
			onClick={async () => {
				if (
					bufferHasContent && !await requestConfirm(RECORD_CONFIRM)
				) return;
				onStart();
			}}
			title="Start recording from now"
			aria-label="Start recording"
		>
			<span style={dotStyle} />
			<span>Record</span>
		</button>
	);
}

const dotStyle: React.CSSProperties = {
	width: 8,
	height: 8,
	borderRadius: "50%",
	background: c.danger,
	display: "inline-block",
	// No margin: `.ocv-btn` already gaps its own children, and a margin
	// on top of that gap put the dot twice as far from its label as
	// every other button's glyph.
};
