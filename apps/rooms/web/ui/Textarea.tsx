// The multi-line box of a form, the same box `Input` and `Select` draw. It
// owns the `field` class and forwards every attribute, so a caller passes the
// rows, the value, and the wiring and never the look.

import type { ComponentPropsWithRef } from "react";
import { classNames } from "./classes.ts";

export function Textarea({ className, ...textarea }: ComponentPropsWithRef<"textarea">) {
	return <textarea {...textarea} className={classNames("field", className)} />;
}
