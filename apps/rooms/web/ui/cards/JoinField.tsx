// A join-form field: one box, a prefix that looks like a preview, and the text.
//
// The prefix is the control: a directory mark that opens held locators, a hash
// that becomes a lock when the room is private, a picture of you that will one
// day set one. Hover and press live on that mark so the field reads as a name
// beside an identity, not as a box with a button stuck to its side.

import type { ComponentPropsWithRef, ReactNode } from "react";

export function JoinField(
	{ invalid, children }: { invalid?: boolean; children: ReactNode },
) {
	return (
		<div className="join-field" data-invalid={invalid === true ? "true" : undefined}>
			{children}
		</div>
	);
}

/** The mark at the start of a join field. Geometry and interaction are the icon
 * button family's. The contents are whatever that field is about. */
export function JoinPrefix({
	label,
	className,
	children,
	...button
}: {
	label: string;
	children: ReactNode;
} & Omit<ComponentPropsWithRef<"button">, "aria-label" | "children" | "title" | "type">) {
	const classes = ["icon-button", "join-prefix", className].filter(Boolean).join(" ");
	return (
		<button
			{...button}
			type="button"
			className={classes}
			data-size="normal"
			data-variant="ghost"
			data-tone="neutral"
			data-shape="rounded"
			aria-label={label}
			title={label}
		>
			{children}
		</button>
	);
}
