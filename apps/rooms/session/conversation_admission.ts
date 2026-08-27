// Two-phase admission for an external effect that needs a live conversation.

import type { DurableRoomsRuntime } from "./runtime.ts";
import type { DurableRoomsSessionState } from "./state.ts";

export async function prepareConversationEffect(
	state: DurableRoomsSessionState,
	runtime: DurableRoomsRuntime,
	operationId: string,
	baseRevision: number,
	operationMaterial: string,
	kind: "room" | "direct",
	conversationId: string,
): Promise<{ kind: "prepared" } | { kind: "committed"; revision: number }> {
	const preflight = () => runtime.requireConversation(kind, conversationId);
	let realized = true;
	try {
		preflight();
	} catch {
		realized = false;
		// Retry recognition belongs to durable state and must happen before a
		// disconnected target is allowed to delay or refuse an already-committed act.
	}
	if (realized) return await state.prepareEffect(operationId, baseRevision, operationMaterial, preflight);
	const inspection = await state.inspectEffect(operationId, baseRevision, operationMaterial);
	if (inspection.kind === "committed") return inspection;
	await runtime.realizeConversation(kind, conversationId);
	return await state.prepareInspectedEffect(inspection, operationMaterial, preflight);
}
