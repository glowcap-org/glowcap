// One interpretation of a new composer submission for every Rooms controller.
// The result retains asynchronous command completion; admission is not success.

import { applicationModule } from "../application.ts";
import type { CommandPowers } from "../commands.ts";
import { applyCommandPlan, type Effect } from "../commands/execute.ts";
import { type Conv, conversationTakesFiles } from "../types.ts";
import type { DraftPreview } from "../link_preview.ts";

export interface ComposerDraft {
	readonly text: string;
	readonly files: readonly File[];
	readonly keeping?: readonly unknown[];
	readonly previews: readonly DraftPreview[];
}

export type PreparedComposerSend =
	| { kind: "nothing" }
	| { kind: "handled"; original: string; retires?: "conversation" | "directory"; completion?: Promise<void> }
	| { kind: "refused"; why: string }
	| { kind: "send"; original: string; text: string; files: readonly File[]; previewUrls: readonly string[] };

export function composerLineRefusal(conv: Conv, text: string): string | null {
	return applicationModule().composerLineRefusal(text, conv.type === "room" ? conv.lineBytes : undefined) ?? null;
}

export type ComposerPlan =
	| { kind: "nothing" }
	| { kind: "refused"; why: string }
	| Extract<PreparedComposerSend, { kind: "send" }>
	| { kind: "command"; plan: Effect; original: string };

type Prepared =
	| { kind: "nothing" }
	| { kind: "refused"; why: string }
	| { kind: "send"; text: string }
	| { kind: "command"; plan: Effect };

export function prepareComposerSend(
	conv: Conv | null,
	draft: ComposerDraft,
	powers: CommandPowers,
): PreparedComposerSend {
	return applyComposerPlan(planComposerSend(conv, draft, powers), conv, powers);
}

/** Interpret without executing. A queued gesture owns this bounded plan. */
export function planComposerSend(conv: Conv | null, draft: ComposerDraft, powers: CommandPowers): ComposerPlan {
	const original = draft.text;
	const files = [...draft.files];
	const prepared = JSON.parse(
		applicationModule().prepareComposer(JSON.stringify({
			text: original,
			place: conv?.type === "dm" ? "direct" : conv?.type ?? "none",
			you: powers.you(),
			away: powers.standingHere() !== "",
			lineLimit: conv?.type === "room" ? conv.lineBytes ?? null : null,
			canPostFiles: conversationTakesFiles(conv),
			files: files.map((file) => ({
				name: file.name,
				mime: file.type || "application/octet-stream",
				size: file.size,
			})),
			keeping: draft.keeping != null,
		})),
	) as Prepared;
	if (prepared.kind === "nothing" || prepared.kind === "refused") return prepared;
	if (prepared.kind === "command") {
		return { ...prepared, original };
	}
	return {
		kind: "send",
		original,
		text: prepared.text,
		files,
		previewUrls: draft.previews.filter((preview) => preview.state !== "removed").map((preview) => preview.url),
	};
}

export function applyComposerPlan(plan: ComposerPlan, conv: Conv | null, powers: CommandPowers): PreparedComposerSend {
	if (plan.kind !== "command") return plan;
	const outcome = applyCommandPlan(plan.plan, powers, conv);
	if (outcome.kind === "refused") return outcome;
	if (outcome.kind !== "done") throw new Error("A Rust command gesture unexpectedly produced a message");
	return { kind: "handled", original: plan.original, retires: outcome.retires, completion: outcome.completion };
}
