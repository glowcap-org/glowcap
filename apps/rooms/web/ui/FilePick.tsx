// Choosing a file, in the page's own voice.
//
// The browser's own file control is the one input a page cannot dress: its
// button is drawn by the platform, its words are the platform's ("Choose
// File", "No file chosen"), and its height is whatever the platform says. Put
// beside a rooms field and a rooms button it reads as something pasted in from
// another program, which is exactly what it is.
//
// So the real input stays, invisible but present and pressable across the
// whole control, and the page draws the face over it: a mark, then either the
// invitation or the name of the file that was chosen. The input is what the
// pointer and the keyboard both reach, which is why it is transparent rather
// than hidden — a hidden input takes no press and no focus, and driving one
// from a label's click handler loses the keyboard.

import { Icon } from "./icons.tsx";

export function FilePick(
	{ id, accept, name, disabled = false, describedBy, invalid, onChoose }: {
		/** The field's own id, so its label names this control. */
		id: string;
		accept: string;
		/** The chosen file's name, or null while none is chosen. */
		name: string | null;
		disabled?: boolean;
		describedBy?: string;
		invalid?: true;
		onChoose(file: File | null): void;
	},
) {
	return (
		<div className="file-pick" data-chosen={name === null ? undefined : ""} data-disabled={disabled || undefined}>
			<input
				id={id}
				className="file-pick-input"
				type="file"
				accept={accept}
				disabled={disabled}
				aria-describedby={describedBy}
				aria-invalid={invalid}
				onChange={(event) =>
					onChoose(event.currentTarget.files?.[0] ?? null)}
			/>
			<span className="file-pick-face" aria-hidden="true">
				<Icon name="file" size={16} />
				<span className="file-pick-name">{name ?? "Choose a file"}</span>
			</span>
		</div>
	);
}
