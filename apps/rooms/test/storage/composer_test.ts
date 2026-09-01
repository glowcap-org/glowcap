// The storage composer's selection grammar: which destination shape opens
// which backend, and which is refused out loud. The PostgreSQL walk itself
// is the fixture suite's to prove; this holds the one place a scheme name
// is allowed to mean anything.

import { openHistoryStorage } from "../../server/storage.ts";
import { FileHistoryBackend, HISTORY_FILE_BYTES } from "../../server/storage/files.ts";
import { HISTORY_ROOMS_KEPT, HistoryIndex } from "../../server/history_index.ts";
import { assertEquals } from "../assert.ts";

async function historyRefusal(directory: string): Promise<string> {
	try {
		await new FileHistoryBackend(directory).restore(new HistoryIndex());
		return "";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}

Deno.test("no destination keeps today's posture: state files, else memory", async () => {
	assertEquals(await openHistoryStorage(undefined, null), null);
	const backed = await openHistoryStorage(undefined, "/tmp/state");
	assertEquals(backed instanceof FileHistoryBackend, true);
	backed?.close();
});

Deno.test("a plain destination is a directory for the file backend", async () => {
	const backend = await openHistoryStorage("/somewhere/else", null);
	assertEquals(backend instanceof FileHistoryBackend, true);
	backend?.close();
});

Deno.test("an unknown scheme is refused out loud, never treated as a path", async () => {
	let refused = "";
	try {
		await openHistoryStorage("mysql://user:pw@db:3306/rooms", null);
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assertEquals(refused.includes('unknown storage scheme "mysql://"'), true);
});

Deno.test("file compaction derives its bounded tail without one supplied by every append", async () => {
	const directory = await Deno.makeTempDir();
	try {
		const backend = new FileHistoryBackend(directory);
		for (let id = 1; id <= 1_000; id++) {
			await backend.append("general", { from: "alice", text: `line ${id}`, at: id }, null);
		}
		const restored = new HistoryIndex();
		await backend.restore(restored);
		const kept = restored.read("general", 500);
		assertEquals(kept.length, 500);
		assertEquals(kept[0].text, "line 501");
		assertEquals(kept.at(-1)?.text, "line 1000");
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("file history recovers only a torn final append and refuses complete corruption", async () => {
	const directory = await Deno.makeTempDir();
	try {
		const history = `${directory}/history`;
		await Deno.mkdir(history);
		const path = `${history}/general.jsonl`;
		const first = JSON.stringify({ version: 1, from: "alice", text: "whole", at: 1 });
		await Deno.writeTextFile(path, `${first}\n{"from"`);
		const backend = new FileHistoryBackend(directory);
		const restored = new HistoryIndex();
		await backend.restore(restored);
		assertEquals(restored.read("general", 500).map((line) => line.text), ["whole"]);
		await Deno.writeTextFile(path, `${first}\nnot-json\n`);
		let refused = false;
		try {
			await backend.restore(new HistoryIndex());
		} catch {
			refused = true;
		}
		assertEquals(refused, true, "a malformed complete row must be refused");
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("file history refuses unsupported and unversioned rows", async () => {
	const directory = await Deno.makeTempDir();
	try {
		const history = `${directory}/history`;
		await Deno.mkdir(history);
		await Deno.writeTextFile(
			`${history}/general.jsonl`,
			JSON.stringify({ version: 2, from: "alice", text: "future", at: 1 }) + "\n",
		);
		let refused = "";
		try {
			await new FileHistoryBackend(directory).restore(new HistoryIndex());
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assertEquals(refused.includes("unsupported line version 2"), true);
		await Deno.writeTextFile(
			`${history}/general.jsonl`,
			JSON.stringify({ from: "alice", text: "unversioned", at: 1 }) + "\n",
		);
		assertEquals((await historyRefusal(directory)).includes("invalid line"), true);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("file history opens its directory and refuses unexpected state before serving", async () => {
	const directory = await Deno.makeTempDir();
	try {
		const history = `${directory}/history`;
		await Deno.mkdir(history);
		await Deno.writeTextFile(`${history}/notes.txt`, "not room history\n");
		let refused = "";
		try {
			await new FileHistoryBackend(directory).restore(new HistoryIndex());
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assertEquals(refused.includes("unexpected file"), true);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("file startup bounds each read and validates rows beyond the visible tail", async () => {
	const directory = await Deno.makeTempDir();
	try {
		const history = `${directory}/history`;
		await Deno.mkdir(history);
		const path = `${history}/general.jsonl`;
		const oversized = await Deno.open(path, { createNew: true, write: true });
		await oversized.truncate(HISTORY_FILE_BYTES + 1);
		oversized.close();
		let refused = "";
		try {
			await new FileHistoryBackend(directory).restore(new HistoryIndex());
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assertEquals(refused.includes(`${HISTORY_FILE_BYTES} bytes`), true);

		const bad = JSON.stringify({ from: "", text: "hidden beyond the tail", at: 1, id: 1 });
		const visible = Array.from(
			{ length: 500 },
			(_, at) => JSON.stringify({ from: "alice", text: `line ${at}`, at: at + 2, id: at + 2 }),
		);
		await Deno.writeTextFile(path, [bad, ...visible].join("\n") + "\n");
		refused = "";
		try {
			await new FileHistoryBackend(directory).restore(new HistoryIndex());
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assertEquals(refused.includes("contains an invalid line"), true);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("file startup removes a probe left by an interrupted earlier open", async () => {
	const directory = await Deno.makeTempDir();
	try {
		const history = `${directory}/history`;
		await Deno.mkdir(history);
		await Deno.writeTextFile(`${history}/.open-check.tmp`, "");
		await new FileHistoryBackend(directory).restore(new HistoryIndex());
		let remains = true;
		try {
			await Deno.stat(`${history}/.open-check.tmp`);
		} catch (error) {
			if (error instanceof Deno.errors.NotFound) remains = false;
			else throw error;
		}
		assertEquals(remains, false);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("file append removes the shared index's exact whole-room victim", async () => {
	const directory = await Deno.makeTempDir();
	try {
		const backend = new FileHistoryBackend(directory);
		await backend.restore(new HistoryIndex());
		await backend.append("oldest", { from: "alice", text: "old", at: 1 }, null);
		await backend.append("newest", { from: "alice", text: "new", at: 2 }, "oldest");
		const restored = new HistoryIndex();
		await backend.restore(restored);
		assertEquals(restored.read("oldest", 1), []);
		assertEquals(restored.read("newest", 1).map((line) => line.text), ["new"]);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("file startup repairs the one-room surplus an interrupted eviction can leave", async () => {
	const directory = await Deno.makeTempDir();
	try {
		const backend = new FileHistoryBackend(directory);
		for (let room = 0; room <= HISTORY_ROOMS_KEPT; room++) {
			await backend.append(`room-${room}`, { from: "alice", text: "one", at: room }, null);
		}
		const restored = new HistoryIndex();
		await backend.restore(restored);
		const victims = restored.takeEvicted();
		assertEquals(victims, ["room-0"]);
		for (const room of victims) await backend.replace(room, []);

		const reopened = new HistoryIndex();
		await backend.restore(reopened);
		assertEquals(reopened.takeEvicted(), []);
		assertEquals(reopened.read("room-0", 1), []);
		assertEquals(reopened.read(`room-${HISTORY_ROOMS_KEPT}`, 1).length, 1);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});
