// An interactive tasks client — the one you actually manage tasks in.
//
// It connects to a task board, prints every change as it arrives, and accepts
// commands: `add <text>`, `done <id>`, `list`. Press Ctrl-D to leave.
//
//   deno run --allow-ffi --allow-read --allow-net board.ts 127.0.0.1 9099

import { type Task, TaskBoard } from "./task_client.ts";

const [host, portStr] = Deno.args;
if (!host || !portStr) {
  console.error("usage: board.ts <host> <port>");
  Deno.exit(2);
}

const board = await TaskBoard.join(host, Number(portStr));
console.log("(connected — commands: add <text>, done <id>, list, quit)");

const initial = await board.list();
printBoard(initial);

await Promise.race([showUpdates(), readCommands()]);
await board.leave();

function printBoard(tasks: Task[]): void {
  if (tasks.length === 0) {
    console.log("  (no tasks)");
    return;
  }
  for (const t of tasks) {
    console.log(`  ${t.completed ? "[x]" : "[ ]"} #${t.id} ${t.text}`);
  }
}

async function showUpdates(): Promise<void> {
  for await (const tasks of board.updates) {
    console.log("\n--- board updated ---");
    printBoard(tasks);
    prompt();
  }
}

async function readCommands(): Promise<void> {
  for await (const line of typedLines()) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;

    if (trimmed === "quit" || trimmed === "q") break;

    if (trimmed === "list") {
      const tasks = await board.list();
      printBoard(tasks);
      continue;
    }

    if (trimmed.startsWith("add ")) {
      const text = trimmed.slice(4).trim();
      if (text.length === 0) { console.log("  (need text after 'add')"); continue; }
      const id = await board.add(text);
      console.log(`  added task #${id}`);
      continue;
    }

    if (trimmed.startsWith("done ")) {
      const id = Number(trimmed.slice(5).trim());
      if (Number.isNaN(id) || id <= 0) { console.log("  (need a task id after 'done')"); continue; }
      try {
        await board.done(id);
        console.log(`  task #${id} completed`);
      } catch {
        console.log(`  task #${id} not found or already done`);
      }
      continue;
    }

    console.log("  commands: add <text>, done <id>, list, quit");
  }
}

function prompt(): void {
  const encoder = new TextEncoder();
  Deno.stdout.writeSync(encoder.encode("tasks> "));
}

async function* typedLines(): AsyncGenerator<string> {
  const decoder = new TextDecoder();
  let rest = "";
  prompt();
  for await (const chunk of Deno.stdin.readable) {
    const text = rest + decoder.decode(chunk, { stream: true });
    const pieces = text.split("\n");
    rest = pieces.pop() ?? "";
    for (const piece of pieces) yield piece;
  }
  if (rest.trim().length > 0) yield rest;
}
