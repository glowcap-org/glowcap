// Remembered operations swiss numbers, opt-in per capability.
//
// A swiss number is a secret, so nothing here runs unasked: the take modal's
// "Remember on this device" is the only writer, and what it writes is keyed
// by the capability AND the home it was redeemed on — the directory session
// for the session-fetched capabilities, the timeline endpoint's URL for viz —
// so a remembered name is never offered to a different server. The same drop
// that lets a capability go erases its remembered copy, and a failed
// auto-redeem erases it too: a dead secret must not linger or retry forever.
// What is stored sits readably in localStorage, and a swiss number is bearer
// authority — whoever reads it can redeem the capability from any client, not
// only this page — which is exactly what the take modal's hint says out loud.

import { LS } from "../storage.ts";
import { type OpsCap, type OpsScope, opsSwissKey } from "../types.ts";

/** Keep `pasted` for `cap` on `home`, replacing any earlier memory. */
export function rememberOpsSwiss(cap: OpsCap, home: OpsScope, pasted: string): void {
	LS.set(opsSwissKey(cap, home), pasted.trim());
}

/** Erase what was remembered for `cap` on `home`. Idempotent. */
export function forgetOpsSwiss(cap: OpsCap, home: OpsScope): void {
	LS.remove(opsSwissKey(cap, home));
}

/** What this browser remembers for `cap` on `home`, or null. */
export function rememberedOpsSwiss(cap: OpsCap, home: OpsScope): string | null {
	return LS.get(opsSwissKey(cap, home));
}
