// A one-shot tasks client for the cross-language demo: connect, add a task,
// list, mark it done, list again, and exit. The orchestrator runs one of these
// per language and checks they all succeed.
//
//   deno run --allow-ffi --allow-read --allow-net client.ts 127.0.0.1 9099 \
//     "deno-alice" "buy groceries"

import { TaskBoard } from "./task_client.ts";

const [host, portStr, nick, taskText] = Deno.args;
if (!host || !portStr || !nick || !taskText) {
  console.error("usage: client.ts <host> <port> <nick> <task-text>");
  Deno.exit(2);
}

const board = await TaskBoard.join(host, Number(portStr));

const id = await board.add(`[${nick}] ${taskText}`);
console.log(`${nick}: added task #${id}`);

const before = await board.list();
console.log(`${nick}: ${before.length} task(s) on the board`);
for (const t of before) {
  console.log(`  ${t.completed ? "[x]" : "[ ]"} #${t.id} ${t.text}`);
}

await board.done(id);
console.log(`${nick}: completed task #${id}`);

const after = await board.list();
const ours = after.find((t) => t.id === id);
if (!ours || !ours.completed) {
  console.error(`${nick}: FAIL — task #${id} not marked completed`);
  await board.leave();
  Deno.exit(1);
}
console.log(`${nick}: confirmed task #${id} is done`);

await board.leave();
