// Remembered operations swiss numbers inside the versioned Rooms state bundle.
//
// A swiss number is a secret, so nothing here runs unasked: the saved
// capability-set editor is the only writer, and what it writes is keyed
// by the capability AND the home it was redeemed on — the directory session
// for the session-fetched capabilities, the timeline endpoint's URL for viz —
// so a remembered name is never offered to a different server. The same drop
// that lets a capability go erases its remembered copy, and a failed
// auto-redeem erases it too: a dead secret must not linger or retry forever.
// The bundle remains readable in browser storage and when exported, and a swiss
// number is bearer authority — whoever reads it can redeem the capability from
// any client, not only this page — which is exactly what its value modal says.

import type { OpsCap, OpsScope } from "../types.ts";
import {
	rememberedWorkspaceOperation,
	rememberedWorkspaceOperations,
	setRememberedWorkspaceOperation,
	setRememberedWorkspaceOperations,
} from "../workspace_state.ts";

/** Keep `pasted` for `cap` on `home`, replacing any earlier memory. */
export function rememberOpsSwiss(cap: OpsCap, home: OpsScope, pasted: string): boolean {
	if (pasted !== pasted.trim()) return false;
	return setRememberedWorkspaceOperation(cap, home, pasted);
}

/** Erase what was remembered for `cap` on `home`. Idempotent. */
export function forgetOpsSwiss(cap: OpsCap, home: OpsScope): boolean {
	return setRememberedWorkspaceOperation(cap, home, null);
}

/** What this browser remembers for `cap` on `home`, or null. */
export function rememberedOpsSwiss(cap: OpsCap, home: OpsScope): string | null {
	return rememberedWorkspaceOperation(cap, home);
}

export function rememberedOpsCredentials() {
	return rememberedWorkspaceOperations();
}

export function replaceOpsCredentials(credentials: ReturnType<typeof rememberedWorkspaceOperations>): boolean {
	return setRememberedWorkspaceOperations(credentials);
}
