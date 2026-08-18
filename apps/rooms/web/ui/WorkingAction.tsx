// A commitment that is still happening, and the × that stops it.
//
// The busy button keeps saying what it is doing and is not a second press of
// the same action — that is why it stays unpressable. The × is the same mark
// that stops a file send and takes a chip back: one glyph, a name that says
// the specific wait it ends.

import { Button, type ButtonProps } from "./Button.tsx";
import { IconButton } from "./IconButton.tsx";

export function WorkingAction(
	{ busy, stopLabel, onStop, stopId, children, ...button }: ButtonProps & {
		stopLabel: string;
		onStop: () => void;
		stopId?: string;
	},
) {
	if (!busy) {
		return <Button {...button}>{children}</Button>;
	}
	return (
		<div className="working-action">
			<Button {...button} busy>
				{children}
			</Button>
			<IconButton
				id={stopId}
				icon="close"
				label={stopLabel}
				size="small"
				variant="ghost"
				tone="danger"
				onClick={onStop}
			/>
		</div>
	);
}
