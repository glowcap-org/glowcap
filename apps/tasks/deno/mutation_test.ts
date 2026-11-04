// Two new actions must not become one receipt retry, even with equal text.
import { TaskBoard } from "./task_client.ts";
import { watcherStartup } from "./watcher_test.ts";

function assert(value: unknown, message: string): asserts value {
	if (!value) throw new Error(message);
}

const [port, name] = Deno.args;
const board = await TaskBoard.join("127.0.0.1", Number(port), name);
try {
	const before = (await board.lists())[0].tasks.length;
	await Promise.all([board.add("typescript same"), board.add("typescript same")]);
	let tasks = (await board.lists())[0].tasks;
	assert(tasks.length === before + 2, "two identical adds collapsed into one receipt");
	await Promise.all([board.add("typescript left"), board.add("typescript right")]);
	tasks = (await board.lists())[0].tasks;
	assert(tasks.length === before + 4, "distinct overlapping adds did not both commit");
	const [refused, resumed] = await Promise.allSettled([
		board.add("x".repeat(4097)),
		board.add("typescript after refusal"),
	]);
	assert(refused.status === "rejected", "oversized task was admitted");
	assert(resumed.status === "fulfilled", "mutation queue stayed refused");
	const read = board.lists();
	await board.add("typescript parallel read");
	await read;
	assert((await board.lists())[0].tasks.length === before + 6, "refusal changed later mutation effects");
	await watcherStartup(board);
	console.log("TypeScript: identical/distinct actions, refusal recovery, and parallel reads passed");
} finally {
	await board.leave();
}
