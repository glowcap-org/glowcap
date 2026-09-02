import { Ref, type Session } from "@glowcap/runtime";
import type { Attachment, AttachmentSource } from "../../lib/attachment.ts";
import { MAX_ATTACHMENT_BYTES } from "../../lib/limits.ts";
import type { PostedLine } from "../../lib/posted_line.ts";
import type { Message, Room } from "../../lib/room/client.ts";
import { DirectFileCustody } from "../../session/direct_files.ts";
import { materializeAttachmentSources, sendSessionFiles } from "../../session/file_mutation.ts";
import type { LiveDirectory, LiveRoom } from "../../session/live.ts";
import { RoomFileCustody } from "../../session/room_files.ts";
import { assertEquals } from "../assert.ts";

function attachment(name: string): Attachment {
	return {
		name,
		mime: "application/octet-stream",
		size: MAX_ATTACHMENT_BYTES,
		blob: {} as Ref,
		width: 0,
		height: 0,
	};
}

function source(name: string): AttachmentSource {
	return {
		name,
		mime: "application/octet-stream",
		size: MAX_ATTACHMENT_BYTES,
		read: (_offset, length) => Promise.resolve(new Uint8Array(length)),
	};
}

function fileMessage(lineId: number, change: "said" | "refiled", attachments: Attachment[]): Message {
	return { from: "ada", text: "", system: false, lineId, change, attachments };
}

Deno.test("room file custody releases old capabilities at its aggregate byte bound", () => {
	const released: string[] = [];
	const room = { release: (file: Attachment) => released.push(file.name) } as unknown as Room;
	const custody = new RoomFileCustody(room);
	for (let line = 1; line <= 5; line += 1) {
		custody.apply(fileMessage(line, "said", [attachment(`${line}.bin`)]));
	}
	assertEquals(released, ["1.bin"]);
	custody.close();
	assertEquals(released, ["1.bin", "2.bin", "3.bin", "4.bin", "5.bin"]);
});

Deno.test("room refiling retains occurrences that remain on the line", () => {
	const released: string[] = [];
	const room = { release: (file: Attachment) => released.push(file.name) } as unknown as Room;
	const custody = new RoomFileCustody(room);
	const kept = attachment("kept.bin");
	const dropped = attachment("dropped.bin");
	custody.apply(fileMessage(1, "said", [kept, dropped]));
	custody.apply(fileMessage(1, "refiled", [kept]));
	assertEquals(released, ["dropped.bin"]);
	custody.close();
	assertEquals(released, ["dropped.bin", "kept.bin"]);
});

Deno.test("a shared room file post files its returned line authority before upload completion", async () => {
	const authority = {} as PostedLine;
	let uploads = 0;
	const room = {
		stage: () => Promise.resolve({} as Ref),
		postFiles: () => Promise.resolve(authority),
		upload: () => {
			uploads += 1;
			return Promise.resolve();
		},
		discard: () => Promise.resolve(),
	} as unknown as Room;
	const liveRoom = { room, pendingLines: [] } as unknown as LiveRoom;
	const directory = {
		roomRealization: { rooms: new Map([["conversation", liveRoom]]) },
		directs: new Map(),
	} as unknown as LiveDirectory;
	await sendSessionFiles(new Map([["directory", directory]]), () => Promise.resolve(), "conversation", "caption", [
		source("file.bin"),
	]);
	assertEquals(liveRoom.pendingLines.length, 1);
	assertEquals(await liveRoom.pendingLines[0], authority);
	assertEquals(uploads, 1);
});

Deno.test("materialized file mutation identity binds the exact bytes", async () => {
	const bytesByRef = new Map<Ref, Uint8Array>();
	const released: Ref[] = [];
	const session = {
		send: (ref: Ref, _verb: string, args: unknown[]) => {
			const bytes = bytesByRef.get(ref);
			if (bytes == null) return Promise.reject(new Error("unknown test blob"));
			const offset = Number(args[0]);
			const length = Number(args[1]);
			return Promise.resolve(bytes.subarray(offset, offset + length));
		},
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
	const make = (value: string): Attachment => {
		const blob = {} as Ref;
		const bytes = new TextEncoder().encode(value);
		bytesByRef.set(blob, bytes);
		return { name: "same.txt", mime: "text/plain", size: bytes.length, blob, width: 0, height: 0 };
	};
	const first = await materializeAttachmentSources(session, [make("first")]);
	const second = await materializeAttachmentSources(session, [make("other")]);
	assertEquals(first[0].name, second[0].name);
	assertEquals(first[0].bytes.length, second[0].bytes.length);
	assertEquals(first[0].digest === second[0].digest, false);
	assertEquals(released.length, 2);
});

Deno.test("direct refiling reapplies the aggregate outgoing custody bound", async () => {
	const custody = new DirectFileCustody();
	const evicted = custody.retainOutgoing(1, [source("one"), source("two"), source("three")]);
	custody.retainOutgoing(2, [source("four")]);
	custody.refileOutgoing(2, [], [source("five"), source("six")]);
	assertEquals(custody.projectOutgoing(1), []);
	assertEquals(custody.projectOutgoing(2).map((file) => file.name), ["five", "six"]);
	let refused = false;
	try {
		await evicted[0].read(0, 1);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
});
