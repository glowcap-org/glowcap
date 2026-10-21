// Types the browser shares about a Rooms session: the controller choice, the
// bridge form a reader answered, and the conversation ceiling the Rust
// application enforces.

import type { BridgeAnswers } from "./bridge/form.ts";

/** Mirrors the Rust workspace conversation limit. */
export const MAX_WORKSPACE_CONVERSATIONS = 256;

/** A bridge form a reader answered, kept so a reconnect can answer it again.
 *
 * What is kept is what the reader chose: which action, within which of the
 * bridge's scopes, and the answers that are not secrets. A secret is never
 * checkpointed. It lives in the runtime until every room in its scope has read
 * it, and a reconnect without one asks the reader again and does not guess.
 *
 * `scope` is the bridge's word for how far one answer reaches, so a reader who
 * linked an identity on one channel finds it on the others without this having
 * to know why. */
export interface WorkspaceRoomBridgeIntent {
	readonly scope: string;
	readonly action: string;
	readonly answers: BridgeAnswers;
	/** Whether the reader answered a secret field.
	 *
	 * The secret itself is never here. Without this flag a replay could not tell
	 * a submission that needed none from one whose password is missing, and
	 * would send a blank where a credential belonged. Both replays read it: a
	 * browser that holds nothing asks the reader again, and a durable runtime
	 * looks in its own storage first. */
	readonly secretsGiven: boolean;
	/** Opaque command identity for matching separately held credentials. It is
	 * public but contains no credential-derived material. */
	readonly credentialRevision?: string | undefined;
}

export type RoomsControllerSelection =
	| { readonly kind: "none" }
	| { readonly kind: "local" }
	| { readonly kind: "attached"; readonly sturdyref: string }
	| { readonly kind: "hosted"; readonly sturdyref: string };

/** A capability-named shared session this browser is attached to or hosting. */
export type SharedRoomsControllerSelection = Extract<
	RoomsControllerSelection,
	{ kind: "attached" } | { kind: "hosted" }
>;
