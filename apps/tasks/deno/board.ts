// An interactive tasks client, the one you manage tasks in.
//
// It joins a board by name, shows both lists, and accepts commands: `add <text>`,
// `done <index>` (an index in "To do"), `list`, and `quit`. It lists again after
// each change. Ctrl-D leaves.
//
//   deno run --allow-ffi --allow-read --allow-net board.ts 127.0.0.1 9099 <board-name>

import { TaskBoard, type TaskList } from "./task_client.ts";

const [host, portStr, name] = Deno.args;
if (!host || !portStr || !name) {
	console.error("usage: board.ts <host> <port> <board-name>");
	Deno.exit(2);
}

const board = await TaskBoard.join(host, Number(portStr), name);
console.log("(connected, commands: add <text>, done <index>, list, quit)");
printLists(await board.lists());
await readCommands();
await board.leave();

function printLists(lists: TaskList[]): void {
	for (const list of lists) {
		console.log(`${list.name} (${list.tasks.length})`);
		list.tasks.forEach((task, i) => console.log(`  ${i}: ${task}`));
	}
}

async function readCommands(): Promise<void> {
	for await (const line of typedLines()) {
		const trimmed = line.trim();
		if (trimmed.length === 0) continue;
		if (trimmed === "quit" || trimmed === "q") break;
		try {
			if (trimmed === "list") {
				printLists(await board.lists());
			} else if (trimmed.startsWith("add ")) {
				const text = trimmed.slice(4).trim();
				if (text.length === 0) {
					console.log("  (need text after 'add')");
					continue;
				}
				await board.add(text);
				console.log("  added a task");
				printLists(await board.lists());
			} else if (trimmed.startsWith("done ")) {
				const index = Number(trimmed.slice(5).trim());
				if (!Number.isInteger(index) || index < 0) {
					console.log("  (need a task index after 'done')");
					continue;
				}
				await board.done(await board.task(index));
				printLists(await board.lists());
			} else {
				console.log("  commands: add <text>, done <index>, list, quit");
			}
		} catch (error) {
			console.log(`  refused: ${error instanceof Error ? error.message : error}`);
		}
	}
}

function prompt(): void {
	Deno.stdout.writeSync(new TextEncoder().encode("tasks> "));
}

async function* typedLines(): AsyncGenerator<string> {
	const decoder = new TextDecoder();
	let rest = "";
	prompt();
	for await (const chunk of Deno.stdin.readable) {
		const text = rest + decoder.decode(chunk, { stream: true });
		const pieces = text.split("\n");
		rest = pieces.pop() ?? "";
		for (const piece of pieces) {
			yield piece;
			prompt();
		}
	}
	if (rest.trim().length > 0) yield rest;
}
