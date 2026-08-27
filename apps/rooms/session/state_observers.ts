// Post-commit checkpoint and effect-status observation for a durable Rooms session.

import type { RoomsSessionState } from "../lib/rooms_state.ts";
import type { RoomsCheckpointImpact } from "./commands.ts";

type StateObserver = (revision: number, checkpoint: RoomsSessionState) => void;
type CheckpointObserver = (
	revision: number,
	checkpoint: RoomsSessionState,
	impact: RoomsCheckpointImpact,
) => void;

export class RoomsSessionStateObservers {
	readonly #state = new Set<StateObserver>();
	readonly #checkpoint = new Set<CheckpointObserver>();

	onState(changed: StateObserver): () => void {
		this.#state.add(changed);
		return () => this.#state.delete(changed);
	}

	onCheckpoint(changed: CheckpointObserver): () => void {
		this.#checkpoint.add(changed);
		return () => this.#checkpoint.delete(changed);
	}

	stateChanged(revision: number, checkpoint: RoomsSessionState): void {
		this.#deliver<[number, RoomsSessionState]>(this.#state, [revision, checkpoint], "state");
	}

	checkpointChanged(revision: number, checkpoint: RoomsSessionState, impact: RoomsCheckpointImpact): void {
		this.#deliver<[number, RoomsSessionState, RoomsCheckpointImpact]>(
			this.#checkpoint,
			[revision, checkpoint, impact],
			"checkpoint",
		);
		this.stateChanged(revision, checkpoint);
	}

	#deliver<Args extends unknown[]>(
		observers: ReadonlySet<(...args: Args) => void>,
		args: Args,
		kind: string,
	): void {
		for (const changed of observers) {
			try {
				changed(...args);
			} catch (error) {
				console.error(
					`rooms session: a ${kind} observer failed after commit: ${
						error instanceof Error ? error.message : error
					}`,
				);
			}
		}
	}
}
