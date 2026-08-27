import { type Argument, type Behavior, Ref, type Session } from "@pancake/runtime";
import type { Attachment } from "../lib/attachment.ts";
import { Room } from "../lib/room_client.ts";
import { LEAVE, LINE, NOTIFY, SUBSCRIBE } from "../lib/protocol.ts";
import { assertEquals } from "./assert.ts";

function ref(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

function fileLine(blob: Ref, extra?: Ref): Argument[] {
	return [
		"bo",
		"file",
		LINE,
		1n,
		"file",
		"note.txt",
		"text/plain",
		1n,
		blob,
		0n,
		0n,
		...(extra == null ? [] : [extra]),
	];
}

Deno.test("a Room inbox releases surplus and late attachment capabilities", async () => {
	const roomRef = ref();
	const inboxRef = ref();
	const released: Ref[] = [];
	const hosted: Behavior[] = [];
	const session = {
		spawn(behavior: Behavior) {
			hosted.push(behavior);
			return inboxRef;
		},
		send(_target: Ref, verb: string) {
			if (verb === SUBSCRIBE) queueMicrotask(() => hosted[0]?.(NOTIFY, ["room", "", "listed"]));
			if (verb !== SUBSCRIBE && verb !== LEAVE) throw new Error(`unexpected test verb ${verb}`);
			return Promise.resolve(null);
		},
		serve: () => new Promise<void>(() => {}),
		release: (capability: Ref) => released.push(capability),
	} as unknown as Session;
	const room = await Room.subscribe(session, roomRef, "ada");
	const inbox = hosted[0];
	if (inbox == null) throw new Error("the room fixture hosted no inbox");

	const typingExtra = ref();
	inbox(NOTIFY, ["room", "", "typing", "bo", true, typingExtra]);
	assertEquals(released.includes(typingExtra), true);

	const blob = ref();
	const surplus = ref();
	inbox(NOTIFY, fileLine(blob, surplus));
	assertEquals(released.includes(surplus), true);
	assertEquals(released.includes(blob), false);
	const reader = room.messages.getReader();
	const received = await reader.read();
	const attachment = received.value?.attachments[0] as Attachment;
	room.release(attachment);
	assertEquals(released.includes(blob), true);
	reader.releaseLock();

	await room.leave();
	const late = ref();
	inbox(NOTIFY, fileLine(late));
	assertEquals(released.includes(late), true);
});
