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

import { type AppValue, connect, type Ref, type Session, tcpLocator } from "@pancake/stack";
import { ADD, BOARD, DONE, LIST, UPDATE, WATCH } from "./protocol.ts";

export interface Task {
	id: number;
	text: string;
	completed: boolean;
}

function parseSnapshot(raw: AppValue): Task[] {
	if (!Array.isArray(raw)) return [];
	return raw.map((entry) => {
		if (!Array.isArray(entry) || entry.length < 3) {
			return { id: 0, text: "?", completed: false };
		}
		return {
			id: typeof entry[0] === "bigint" ? Number(entry[0]) : Number(entry[0]),
			text: String(entry[1]),
			completed: Boolean(entry[2]),
		};
	});
}

export class TaskBoard {
	#session: Session;
	#board: Ref;
	#snapshots!: ReadableStreamDefaultController<Task[]>;
	#leaving = false;

	/** A stream of task-list snapshots: every change pushes the full current
	 * state. Ends when you `leave` or the board hangs up. */
	readonly updates: ReadableStream<Task[]>;

	private constructor(session: Session, board: Ref) {
		this.#session = session;
		this.#board = board;
		this.updates = new ReadableStream<Task[]>({
			start: (controller) => {
				this.#snapshots = controller;
			},
		});
	}

	static async join(host: string, port: number): Promise<TaskBoard> {
		const session = await connect(tcpLocator(host, port));
		session.serve().catch(() => {});
		const board = await session.fetch(BOARD);
		const self = new TaskBoard(session, board);

		const watcher = session.spawn((verb, args) => {
			if (verb !== UPDATE) throw new Error(`watcher has no method ${verb}`);
			self.#push(args[0]);
			return null;
		});

		session.serve().finally(() => self.#endStream());
		await session.send(board, WATCH, [watcher]);
		return self;
	}

	/** Add a task. Returns the new task's ID. */
	async add(text: string): Promise<number> {
		const result = await this.#session.send(this.#board, ADD, [text]);
		return typeof result === "bigint" ? Number(result) : 0;
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
		this.#session.close();
		await this.#session.serve().catch(() => {});
	}

	#push(raw: AppValue): void {
		try {
			this.#snapshots.enqueue(parseSnapshot(raw));
		} catch {
			// stream already closed
		}
	}

	#endStream(): void {
		if (!this.#leaving) console.error("tasks: the board closed the connection");
		try {
			this.#snapshots.close();
		} catch {
			// already closed
		}
	}
}
