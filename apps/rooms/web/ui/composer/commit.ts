// Commit a submission to its originating conversation. Rust interprets commands.
// Commands retain their submitted plan while the UI accepts the next draft.

import * as store from "../store.ts";
import type { CommandPowers } from "../commands.ts";
import type { Conv } from "../types.ts";
import type { PageProjection } from "../store/core.ts";
import {
	applyComposerPlan,
	type ComposerDraft,
	type ComposerPlan,
	prepareComposerSend,
	type PreparedComposerSend,
} from "./send.ts";

export type CommittedComposerSend = Extract<PreparedComposerSend, { kind: "handled" | "send" }>;

/** Interpret a submission and display immediate refusals. `null` means no effect. */
export function interpretComposerSend(
	projection: PageProjection,
	conv: Conv | null,
	draft: ComposerDraft,
	powers: CommandPowers,
	plan?: ComposerPlan,
): CommittedComposerSend | null {
	const prepared = plan == null ? prepareComposerSend(conv, draft, powers) : applyComposerPlan(plan, conv, powers);
	if (prepared.kind === "nothing") return null;
	if (prepared.kind === "refused") {
		store.deliverActive(projection, store.sysItem(projection, prepared.why));
		return null;
	}
	return prepared;
}
