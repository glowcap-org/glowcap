// A commitment that is still happening, and the × that stops it.
//
// The busy button keeps saying what it is doing and is not a second press of
// the same action. That is why it stays unpressable. The × is the same mark
// that stops a file send and takes a chip back: one glyph, a name that says
// the specific wait it ends. It stands on the button's own face, so it takes
// that face's ink: the on-accent tone over amber, the ordinary one elsewhere.

import { Button, type ButtonProps } from "./Button.tsx";
import { IconButton } from "./IconButton.tsx";

export function WorkingAction(
	{ busy, stopLabel, onStop, stopId, children, ...button }: ButtonProps & {
		stopLabel: string;
		onStop: () => void;
		stopId?: string;
	},
) {
	return (
		<div className="working-action">
			<Button {...button} busy={busy}>
				{children}
			</Button>
			<IconButton
				id={stopId}
				style={{ visibility: busy ? "visible" : "hidden" }}
				disabled={!busy}
				icon="close"
				label={stopLabel}
				size="small"
				variant="ghost"
				tone={(button.variant ?? "primary") === "primary" ? "on-accent" : "neutral"}
				onClick={onStop}
			/>
		</div>
	);
}
