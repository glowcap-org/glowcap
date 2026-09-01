// Presentation-only state for where this tab records member history. The live
// Session and Ref stay below the store; this value is only what Settings draws.

export type ArchiveOwner = "browser" | "session";

export type ArchiveTargetView =
	& { readonly owner: ArchiveOwner }
	& (
		| { readonly kind: "owned" }
		| {
			readonly kind: "peer";
			readonly status: "connecting" | "connected" | "unavailable";
			readonly label: string;
			readonly remembered: boolean;
			readonly error: string;
		}
	);

/** One archive account offered over a direct line. Live facets keep their Ref
 * in the network layer; durable offers are sturdyrefs whose Host publication
 * the issuer can revoke independently. This row is only the bounded choice the
 * conversation card draws. */
export interface ArchiveShareView {
	readonly id: string;
	readonly conversationKey: string;
	readonly from: string;
	readonly status: "offered" | "reading" | "unavailable";
	readonly error: string;
	readonly kind: "direct" | "room" | "standing";
	readonly scopeConversation: string | null;
	readonly custody: "live" | "durable";
	readonly sturdyref: string;
}
