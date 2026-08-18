// A labeled on/off control for a settings row.
//
// The press is the whole of the choice: there is no separate "apply". Callers
// decide what turning on costs — a modal to take a capability, a preference
// that sticks — and this only says whether the thing is in force.

import type { ComponentPropsWithRef } from "react";

export type SwitchProps = Omit<ComponentPropsWithRef<"button">, "aria-checked" | "role" | "children"> & {
	checked: boolean;
	/** Accessible name. The visible row label is separate so the switch can sit
	 * at the end of a line without repeating it to the eye. */
	label: string;
	/** The press's verb is in flight: the thumb pulses and the control parks
	 * until the answer lands. Separate from `disabled`, which says the press
	 * is not on offer at all. */
	busy?: boolean;
};

export function Switch({ checked, label, busy = false, disabled, className, type = "button", ...button }: SwitchProps) {
	return (
		<button
			{...button}
			type={type}
			role="switch"
			className={["switch", className].filter(Boolean).join(" ")}
			aria-checked={checked}
			aria-label={label}
			aria-busy={busy || undefined}
			data-busy={busy ? "true" : undefined}
			disabled={disabled || busy}
		/>
	);
}
