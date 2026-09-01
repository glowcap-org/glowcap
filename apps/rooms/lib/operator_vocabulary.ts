/** The bounded operator inventory axes shared by the server, durable session,
 * clients, and UI. Operation verb strings live in protocol_operator.ts; this leaf
 * owns only category and exact reference-kind classification. */

export const OPERATOR_CATEGORIES = [
	"stewardships",
	"links",
	"registrations",
	"sessions",
	"rooms",
	"references",
	"trouble",
] as const;
export type OperatorCategory = (typeof OPERATOR_CATEGORIES)[number];

export const OPERATOR_REFERENCE_KINDS = [
	"membership",
	"line",
	"upload",
	"foreign-room",
	"pending-peering",
	"registration",
	"offered-inbox",
	"signaling",
	"signal-exchange",
] as const;
export type OperatorReferenceKind = (typeof OPERATOR_REFERENCE_KINDS)[number];
export type OperatorResetScope = "links" | "registrations" | "sessions" | "rooms" | "runtime" | "all";

export function isOperatorCategory(value: unknown): value is OperatorCategory {
	return typeof value === "string" && (OPERATOR_CATEGORIES as readonly string[]).includes(value);
}

export function isOperatorReferenceKind(value: unknown): value is OperatorReferenceKind {
	return typeof value === "string" && (OPERATOR_REFERENCE_KINDS as readonly string[]).includes(value);
}
