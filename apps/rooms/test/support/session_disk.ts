// File-backed session documents for Deno tests that already own a temp directory.

import { fileSessionDocuments } from "../../session/file_documents.ts";
import { DurableRoomsSessionGrants, type RoomsSessionGrantPublisher } from "../../session/grants.ts";
import { DurableRoomsSessionState } from "../../session/state.ts";
import type { RoomsSessionResultApplier, RoomsSessionResultValidator } from "../../session/state_contract.ts";

export function openSessionState(
	directory: string,
	applyResult?: RoomsSessionResultApplier,
	validateResult?: RoomsSessionResultValidator,
): Promise<DurableRoomsSessionState> {
	return DurableRoomsSessionState.open(fileSessionDocuments(directory), applyResult, validateResult);
}

export function openSessionGrants(
	directory: string,
	rootEntropy: Uint8Array,
	publisher: RoomsSessionGrantPublisher,
): Promise<DurableRoomsSessionGrants> {
	return DurableRoomsSessionGrants.open(fileSessionDocuments(directory), rootEntropy, publisher);
}
