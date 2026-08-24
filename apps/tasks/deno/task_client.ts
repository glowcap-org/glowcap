import * as tcp from "@pancake/tcp";
// A small, friendly client for the tasks board, built on pancake actors.
//
// On the connection API this is barely a layer: connect, fetch the board by
// name, publish a watcher the board can call back, and surface its updates as a
// stream. Everything above it reads like an app, not like a protocol.
//
//   const board = await TaskBoard.join("127.0.0.1", 9099);
//   const id = await board.add("buy groceries");
//   await board.done(id);
//   for await (const tasks of board.updates) console.log(tasks);
//   await board.leave();

import { type Argument, type Ref, Runtime, type Session } from "@pancake/runtime";
import { ADD, BOARD, DONE, LIST, UPDATE, WATCH } from "./protocol.ts";
import { type Task } from "./board_state.ts";
import { closeFailedJoin } from "./lifecycle.ts";
import { MAX_SNAPSHOT_TEXT_BYTES, MAX_TASKS, validateTaskText } from "./limits.ts";
import { LatestSnapshotStream } from "./snapshot_stream.ts";

export type { Task } from "./board_state.ts";

function parseTaskId(raw: unknown, context: string): number {
	if (typeof raw !== "bigint" || raw <= 0n || raw > BigInt(Number.MAX_SAFE_INTEGER)) {
		throw new Error(`${context} must be a positive safe integer`);
	}
	return Number(raw);
}

export function parseSnapshot(raw: Argument): Task[] {
	if (!Array.isArray(raw) || raw.length > MAX_TASKS) throw new Error("malformed task snapshot");
	const ids = new Set<number>();
	let textBytes = 0;
	return raw.map((entry) => {
		if (!Array.isArray(entry) || entry.length !== 3) throw new Error("malformed task snapshot entry");
		const id = parseTaskId(entry[0], "task id");
		if (ids.has(id)) throw new Error(`duplicate task id ${id}`);
		ids.add(id);
		if (typeof entry[1] !== "string" || typeof entry[2] !== "boolean") {
			throw new Error("malformed task snapshot entry");
		}
		textBytes += validateTaskText(entry[1]);
		if (textBytes > MAX_SNAPSHOT_TEXT_BYTES) throw new Error("task snapshot text budget exceeded");
		return { id, text: entry[1], completed: entry[2] };
	});
}

export class TaskBoard {
	#session: Session;
	#runtime: Runtime;
	#board: Ref;
	readonly #snapshotStream = new LatestSnapshotStream<Task[]>();
	#leaving = false;

	/** A stream of task-list snapshots: every change pushes the full current
	 * state. Ends when you `leave` or the board hangs up. */
	readonly updates: ReadableStream<Task[]>;

	private constructor(runtime: Runtime, session: Session, board: Ref) {
		this.#runtime = runtime;
		this.#session = session;
		this.#board = board;
		this.updates = this.#snapshotStream.readable;
	}

	static async join(host: string, port: number): Promise<TaskBoard> {
		const runtime = await Runtime.open({ providers: [tcp.provider()] });
		let session: Session | null = null;
		let owner: TaskBoard | null = null;
		try {
			session = await runtime.connect(tcp.locator(host, port));
			const board = await session.fetch(BOARD);
			const self = new TaskBoard(runtime, session, board);
			owner = self;
			self.#startServing();
			const watcher = session.spawn((verb, args) => {
				if (verb !== UPDATE) throw new Error(`watcher has no method ${verb}`);
				self.#push(args[0]);
				return null;
			});
			await session.send(board, WATCH, [watcher]);
			return owner;
		} catch (error) {
			if (owner !== null) owner.#leaving = true;
			return await closeFailedJoin(
				session,
				runtime,
				error,
				(what, closeError) => console.error(`tasks: failed to close ${what}:`, closeError),
			);
		}
	}

	#startServing(): void {
		let serving: Promise<void>;
		try {
			serving = this.#session.serve();
		} catch (error) {
			this.#endStream();
			throw error;
		}
		void serving.then(
			() => this.#endStream(),
			(error) => {
				if (!this.#leaving) console.error("tasks: the board connection failed:", error);
				this.#endStream();
			},
		).catch((error) => {
			console.error("tasks: session failure handling failed:", error);
			this.#endStream();
		});
	}

	/** Add a task. Returns the new task's ID. */
	async add(text: string): Promise<number> {
		const result = await this.#session.send(this.#board, ADD, [text]);
		return parseTaskId(result, "add result");
	}

	/** Mark a task as completed. */
	async done(id: number): Promise<void> {
		await this.#session.send(this.#board, DONE, [BigInt(id)]);
	}

	/** Get the current task list (a one-shot query). */
	async list(): Promise<Task[]> {
		return parseSnapshot(await this.#session.send(this.#board, LIST, []));
	}

	async leave(): Promise<void> {
		this.#leaving = true;
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

	#push(raw: Argument): void {
		this.#snapshotStream.push(parseSnapshot(raw));
	}

	#endStream(): void {
		if (!this.#leaving) console.error("tasks: the board closed the connection");
		this.#snapshotStream.close();
	}
}
