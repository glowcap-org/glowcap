// The tasks board server, written on pancake actors in native Deno.
//
// It hosts one shared task board and accepts any number of OCapN clients over
// TCP — in any language. Each client can add tasks, mark them done, list them,
// and watch for changes. Watchers are notified through capability callbacks
// whenever the board changes — no one polls.
//
// `add` returns the new task's ID as a real reply — request-response, not
// fire-and-forget. When any client mutates the board, every watcher is called
// back with the full current state through the capability it handed us. That
// capability is a return address, not caller identity or authorization: every
// holder of the shared board capability has the same board access.
//
// Run it with a port:  deno run --allow-ffi --allow-net --allow-read server.ts 9099
// With port 0 it binds an ephemeral port and prints it, which the demo harness
// reads to point clients at the right place.

import { type Argument, Ref, Session } from "@pancake/runtime";
import * as tcp from "@pancake/tcp";
import { ADD, BOARD, DONE, LIST, WATCH } from "./protocol.ts";
import { TaskBoardState } from "./board_state.ts";
import { serveAcceptedSession } from "./lifecycle.ts";
import { TaskWatcherTable } from "./watchers.ts";

const board = new TaskBoardState();
const watchers = new TaskWatcherTable((message, error) => console.error(`[tasks] ${message}:`, error));

/** Push the full current task list to every watcher through the capability it
 * gave us. `tell` is the fire-and-forget eventual-send: an update wants no reply,
 * so it costs one deliver with no answer round-trip. A dead watcher is dropped. */
function notifyAll(): void {
	if (watchers.length === 0) return;
	watchers.notify(board.snapshot());
}

function boardBehavior(session: Session) {
	return (verb: string, args: Argument[]): Argument => {
		if (verb === ADD) {
			const text = typeof args[0] === "string" ? args[0] : "";
			const id = board.add(text);
			notifyAll();
			return BigInt(id);
		}
		if (verb === DONE) {
			const id = typeof args[0] === "bigint" ? Number(args[0]) : NaN;
			if (Number.isNaN(id)) throw new Error("done needs an integer task id");
			board.done(id);
			notifyAll();
			return "ok";
		}
		if (verb === LIST) {
			return board.snapshot();
		}
		if (verb === WATCH) {
			const ref = args[0];
			if (!(ref instanceof Ref)) {
				throw new Error("watch needs a watcher capability");
			}
			watchers.register(session, ref);
			return "watching";
		}
		throw new Error(`board has no method ${verb}`);
	};
}

const port = Number(Deno.args[0] ?? "0");
const server = await tcp.listen("127.0.0.1", port);
console.log(`TASKS-SERVER-LISTENING ${server.port}`);

for await (const session of server) {
	serveAcceptedSession(
		session,
		() => session.publish(BOARD, boardBehavior(session)),
		() => watchers.remove(session),
		(what, error) => console.error(`[tasks] ${what} failed:`, error),
	);
}
