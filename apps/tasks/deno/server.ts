// The tasks board server, written on pancake actors in native Deno.
//
// It hosts one shared task board and accepts any number of OCapN clients over
// TCP — in any language. Each client can add tasks, mark them done, list them,
// and watch for changes. Watchers are notified through capability callbacks
// whenever the board changes — no one polls.
//
// `add` returns the new task's ID as a real reply — request-response, not
// fire-and-forget. When any client mutates the board, every watcher is called
// back with the full current state through the capability it handed us. The
// capability the watcher arrives on is the identity: you cannot watch as someone
// else, because you only hold your own.
//
// Run it with a port:  deno run --allow-ffi --allow-net --allow-read server.ts 9099
// With port 0 it binds an ephemeral port and prints it, which the demo harness
// reads to point clients at the right place.

import { type AppValue, listen, Ref, Session } from "@pancake/stack";
import { ADD, BOARD, DONE, LIST, UPDATE, WATCH } from "./protocol.ts";

interface Task {
	id: number;
	text: string;
	completed: boolean;
}

interface Watcher {
	ref: Ref;
	session: Session;
}

const tasks: Task[] = [];
const watchers: Watcher[] = [];
let nextId = 1;

function snapshot(): AppValue {
	return tasks.map((t) => [BigInt(t.id), t.text, t.completed]);
}

function removeWatcher(session: Session): void {
	const i = watchers.findIndex((w) => w.session === session);
	if (i >= 0) watchers.splice(i, 1);
}

/** Push the full current task list to every watcher through the capability it
 * gave us. `tell` is the fire-and-forget eventual-send: an update wants no reply,
 * so it costs one deliver with no answer round-trip. A dead watcher is dropped. */
function notifyAll(): void {
	const snap = snapshot();
	for (const w of [...watchers]) {
		w.session.tell(w.ref, UPDATE, [snap]).catch(() => removeWatcher(w.session));
	}
}

function boardBehavior(session: Session) {
	return (verb: string, args: AppValue[]): AppValue => {
		if (verb === ADD) {
			const text = typeof args[0] === "string" ? args[0] : "";
			if (text.length === 0) throw new Error("add needs a non-empty text");
			const id = nextId++;
			tasks.push({ id, text, completed: false });
			notifyAll();
			return BigInt(id);
		}
		if (verb === DONE) {
			const id = typeof args[0] === "bigint" ? Number(args[0]) : NaN;
			if (Number.isNaN(id)) throw new Error("done needs an integer task id");
			const task = tasks.find((t) => t.id === id);
			if (!task || task.completed) {
				throw new Error(`task ${id} not found or already done`);
			}
			task.completed = true;
			notifyAll();
			return "ok";
		}
		if (verb === LIST) {
			return snapshot();
		}
		if (verb === WATCH) {
			const ref = args[0];
			if (!(ref instanceof Ref)) {
				throw new Error("watch needs a watcher capability");
			}
			watchers.push({ ref, session });
			return "watching";
		}
		throw new Error(`board has no method ${verb}`);
	};
}

const port = Number(Deno.args[0] ?? "0");
const server = listen("127.0.0.1", port);
console.log(`TASKS-SERVER-LISTENING ${await server.ready()}`);

for await (const session of server) {
	session.publish(BOARD, boardBehavior(session)); // fetchable by name
	session.serve().catch(() => removeWatcher(session));
}
