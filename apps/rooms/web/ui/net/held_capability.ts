// Imported operations authority retained by one local browser directory.

import type { Ref, Session } from "@glowcap/runtime";
import { settleCapabilityCleanup } from "../../../lib/capability_cleanup.ts";
import type { DirId } from "../types.ts";

export interface HeldDirectoryCapability {
	readonly session: Session;
	readonly cap: Ref;
	readonly dir: DirId;
}

/** Give back one imported occurrence. Local presentation ownership ends even
 * if release reports a diagnostic; the enclosing session remains the terminal
 * owner and reclaims the occurrence when it closes. */
export function releaseHeldCapability(held: HeldDirectoryCapability | null, label: string): void {
	if (held == null) return;
	settleCapabilityCleanup(label, () => held.session.release(held.cap));
}
