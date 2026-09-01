import { DirectoryConnectionLifecycle } from "../web/ui/net/directory_connection_lifecycle.ts";
import { dirId } from "../web/ui/types.ts";
import { assertEquals } from "./assert.ts";

function deferred(): { promise: Promise<void>; resolve(): void } {
	let resolve!: () => void;
	const promise = new Promise<void>((done) => resolve = done);
	return { promise, resolve };
}

Deno.test("leaving invalidates an opening and every open already waiting behind it", async () => {
	const lifecycle = new DirectoryConnectionLifecycle(32);
	const directory = dirId("directory");
	const gate = deferred();
	let secondRuns = 0;
	const first = lifecycle.open(directory, 0, undefined, () => false, async (attempt) => {
		await gate.promise;
		return attempt.stale() ? "stale" : "seated";
	});
	const second = lifecycle.open(directory, 0, undefined, () => false, () => {
		secondRuns += 1;
		return Promise.resolve("seated");
	});
	lifecycle.leave(directory);
	gate.resolve();

	assertEquals(await first, "stale");
	assertEquals(await second, "");
	assertEquals(secondRuns, 0);
});

Deno.test("an explicit open after leave starts a new holding epoch", async () => {
	const lifecycle = new DirectoryConnectionLifecycle(32);
	const directory = dirId("directory");
	const gate = deferred();
	const old = lifecycle.open(directory, 0, undefined, () => false, async (attempt) => {
		await gate.promise;
		return attempt.left() ? "left" : "seated";
	});
	lifecycle.leave(directory);
	let reopened = false;
	const fresh = lifecycle.open(directory, 0, undefined, () => false, (attempt) => {
		reopened = !attempt.stale();
		return Promise.resolve(reopened ? "seated" : "stale");
	});
	gate.resolve();

	assertEquals(await old, "left");
	assertEquals(await fresh, "seated");
	assertEquals(reopened, true);
});

Deno.test("leave cancels a scheduled reconnect", async () => {
	const lifecycle = new DirectoryConnectionLifecycle(32);
	const directory = dirId("directory");
	let reopened = false;
	lifecycle.schedule(directory, 0, () => reopened = true);
	lifecycle.leave(directory);
	await new Promise((resolve) => setTimeout(resolve, 5));
	assertEquals(reopened, false);
});

Deno.test("a refused opening does not poison the next explicit open", async () => {
	const lifecycle = new DirectoryConnectionLifecycle(32);
	const directory = dirId("directory");
	const first = lifecycle.open(
		directory,
		0,
		undefined,
		() => false,
		() => Promise.reject(new Error("dial refused")),
	);
	assertEquals(await first.then(() => "", (error) => error.message), "dial refused");
	assertEquals(
		await lifecycle.open(directory, 0, undefined, () => false, () => Promise.resolve("seated")),
		"seated",
	);
});

Deno.test("explicit directory openings share the workspace admission bound", async () => {
	const lifecycle = new DirectoryConnectionLifecycle(2);
	const gate = deferred();
	const opening = (name: string) =>
		lifecycle.open(dirId(name), 0, undefined, () => false, async () => {
			await gate.promise;
			return "seated";
		});
	const first = opening("first");
	const second = opening("second");
	assertEquals(await opening("third"), "This browser can hold or open at most 2 directories.");
	gate.resolve();
	await Promise.all([first, second]);
});

Deno.test("drain stops every opening and reconnect without a later reopen", async () => {
	const lifecycle = new DirectoryConnectionLifecycle(32);
	const directory = dirId("directory");
	const gate = deferred();
	let reopened = false;
	const opening = lifecycle.open(directory, 0, undefined, () => false, async (attempt) => {
		await gate.promise;
		return attempt.stale() ? "stale" : "seated";
	});
	lifecycle.schedule(directory, 0, () => reopened = true);
	lifecycle.drainAll();
	gate.resolve();
	assertEquals(await opening, "stale");
	await new Promise((resolve) => setTimeout(resolve, 5));
	assertEquals(reopened, false);
});

Deno.test("drain then an explicit open starts a new holding epoch", async () => {
	const lifecycle = new DirectoryConnectionLifecycle(32);
	const directory = dirId("directory");
	const gate = deferred();
	const opening = lifecycle.open(directory, 0, undefined, () => false, async (attempt) => {
		await gate.promise;
		return attempt.stale() ? "stale" : "seated";
	});
	lifecycle.drainAll();
	gate.resolve();
	assertEquals(await opening, "stale");
	let reopened = false;
	const fresh = lifecycle.open(directory, 0, undefined, () => false, (attempt) => {
		reopened = !attempt.stale();
		return Promise.resolve(reopened ? "seated" : "stale");
	});
	assertEquals(await fresh, "seated");
	assertEquals(reopened, true);
});
