// A one-shot tasks client for the cross-language demo: join the board and
// watch it, add a task, mark it done, print both lists, and exit 0 once the task
// shows up under "Done" and the watcher saw the board change. The orchestrator
// runs one of these per language.
//
//   deno run --allow-ffi --allow-read --allow-net client.ts 127.0.0.1 9099 \
//     <board-name> deno-alice "buy groceries"

import { TaskBoard } from "./task_client.ts";

const [host, portStr, name, nick, taskText] = Deno.args;
if (!host || !portStr || !name || !nick || !taskText) {
	console.error("usage: client.ts <host> <port> <board-name> <nick> <task-text>");
	Deno.exit(2);
}

const board = await TaskBoard.join(host, Number(portStr), name);
const text = `[${nick}] ${taskText}`;

const watcher = await board.watch();
const task = await board.add(text);
console.log(`${nick}: added a task`);
await board.done(task);
console.log(`${nick}: marked it done`);

const lists = await board.lists();
for (const list of lists) {
	console.log(`${nick}: ${list.name}: ${list.tasks.length} task(s)`);
	for (const task of list.tasks) console.log(`  ${task}`);
}
const watched = await watcher.changed();
await watcher.stop();
await board.leave();

if (!lists[1].tasks.includes(text)) {
	console.error(`${nick}: FAIL, the task is not in the done list`);
	Deno.exit(1);
}
console.log(`${nick}: confirmed the task is done`);
if (!watched) {
	console.error(`${nick}: FAIL, the watcher saw no change`);
	Deno.exit(1);
}
console.log(`${nick}: the watcher saw the board change`);
