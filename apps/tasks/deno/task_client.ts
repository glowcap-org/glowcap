// A small client for the tasks board, built on glowcap actors.
//
// The board is a secret-named capability with two lists, "To do" first and
// "Done" second. Every change is a receipt-backed call: ask the target for a
// fresh `mutation-sequence`, then `mutate` with that number, so a retried
// change applies once. Adding a task returns the task, and `done` moves that
// task. A watcher reports whether anything on the board changed since its last
// look, and `stop` frees the board's observation context.
//
//   const board = await TaskBoard.join("127.0.0.1", 9099, boardName);
//   const watcher = await board.watch();
//   const task = await board.add("buy groceries");
//   await board.done(task);
//   console.log(await board.lists(), await watcher.changed());
//   await watcher.stop();
//   await board.leave();

import * as tcp from "@glowcap/tcp";
import { type Argument, type Ref, Runtime, type Session, Tagged } from "@glowcap/runtime";

export interface TaskList {
	name: string;
	tasks: string[];
}

/** A task on the board, named by its capability. */
export class Task {
	constructor(readonly ref: Ref) {}
}

function ref(value: unknown, what: string): Ref {
	if (value === null || typeof value !== "object") throw new Error(`${what} was not a capability`);
	return value as Ref;
}

function integer(value: unknown, what: string): bigint {
	if (typeof value !== "bigint") throw new Error(`${what} was not an integer`);
	return value;
}

function text(value: unknown, what: string): string {
	if (typeof value !== "string") throw new Error(`${what} was not text`);
	return value;
}

/** Reports whether the board changed since the last look. */
export class Watcher {
	#session: Session;
	#receiver: Ref;
	#canceller: Ref;
	#cursor: Uint8Array;

	constructor(session: Session, receiver: Ref, canceller: Ref, cursor: Uint8Array) {
		this.#session = session;
		this.#receiver = receiver;
		this.#canceller = canceller;
		this.#cursor = cursor;
	}

	static async start(session: Session, receiver: Ref, canceller: Ref): Promise<Watcher> {
		return new Watcher(session, receiver, canceller, (await Watcher.#observe(session, receiver, [])).cursor);
	}

	static async #observe(
		session: Session,
		receiver: Ref,
		args: Argument[],
	): Promise<{ cursor: Uint8Array; changed: boolean }> {
		const reply = await session.send(receiver, "poll", args);
		if (!(reply instanceof Tagged) || reply.value.length !== 5) throw new Error("the watcher sent no observation");
		// Loam's `access:observation` record, see docs/loam/access-observation.md:
		// the cursor comes first and the fourth field is whether anything changed.
		const [cursor, , , changed] = reply.value;
		if (!(cursor instanceof Uint8Array) || typeof changed !== "boolean") {
			throw new Error("the watcher sent no observation");
		}
		return { cursor, changed };
	}

	/** Whether anything on the board changed since the previous look. */
	async changed(): Promise<boolean> {
		const seen = await Watcher.#observe(this.#session, this.#receiver, [this.#cursor]);
		this.#cursor = seen.cursor;
		return seen.changed;
	}

	/** Close the board's observation context. Call it once when done watching. */
	async stop(): Promise<void> {
		const closed = await this.#session.send(this.#canceller, "cancel", []);
		if (typeof closed !== "boolean") throw new Error("cancelling the watcher returned no boolean");
	}
}

export class TaskBoard {
	#runtime: Runtime;
	#session: Session;
	#board: Ref;
	#todo: Ref;
	#done: Ref;

	private constructor(runtime: Runtime, session: Session, board: Ref, todo: Ref, done: Ref) {
		this.#runtime = runtime;
		this.#session = session;
		this.#board = board;
		this.#todo = todo;
		this.#done = done;
	}

	static async join(host: string, port: number, name: string): Promise<TaskBoard> {
		const runtime = await Runtime.open({ providers: [tcp.provider()] });
		try {
			const session = await runtime.connect(tcp.locator(host, port));
			session.serve().catch((error: unknown) => console.error("tasks: the board connection failed:", error));
			const board = ref(await session.fetch(name), "board");
			const todo = ref(await session.send(board, "list", [0n]), "list 0");
			const done = ref(await session.send(board, "list", [1n]), "list 1");
			return new TaskBoard(runtime, session, board, todo, done);
		} catch (error) {
			await runtime.close().catch(() => {}); // tolerant: the join already failed, and that error is the one rethrown.
			throw error;
		}
	}

	async #mutate(target: Ref, ...args: Argument[]): Promise<unknown> {
		const seq = integer(await this.#session.send(target, "mutation-sequence", []), "mutation sequence");
		return await this.#session.send(target, "mutate", [seq, ...args]);
	}

	/** Add a task to "To do". Returns the new task. */
	async add(text: string): Promise<Task> {
		return new Task(ref(await this.#mutate(this.#todo, "add", text), "added task"));
	}

	/** The "To do" task at `index`. */
	async task(index: number): Promise<Task> {
		return new Task(ref(await this.#session.send(this.#todo, "task", [BigInt(index)]), "task"));
	}

	/** Move `task` from "To do" to the end of "Done". */
	async done(task: Task): Promise<void> {
		await this.#mutate(this.#todo, "move", task.ref, this.#done);
	}

	/** Start watching the board for changes. */
	async watch(): Promise<Watcher> {
		const reply = await this.#mutate(this.#board, "observe");
		if (!Array.isArray(reply)) throw new Error("watching returned no receiver");
		return await Watcher.start(this.#session, ref(reply[0], "watch receiver"), ref(reply[1], "watch canceller"));
	}

	/** Read both lists, "To do" first. */
	async lists(): Promise<TaskList[]> {
		const read = async (list: Ref): Promise<TaskList> => {
			const name = text(await this.#session.send(list, "name", []), "list name");
			const count = Number(integer(await this.#session.send(list, "count", []), "list count"));
			const tasks: string[] = [];
			for (let i = 0; i < count; i++) {
				const task = ref(await this.#session.send(list, "task", [BigInt(i)]), "task");
				tasks.push(text(await this.#session.send(task, "text", []), "task text"));
			}
			return { name, tasks };
		};
		return [await read(this.#todo), await read(this.#done)];
	}

	async leave(): Promise<void> {
		const failures: unknown[] = [];
		try {
			await this.#session.close();
		} catch (error) {
			failures.push(error);
		}
		try {
			await this.#runtime.close();
		} catch (error) {
			failures.push(error);
		}
		if (failures.length === 1) throw failures[0];
		if (failures.length > 1) throw new AggregateError(failures, "tasks board leave failed");
	}
}
