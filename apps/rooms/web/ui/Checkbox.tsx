// A labeled yes-or-no mark for a form row.
//
// The switch next door answers "is this in force" and flips things that
// apply at once; a checkbox answers "include this" inside a form that still
// has its own submit. It stays a native input — forms, labels, and keyboards
// already know one — and the stylesheet draws it in the design system's
// field language: the field fill and lift at rest, the accent with a drawn
// check when chosen. The visible row label lives beside it in a `check-row`
// label, so the control needs no aria of its own.

import type { ComponentPropsWithRef } from "react";

export type CheckboxProps = Omit<ComponentPropsWithRef<"input">, "type" | "children">;

export function Checkbox({ className, ...input }: CheckboxProps) {
	return <input {...input} type="checkbox" className={["checkbox", className].filter(Boolean).join(" ")} />;
}
