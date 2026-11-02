// The choice box of a form, the other control `Field` wires. It owns the
// `field` class that draws the box, the same one `Input` wears, and forwards
// every attribute and its options.

import type { ComponentPropsWithRef } from "react";

export function Select({ className, ...select }: ComponentPropsWithRef<"select">) {
	return <select {...select} className={["field", className].filter(Boolean).join(" ")} />;
}
