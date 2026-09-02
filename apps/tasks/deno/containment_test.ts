import { type Ref, type Session } from "@glowcap/runtime";
import { TaskBoardState } from "./board_state.ts";
import { closeFailedJoin, serveAcceptedSession } from "./lifecycle.ts";
import { MAX_SNAPSHOT_TEXT_BYTES, MAX_TASK_TEXT_BYTES, MAX_TASKS, MAX_WATCHERS } from "./limits.ts";
import { LatestSnapshotStream } from "./snapshot_stream.ts";
import { parseSnapshot } from "./task_client.ts";
import { TaskWatcherTable } from "./watchers.ts";

function assert(condition: boolean, message: string): void {
	if (!condition) throw new Error(message);
}

async function assertRejects(action: () => Promise<unknown>, expected: unknown, message: string): Promise<void> {
	try {
		await action();
	} catch (error) {
		assert(error === expected, message);
		return;
	}
	throw new Error(message);
}

Deno.test("task limits reject before state mutation", () => {
	const board = new TaskBoardState();
	let rejected = false;
	try {
		board.add("x".repeat(MAX_TASK_TEXT_BYTES + 1));
	} catch {
		rejected = true;
	}
	assert(rejected, "oversized task text was accepted");
	assert(board.length === 0, "rejected task changed state");

	for (let i = 0; i < MAX_TASKS; i += 1) board.add(String(i));
	rejected = false;
	try {
		board.add("too many");
	} catch {
		rejected = true;
	}
	assert(rejected, "the task count limit was not enforced");
	assert(board.length === MAX_TASKS, "the rejected task changed the count");
});

Deno.test("the aggregate snapshot payload stays below its wire budget", () => {
	const board = new TaskBoardState();
	const chunk = "x".repeat(MAX_TASK_TEXT_BYTES);
	for (let bytes = 0; bytes < MAX_SNAPSHOT_TEXT_BYTES; bytes += MAX_TASK_TEXT_BYTES) board.add(chunk);
	let rejected = false;
	try {
		board.add("one byte too many");
	} catch {
		rejected = true;
	}
	assert(rejected, "the aggregate snapshot text budget was not enforced");
	assert(
		board.length === MAX_SNAPSHOT_TEXT_BYTES / MAX_TASK_TEXT_BYTES,
		"rejected aggregate text changed board state",
	);
});

Deno.test("failed joins close every acquired resource and preserve the primary error", async () => {
	const closed: string[] = [];
	const reported: string[] = [];
	const primary = new Error("watch failed");
	const session = {
		close: () => {
			closed.push("session");
			return Promise.reject(new Error("session close failed"));
		},
	};
	const runtime = {
		close: () => {
			closed.push("runtime");
			return Promise.resolve();
		},
	};
	await assertRejects(
		() => closeFailedJoin(session, runtime, primary, (what) => reported.push(what)),
		primary,
		"join cleanup replaced the original failure",
	);
	assert(closed.join(",") === "session,runtime", "join cleanup did not retire both resources");
	assert(reported.length === 1 && reported[0] === "abandoned join session", "cleanup failure was not observed");
});

Deno.test("accepted task sessions acquire cleanup before publication", async () => {
	const publicationFailure = new Error("publication failed");
	const cleanupFailure = new Error("cleanup failed");
	const reports: Array<{ what: string; error: unknown }> = [];
	let closed = 0;
	let cleaned = 0;
	serveAcceptedSession(
		{
			onClose: () => {},
			serve: () => Promise.resolve(),
			close: () => {
				closed += 1;
				return Promise.resolve();
			},
		},
		() => {
			throw publicationFailure;
		},
		() => {
			cleaned += 1;
			throw cleanupFailure;
		},
		(what, error) => reports.push({ what, error }),
	);
	await Promise.resolve();
	assert(closed === 1 && cleaned === 1, "publication failure did not retire the accepted session");
	assert(
		reports.length === 2 &&
			reports.some(({ what, error }) => what === "accepted session setup" && error === publicationFailure) &&
			reports.some(({ what, error }) => what === "accepted session cleanup" && error === cleanupFailure),
		"accepted-session failures lost their operation owners",
	);
});

Deno.test("latest snapshots coalesce and the delivered value is a resync", async () => {
	const stream = new LatestSnapshotStream<number[]>();
	const reader = stream.readable.getReader();
	stream.push([1]);
	stream.push([2]);
	stream.push([3]);
	assert((await reader.read()).value?.[0] === 1, "the first snapshot was not delivered");
	assert((await reader.read()).value?.[0] === 3, "the latest snapshot was not retained as resync");
	await reader.cancel();
});

