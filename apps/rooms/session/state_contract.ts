// Public views and opaque admission tokens produced by durable session state.

export interface PendingEffectDetail {
	id: string;
	kind: string;
	phase: "unresolved" | "prepared" | "completed" | "applied";
	intent: string | null;
}

export const ordinaryEffectInspection: unique symbol = Symbol("Rooms ordinary effect inspection");

export interface NewOrdinaryEffectInspection {
	readonly kind: "new";
	readonly operationId: string;
	readonly digest: string;
	readonly owner: symbol;
	readonly [ordinaryEffectInspection]: true;
}

export type OrdinaryEffectInspection =
	| NewOrdinaryEffectInspection
	| { readonly kind: "committed"; readonly revision: number };

export type RoomsSessionResultApplier = (
	checkpoint: import("../lib/rooms_state.ts").RoomsSessionState,
	kind: string,
	intent: string,
	result: string,
) => import("../lib/rooms_state.ts").RoomsSessionState;
export type RoomsSessionResultValidator = (
	checkpoint: import("../lib/rooms_state.ts").RoomsSessionState,
	kind: string,
	intent: string,
) => void;
