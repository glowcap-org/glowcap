// The text box of a form: `Field` wires a label, a hint, and a refusal around
// a control, and this is the control. It owns the `field` class that draws the
// box, so a caller passes the attributes that belong to what it asks (a type,
// the keyboard's corrections, the wiring `Field` hands it) and never the look.
// A select is the same box, in `Select.tsx`.

import type { ComponentPropsWithRef } from "react";

export function Input({ className, ...input }: ComponentPropsWithRef<"input">) {
	return <input {...input} className={["field", className].filter(Boolean).join(" ")} />;
}
