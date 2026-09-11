// Widget traversal is presentation; Rust owns the submitted form and secrets.
import { applicationModule } from "./application.ts";
import type { BridgeAction, BridgeAnswers, BridgeField, BridgeForm } from "../../lib/bridge/form.ts";

export function bridgeFormFields(form: BridgeForm): BridgeField[] {
	return form.fields.flatMap((field) => field.kind === "toggle" ? [field, ...field.reveals] : [field]);
}

/** Refresh untouched defaults while preserving edits to surviving fields.
 * Removed fields and changed field kinds relinquish their local values. */
export function refreshBridgeAnswers(
	previous: BridgeForm,
	form: BridgeForm,
	values: BridgeAnswers,
): BridgeAnswers {
	const before = new Map(bridgeFormFields(previous).map((field) => [field.id, field]));
	const next: BridgeAnswers = {};
	for (const field of bridgeFormFields(form)) {
		if (field.kind === "toggle") continue;
		const old = before.get(field.id);
		const current = values[field.id] ?? "";
		const initial = old?.kind === "text" ? old.value ?? "" : "";
		next[field.id] = old?.kind === field.kind && current !== initial
			? current
			: field.kind === "text"
			? field.value ?? ""
			: "";
	}
	return next;
}

export function refreshBridgeToggles(
	previous: BridgeForm,
	form: BridgeForm,
	current: ReadonlySet<string>,
): ReadonlySet<string> {
	const before = new Map(previous.fields.map((field) => [field.id, field]));
	const next = new Set<string>();
	for (const field of form.fields) {
		if (field.kind !== "toggle") continue;
		const old = before.get(field.id);
		const on = old?.kind === "toggle" && current.has(field.id) !== old.on ? current.has(field.id) : field.on;
		if (on) next.add(field.id);
	}
	return next;
}
export function bridgeFormSubmission(
	form: BridgeForm,
	action: BridgeAction,
	values: BridgeAnswers,
	toggles: ReadonlySet<string>,
): { answers: BridgeAnswers; secrets: BridgeAnswers } | { why: string } {
	return JSON.parse(
		applicationModule().prepareBridgeForm(JSON.stringify(form), action.id, JSON.stringify(values), [...toggles]),
	);
}
