// Joins the class names a component owns with the one its caller adds. A
// part that is absent (`undefined`, `null`, `false`, or empty) drops out, so
// a caller writes `classNames("button", className)` and a condition inline.

export function classNames(...parts: Array<string | false | null | undefined>): string {
	return parts.filter(Boolean).join(" ");
}
