import { Ref } from "@pancake/runtime";
import type { Attachment } from "../../lib/attachment.ts";
import { MAX_ROOM_MESSAGE_BACKLOG } from "../../lib/limits.ts";
import type { Message } from "../../lib/room/client.ts";
import { RoomMessageStream } from "../../lib/room/message_stream.ts";
import { assertEquals } from "../assert.ts";

function message(name: string): Message {
	const attachment: Attachment = {
		name,
		mime: "text/plain",
		size: 1,
		width: 0,
		height: 0,
		blob: Object.create(Ref.prototype) as Ref,
	};
	return { from: "bo", text: name, system: false, attachments: [attachment] };
}

Deno.test("room message cancellation releases queued and later capability occurrences", async () => {
	const dropped: string[] = [];
	const stream = new RoomMessageStream((line) => dropped.push(...line.attachments.map((file) => file.name)));
	stream.push(message("first"));
	stream.push(message("second"));
	await stream.readable.cancel();
	assertEquals(dropped, ["first", "second"]);
	stream.push(message("late"));
	assertEquals(dropped, ["first", "second", "late"]);
});

Deno.test("a pending room read takes ownership without entering a platform queue", async () => {
	const dropped: string[] = [];
	const stream = new RoomMessageStream((line) => dropped.push(line.text));
	const reader = stream.readable.getReader();
	const reading = reader.read();
	stream.push(message("direct"));
	assertEquals((await reading).value?.text, "direct");
	stream.close();
	assertEquals((await reader.read()).done, true);
	assertEquals(dropped, []);
});

Deno.test("a room message flood releases its bounded backlog and errors the stream", async () => {
	let dropped = 0;
	const stream = new RoomMessageStream(() => dropped += 1);
	for (let at = 0; at <= MAX_ROOM_MESSAGE_BACKLOG; at += 1) stream.push(message(String(at)));
	const refused = await stream.readable.getReader().read().then(() => false, () => true);
	assertEquals(refused, true);
	assertEquals(dropped, MAX_ROOM_MESSAGE_BACKLOG + 1);
});

Deno.test("room backlog compaction forgets delivered messages without reducing capacity", async () => {
	let dropped = 0;
	const stream = new RoomMessageStream(() => dropped += 1);
	for (let at = 0; at < MAX_ROOM_MESSAGE_BACKLOG; at += 1) stream.push(message(`first-${at}`));
	const reader = stream.readable.getReader();
	const delivered = MAX_ROOM_MESSAGE_BACKLOG / 2;
	for (let at = 0; at < delivered; at += 1) await reader.read();
	for (let at = 0; at < delivered; at += 1) stream.push(message(`second-${at}`));
	await reader.cancel();
	assertEquals(dropped, MAX_ROOM_MESSAGE_BACKLOG);
});