Deno.test("watchers replace by session, release, and retain one pending snapshot", async () => {
	const releases: string[] = [];
	const sent: number[][] = [];
	const failures: unknown[] = [];
	let finishFirst!: () => void;
	const session = {
		sessionOpen: true,
		release: (ref: string) => releases.push(ref),
		tell: (_ref: string, _verb: string, args: unknown[]) => {
			const snapshot = args[0] as number[];
			sent.push(snapshot);
			if (sent.length === 1) return new Promise<void>((resolve) => finishFirst = resolve);
			return Promise.resolve();
		},
	} as unknown as Session;
	const table = new TaskWatcherTable((_message, error) => failures.push(error));
	table.register(session, "old" as unknown as Ref);
	table.register(session, "new" as unknown as Ref);
	assert(table.length === 1, "replacement created a second watcher");
	assert(releases.length === 1 && releases[0] === "old", "replacement did not release the old capability");
	table.notify([1]);
	table.notify([2]);
	table.notify([3]);
	assert(sent.length === 1, "more than one update was in flight");
	finishFirst();
	await Promise.resolve();
	await Promise.resolve();
	assert(sent.length === 2 && sent[1][0] === 3, "pending updates were not coalesced");
	table.remove(session);
	assert(table.length === 0 && releases[1] === "new", "disconnect did not release the replacement");
	assert(failures.length === 0, "healthy watcher reported a failure");
});

Deno.test("watcher delivery failure removes and releases only that watcher", async () => {
	const releases: string[] = [];
	const failures: unknown[] = [];
	const session = {
		sessionOpen: true,
		release: (ref: string) => releases.push(ref),
		tell: () => Promise.reject(new Error("peer went away")),
	} as unknown as Session;
	const table = new TaskWatcherTable((_message, error) => failures.push(error));
	table.register(session, "watcher" as unknown as Ref);
	table.notify([]);
	await Promise.resolve();
	await Promise.resolve();
	assert(table.length === 0, "failed watcher remained registered");
	assert(releases.length === 1 && releases[0] === "watcher", "failed watcher was not released");
	assert(failures.length === 1, "watcher delivery failure was not observed");
});

Deno.test("terminal session cleanup leaves watcher imports to the session", () => {
	const releases: Ref[] = [];
	const failures: unknown[] = [];
	const session = {
		closing: true,
		release: (ref: Ref) => releases.push(ref),
	} as unknown as Session;
	const table = new TaskWatcherTable((_message, error) => failures.push(error));
	table.register(session, "watcher" as unknown as Ref);
	table.remove(session);
	assert(table.length === 0, "terminal watcher remained registered");
	assert(releases.length === 0, "terminal cleanup released an import the session already owns");
	assert(failures.length === 0, "terminal cleanup reported a spurious release failure");
});

Deno.test("watcher capacity releases the refused capability", () => {
	const table = new TaskWatcherTable(() => {});
	for (let i = 0; i < MAX_WATCHERS; i += 1) {
		const session = { release: () => {} } as unknown as Session;
		table.register(session, `watcher-${i}` as unknown as Ref);
	}
	const refused = "refused" as unknown as Ref;
	const releases: Ref[] = [];
	const session = { release: (ref: Ref) => releases.push(ref) } as unknown as Session;
	let rejected = false;
	try {
		table.register(session, refused);
	} catch {
		rejected = true;
	}
	assert(rejected, "watcher capacity did not reject");
	assert(releases.length === 1 && releases[0] === refused, "refused watcher capability was not released");
});

Deno.test("task snapshots reject malformed remote state", () => {
	const malformed = [
		null,
		[[1n, "missing completed"]],
		[[0n, "zero id", false]],
		[[1n, "wrong completed", 1n]],
		[[1n, "first", false], [1n, "duplicate", true]],
		[[1n, "x".repeat(MAX_TASK_TEXT_BYTES + 1), false]],
	];
	for (const snapshot of malformed) {
		let rejected = false;
		try {
			parseSnapshot(snapshot as never);
		} catch {
			rejected = true;
		}
		assert(rejected, `malformed snapshot was accepted: ${String(snapshot)}`);
	}
	const parsed = parseSnapshot([[1n, "valid", false]]);
	assert(parsed.length === 1 && parsed[0].id === 1 && parsed[0].text === "valid", "valid snapshot was refused");
});
