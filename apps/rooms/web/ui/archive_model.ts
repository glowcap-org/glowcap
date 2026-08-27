// Presentation-only state for where this tab records member history. The live
// Session and Ref stay below the store; this value is only what Settings draws.

export type ArchiveTargetView =
	| { readonly kind: "device" }
	| {
		readonly kind: "peer";
		readonly status: "connecting" | "connected" | "unavailable";
		readonly label: string;
		readonly remembered: boolean;
		readonly error: string;
	};

/** One read-only archive facet offered over a direct line. Its Ref stays in
 * the network layer; this row is only the bounded choice the conversation card
 * draws. */
export interface ArchiveShareView {
	readonly id: string;
	readonly conversationKey: string;
	readonly from: string;
	readonly status: "offered" | "reading" | "unavailable";
	readonly error: string;
}
