// Presentation-only state for where this tab records member history. The live
// Session and Ref stay below the store; this value is only what Settings draws.

export type ArchiveTargetView =
	| { readonly kind: "owned" }
	| {
		readonly kind: "peer";
		readonly status: "connecting" | "connected" | "unavailable";
		readonly label: string;
		readonly error: string;
	};

/** One archive account offered over a direct line. A live offer keeps its
 * reference in the Rust application; a lasting one is a link whose Host
 * publication the issuer can revoke on its own. This row is only the bounded
 * choice the conversation card draws. The link itself is a bearer secret and
 * stays in the session snapshot; a control that copies it asks there at press
 * time (`session/bearer.ts`). */
export interface ArchiveShareView {
	readonly id: string;
	readonly conversationKey: string;
	readonly from: string;
	readonly status: "offered" | "reading" | "unavailable";
	readonly error: string;
	readonly kind: "direct" | "room" | "standing";
	readonly scopeConversation: string | null;
	readonly custody: "live" | "durable";
	/** Whether a lasting offer carries a link this tab could copy. */
	readonly copyable: boolean;
}
