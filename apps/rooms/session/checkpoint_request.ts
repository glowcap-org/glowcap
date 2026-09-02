// Inbound wire envelope shared by durable checkpoint replacement and adoption.

import type { Argument } from "@glowcap/runtime";
import { parseRoomsSessionState, type RoomsSessionState } from "../lib/rooms_state.ts";
import { validateOperationId } from "./effects.ts";

export interface RoomsCheckpointRequest {
	operationId: string;
	baseRevision: number;
	checkpoint: RoomsSessionState;
}

export function parseRoomsCheckpointRequest(args: Argument[], verb: string): RoomsCheckpointRequest {
	if (
		args.length !== 3 || typeof args[0] !== "string" || typeof args[1] !== "bigint" ||
		args[1] < 0n || args[1] > BigInt(Number.MAX_SAFE_INTEGER) || typeof args[2] !== "string"
	) throw new Error(`${verb} takes an operation id, base revision, and checkpoint`);
	const operationId = validateOperationId(args[0]);
	const checkpoint = parseRoomsSessionState(args[2]);
	if (checkpoint == null) throw new Error(`${verb} received an invalid checkpoint`);
	return { operationId, baseRevision: Number(args[1]), checkpoint };
}
