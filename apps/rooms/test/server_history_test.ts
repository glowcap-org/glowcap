// What a room keeps of its own conversation, when the server keeps any.
//
// Retention is a stated policy: `--history` is what turns it on, listed
// rooms keep their last lines, and any member may ask the room for them. A
// server without the flag refuses the verb, which clients read as the
// feature not existing there. With a state directory, what a room kept
// survives the server itself restarting, which is the whole reason the
// policy exists.

import { loopbackTcpDesignator } from "../lib/locator.ts";
import { Room } from "../lib/room_client.ts";
import {
	assert,
	DENO_FLAGS,
	dial,
	enterOrOpen,
	readPort,
	roomsTest,
	ROOT,
	SERVER,
	within,
	withServer,
} from "./support/rooms_server.ts";
import { spawnOwned, stopOwned } from "./support/children.ts";

function spawnHistoryServer(state?: string): Deno.ChildProcess {
	return spawnOwned("deno", {
		args: [...DENO_FLAGS, "--allow-write", SERVER, "0", "--history"],
		cwd: ROOT,
		env: state === undefined ? undefined : { ...Deno.env.toObject(), PANCAKE_ROOMS_STATE: state },
		stdout: "piped",
		stderr: "piped",
	});
}

async function joined(port: number, room: string, nick: string) {
	const session = await dial(loopbackTcpDesignator(port));
	const ref = await enterOrOpen(session, room);
	return await Room.subscribe(session, ref, nick);
}

/** The record is fire-and-forget behind the post, so the test waits for the
 * room's own answer to reach the expected count instead of assuming it. */
async function historySettles(room: Room, count: number) {
	for (let tries = 0; tries < 50; tries++) {
		const lines = await within(room.history(), "the room's history");
		if (lines.length >= count) return lines;
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
	throw new Error(`the room never kept ${count} lines`);
}

roomsTest("a room with history answers what it kept, oldest first", async () => {
	const proc = spawnHistoryServer();
	try {
		const port = await readPort(proc);
		const alice = await joined(port, "general", "alice");
		await within(alice.say("first, for the record"), "the first line");
		await within(alice.say("second, also kept"), "the second line");
		const bob = await joined(port, "general", "bob");
		const lines = await historySettles(bob, 2);
		assert(lines.length === 2, `bob read ${lines.length} kept lines`);
		assert(lines[0].from === "alice" && lines[0].text === "first, for the record", "oldest first");
		assert(lines[1].text === "second, also kept", "newest last");
		assert(lines[0].at > 0, "a kept line carries when it was said");
	} finally {
		await stopOwned(proc);
	}
});

roomsTest("a withdrawn line leaves the kept history; an edit reaches it", async () => {
	const proc = spawnHistoryServer();
	try {
		const port = await readPort(proc);
		const alice = await joined(port, "general", "alice");
		const kept = await within(alice.say("stays said"), "the kept line");
		const gone = await within(alice.say("gets taken back"), "the doomed line");
		await historySettles(alice, 2);
		if (gone === null) throw new Error("the room granted no line reference");
		await within(gone.withdraw(), "the withdrawal");
		for (let tries = 0; tries < 50; tries++) {
			const lines = await within(alice.history(), "history after withdrawal");
			if (lines.length === 1 && lines[0].text === "stays said") break;
			if (tries === 49) throw new Error("the withdrawn line survived in the kept history");
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
		if (kept === null) throw new Error("the room granted no line reference");
		await within(kept.edit("stays said, differently"), "the edit");
		for (let tries = 0; tries < 50; tries++) {
			const lines = await within(alice.history(), "history after edit");
			if (lines.length === 1 && lines[0].text === "stays said, differently") break;
			if (tries === 49) throw new Error("the edit never reached the kept copy");
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
	} finally {
		await stopOwned(proc);
	}
});

roomsTest("a server without history refuses the verb", async () => {
	await withServer(async (port) => {
		const alice = await joined(port, "general", "alice");
		let refused = false;
		try {
			await within(alice.history(), "the refusal");
		} catch {
			refused = true;
		}
		assert(refused, "a server keeping no history still answered the verb");
	});
});

roomsTest("kept lines survive the server restarting on its state directory", async () => {
	const state = await Deno.makeTempDir();
	let proc = spawnHistoryServer(state);
	try {
		const port = await readPort(proc);
		const alice = await joined(port, "general", "alice");
		await within(alice.say("outlives the process"), "the durable line");
		await historySettles(alice, 1);
		// The room answers from its in-memory tail, and the disk write behind
		// it is deliberately fire-and-forget: a kill can lose the last line
		// without breaking the module's stated posture. Restart durability is
		// a claim about the file, so the file is what this scene waits for.
		const file = `${state}/history/${encodeURIComponent("general")}.jsonl`;
		let onDisk = false;
		for (let tries = 0; tries < 60 && !onDisk; tries++) {
			try {
				onDisk = (await Deno.readTextFile(file)).includes("outlives the process");
			} catch {
				/* the first write may not have created the file yet */
			}
			if (!onDisk) await new Promise((resolve) => setTimeout(resolve, 50));
		}
		assert(onDisk, "the kept line never reached the state directory");
	} finally {
		await stopOwned(proc);
	}
	proc = spawnHistoryServer(state);
	try {
		const port = await readPort(proc);
		const bob = await joined(port, "general", "bob");
		const lines = await historySettles(bob, 1);
		assert(
			lines.some((line) => line.text === "outlives the process" && line.from === "alice"),
			"the restarted server did not stand the kept line back up",
		);
	} finally {
		await stopOwned(proc);
	}
});
