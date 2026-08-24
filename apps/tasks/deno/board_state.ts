import { type Argument } from "@pancake/runtime";
import { MAX_SNAPSHOT_TEXT_BYTES, MAX_TASKS, validateTaskText } from "./limits.ts";

export interface Task {
	id: number;
	text: string;
	completed: boolean;
}

/** The authoritative task state and its resource limits. */
export class TaskBoardState {
	readonly #tasks: Task[] = [];
	#snapshotTextBytes = 0;

	add(text: string): number {
		const textBytes = validateTaskText(text);
		if (this.#tasks.length >= MAX_TASKS) throw new Error(`the board already has ${MAX_TASKS} tasks`);
		if (this.#snapshotTextBytes + textBytes > MAX_SNAPSHOT_TEXT_BYTES) {
			throw new Error(`the board snapshot may contain at most ${MAX_SNAPSHOT_TEXT_BYTES} text bytes`);
		}
		const id = this.#tasks.length + 1;
		this.#tasks.push({ id, text, completed: false });
		this.#snapshotTextBytes += textBytes;
		return id;
	}

	done(id: number): void {
		if (!Number.isSafeInteger(id) || id <= 0) throw new Error(`task ${id} not found or already done`);
		const task = this.#tasks[id - 1];
		if (task === undefined || task.completed) {
			throw new Error(`task ${id} not found or already done`);
		}
		task.completed = true;
	}

	get length(): number {
		return this.#tasks.length;
	}

	snapshot(): Argument {
		return this.#tasks.map((task) => [BigInt(task.id), task.text, task.completed]);
	}
}
