// Bounded durable admission for room-link invitations.

import * as z from "zod/mini";
import { MAX_PENDING_INVITES } from "../lib/limits.ts";
import { WorkspaceInvitationSchema } from "../lib/rooms_state.ts";
import type { DurableRoomsSessionState } from "./state.ts";
import { applyRoomsSessionCommand, roomsSessionCommandImpact } from "./commands.ts";

export interface IncomingRoomInvitation {
	directory: string;
	label: string;
	link: string;
	from: string;
	locator: string;
	nick: string;
}

/** Serialize base-revision selection without admitting an unbounded promise
 * chain. One durable room link is one pending invitation regardless of how
 * often its sender retries it. */
export class RoomInvitationAdmission {
	readonly #state: DurableRoomsSessionState;
	readonly #pending = new Map<string, Promise<void>>();
	#tail: Promise<void> = Promise.resolve();

	constructor(state: DurableRoomsSessionState) {
		this.#state = state;
	}

	admit(incoming: IncomingRoomInvitation): Promise<void> {
		const parsed = z.safeParse(WorkspaceInvitationSchema, {
			kind: "room-link",
			id: crypto.randomUUID(),
			...incoming,
		});
		if (!parsed.success) return Promise.reject(new Error("received an invalid room-link invitation"));
		const invitation = parsed.data;
		const existing = this.#pending.get(invitation.link);
		if (existing != null) return existing;
		const stored = this.#state.snapshot().checkpoint.invitations;
		if (stored.some((entry) => entry.link === invitation.link)) return Promise.resolve();
		const occupied = new Set(stored.map((entry) => entry.link));
		for (const link of this.#pending.keys()) occupied.add(link);
		if (occupied.size >= MAX_PENDING_INVITES) {
			return Promise.reject(new Error("the room-link invitation admission queue is full"));
		}
		const run = this.#tail.then(async () => {
			const snapshot = this.#state.snapshot();
			await this.#state.mutate({
				operationId: `receive-invitation:${invitation.id}`,
				baseRevision: snapshot.revision,
				material: JSON.stringify(["receiveRoomLinkInvitation", invitation]),
				impact: roomsSessionCommandImpact("receiveRoomLinkInvitation"),
				change: (current) =>
					applyRoomsSessionCommand(current, "receiveRoomLinkInvitation", [JSON.stringify(invitation)]),
			});
		});
		this.#tail = run.then(() => {}, () => {});
		const admitted = run.finally(() => {
			if (this.#pending.get(invitation.link) === admitted) this.#pending.delete(invitation.link);
		});
		this.#pending.set(invitation.link, admitted);
		return admitted;
	}
}
