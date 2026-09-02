// What a room keeps of its own conversation, when the server keeps any.
//
// Retention is a stated policy: `--history` is what turns it on, listed
// rooms keep their last lines, and any member may ask the room for them. A
// server without the flag refuses the verb, which clients read as the
// feature not existing there. With a state directory, what a room kept
// survives the server itself restarting, which is the whole reason the
// policy exists.

import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { Directory, Room } from "../../lib/room/client.ts";
import { PRIVATE_ROOM_POLICY } from "../../lib/room/policy.ts";
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
} from "../support/rooms_server.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";

function spawnHistoryServer(state?: string): Deno.ChildProcess {
	return spawnOwned("deno", {
		args: [...DENO_FLAGS, "--allow-write", SERVER, "0", "--history"],
		cwd: ROOT,
		env: state === undefined ? undefined : { ...Deno.env.toObject(), GLOWCAP_ROOMS_STATE: state },
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

roomsTest("managed room history is keyed by stable opaque identity", async () => {
	const proc = spawnHistoryServer();
	try {
		const port = await readPort(proc);
		const directory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
		const managed = await directory.openManaged("private history", { policy: PRIVATE_ROOM_POLICY });
		const room = await Room.subscribe(directory.session, managed.room, "keeper");
		await room.say("kept by identity");
		const lines = await historySettles(room, 1);
		assert(lines[0]?.text === "kept by identity", "managed room history did not accept its opaque identity");
		await room.leave();
		await directory.close();
	} finally {
		await stopOwned(proc);
	}
});

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

roomsTest("a file caption is retained, refiling updates it, and emptying the line forgets it", async () => {
	const proc = spawnHistoryServer();
	try {
		const port = await readPort(proc);
		const alice = await joined(port, "general", "alice");
		await alice.stage({ name: "notes.txt", mime: "text/plain", bytes: new Uint8Array([1]) });
		const posted = await within(alice.postFiles("first caption"), "the captioned file line");
		if (posted === null) throw new Error("the room granted no file-line reference");
		let lines = await historySettles(alice, 1);
		assert(lines.length === 1 && lines[0].text === "first caption", "the file caption was not retained");

		await within(posted.refile("revised caption", [0]), "the caption refile");
		for (let tries = 0; tries < 50; tries++) {
			lines = await within(alice.history(), "history after caption refile");
			if (lines.length === 1 && lines[0].text === "revised caption") break;
			if (tries === 49) throw new Error("the refile never reached the kept caption");
			await new Promise((resolve) => setTimeout(resolve, 100));
		}

		await within(posted.refile("", []), "the empty refile");
		for (let tries = 0; tries < 50; tries++) {
			lines = await within(alice.history(), "history after empty refile");
			if (lines.length === 0) break;
			if (tries === 49) throw new Error("the emptied file line survived in kept history");
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
	let stopped = false;
	try {
		const port = await readPort(proc);
		const alice = await joined(port, "general", "alice");
		await within(alice.say("outlives the process"), "the durable line");
		await historySettles(alice, 1);
		// No storage polling: controlled shutdown owns the durability boundary
		// and must drain the admitted append before the process exits.
		await stopOwned(proc);
		stopped = true;
	} finally {
		if (!stopped) await stopOwned(proc);
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

roomsTest("a restarted room edits only the line capability from its own generation", async () => {
	const state = await Deno.makeTempDir();
	let proc: Deno.ChildProcess | null = null;
	try {
		proc = spawnHistoryServer(state);
		let port = await readPort(proc);
		let alice = await joined(port, "general", "alice");
		await within(alice.say("first generation"), "the first-generation line");
		await historySettles(alice, 1);
		await stopOwned(proc);
		proc = null;

		proc = spawnHistoryServer(state);
		port = await readPort(proc);
		alice = await joined(port, "general", "alice");
		const current = await within(alice.say("second generation"), "the second-generation line");
		if (current === null) throw new Error("the restarted room granted no line reference");
		await historySettles(alice, 2);
		await within(current.edit("second generation, edited"), "the second-generation edit");
		for (let tries = 0; tries < 50; tries++) {
			const lines = await within(alice.history(), "history after the restarted edit");
			if (
				lines.length === 2 && lines[0].text === "first generation" &&
				lines[1].text === "second generation, edited"
			) break;
			if (tries === 49) throw new Error("the restarted line edited a prior generation's history");
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
		await stopOwned(proc);
		proc = null;

		proc = spawnHistoryServer(state);
		port = await readPort(proc);
		const bob = await joined(port, "general", "bob");
		const lines = await historySettles(bob, 2);
		assert(
			lines.length === 2 && lines[0].text === "first generation" &&
				lines[1].text === "second generation, edited",
			"both room generations did not survive the next restart exactly",
		);
	} finally {
		if (proc !== null) await stopOwned(proc);
		await Deno.remove(state, { recursive: true });
	}
});

roomsTest("corrupt room history refuses startup before a listener opens", async () => {
	const state = await Deno.makeTempDir();
	await Deno.mkdir(`${state}/history`);
	await Deno.writeTextFile(`${state}/history/general.jsonl`, "not-json\n");
	const proc = spawnHistoryServer(state);
	try {
		const status = await within(proc.status, "the corrupt-history startup refusal");
		const said = await new Response(proc.stderr).text();
		assert(!status.success, "the server with corrupt history exited successfully");
		assert(said.includes("room history for general contains invalid JSON"), `the refusal was: ${said}`);
	} finally {
		await stopOwned(proc);
	}
});
