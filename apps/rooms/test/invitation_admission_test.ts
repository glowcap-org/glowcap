import { MAX_PENDING_INVITES } from "../lib/limits.ts";
import { emptyRoomsSessionState, type RoomsSessionState } from "../lib/rooms_state.ts";
import { type IncomingRoomInvitation, RoomInvitationAdmission } from "../session/invitation_admission.ts";
import type { DurableRoomsSessionState } from "../session/state.ts";
import { assertEquals } from "./assert.ts";
import { fixtureSturdyref } from "./support/workspace.ts";

interface InvitationMutation {
	change(checkpoint: RoomsSessionState): RoomsSessionState;
}

class ControlledInvitationState {
	checkpoint: RoomsSessionState;
	revision = 0;
	mutations = 0;
	readonly #blocked: Promise<void>;
	readonly #release: () => void;

	constructor(checkpoint = emptyRoomsSessionState()) {
		this.checkpoint = checkpoint;
		let release!: () => void;
		this.#blocked = new Promise((resolve) => release = resolve);
		this.#release = release;
	}

	snapshot() {
		return { revision: this.revision, checkpoint: this.checkpoint };
	}

	async mutate(mutation: InvitationMutation): Promise<number> {
		this.mutations += 1;
		await this.#blocked;
		this.checkpoint = mutation.change(this.checkpoint);
		this.revision += 1;
		return this.revision;
	}

	release(): void {
		this.#release();
	}

	admission(): RoomInvitationAdmission {
		return new RoomInvitationAdmission(this as unknown as DurableRoomsSessionState);
	}
}

function invitation(at: number): IncomingRoomInvitation {
	return {
		directory: "ocapn://directory.id",
		label: `room-${at}`,
		link: fixtureSturdyref("ocapn://directory.id", `room-${at}`),
		from: "bo",
		locator: "ocapn://directory.id",
		nick: "ada",
	};
}

async function refusal(work: Promise<unknown>): Promise<string> {
	try {
		await work;
		return "";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}

Deno.test("repeated in-flight room invitations share one durable admission", async () => {
	const state = new ControlledInvitationState();
	const admission = state.admission();
	const first = admission.admit(invitation(1));
	const repeated = admission.admit(invitation(1));
	assertEquals(first === repeated, true);

	state.release();
	await Promise.all([first, repeated]);
	assertEquals(state.mutations, 1);
	assertEquals(state.checkpoint.invitations.length, 1);
});

Deno.test("room invitation admission bounds the combined durable queue", async () => {
	const state = new ControlledInvitationState();
	const admission = state.admission();
	const admitted = Array.from({ length: MAX_PENDING_INVITES }, (_, at) => admission.admit(invitation(at)));
	assertEquals(
		await refusal(admission.admit(invitation(MAX_PENDING_INVITES))),
		"the room-link invitation admission queue is full",
	);

	state.release();
	await Promise.all(admitted);
	assertEquals(state.checkpoint.invitations.length, MAX_PENDING_INVITES);
});

Deno.test("a repeated stored invitation succeeds even when the durable queue is full", async () => {
	const invitations = Array.from({ length: MAX_PENDING_INVITES }, (_, at) => ({
		kind: "room-link" as const,
		id: `invite-${at}`,
		...invitation(at),
	}));
	const state = new ControlledInvitationState({ ...emptyRoomsSessionState(), invitations });
	await state.admission().admit(invitation(0));
	assertEquals(state.mutations, 0);
	assertEquals(state.checkpoint.invitations, invitations);
});

Deno.test("invalid room invitations are refused before durable admission", async () => {
	const state = new ControlledInvitationState();
	const invalid = { ...invitation(1), link: "not a sturdyref" };
	assertEquals(await refusal(state.admission().admit(invalid)), "received an invalid room-link invitation");
	assertEquals(state.mutations, 0);
	state.release();
});
