// Room clients release surplus, late, and malformed capability occurrences at the inbox boundary.
import { type Argument, type Behavior, Ref, type Session } from "@glowcap/runtime";
import type { Attachment } from "../../lib/attachment.ts";
import { Room } from "../../lib/room/client.ts";
import { LEAVE, LINE, NOTIFY, SUBSCRIBE } from "../../lib/protocol.ts";
import { assertEquals } from "../assert.ts";

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
	const membershipRef = ref();
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
			return Promise.resolve(verb === SUBSCRIBE ? [membershipRef, "participant", null, null] : null);
		},
		serve: () => new Promise<void>(() => {}),
		release: (capability: Ref) => released.push(capability),
	} as unknown as Session;
	const room = await Room.subscribe(session, roomRef, "ada");
	const inbox = hosted[0];
	if (inbox == null) throw new Error("the room fixture hosted no inbox");

	const typingExtra = ref();
	let refused = false;
	try {
		inbox(NOTIFY, ["room", "", "typing", "bo", true, typingExtra]);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released.includes(typingExtra), true);
	refused = false;
	try {
		inbox(NOTIFY, ["room", "", "typing", "bo", "false"]);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);

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

Deno.test("a room session ending before arrival refuses and releases its inbox", async () => {
	const roomRef = ref();
	const inboxRef = ref();
	const membershipRef = ref();
	const released: Ref[] = [];
	const session = {
		spawn: () => inboxRef,
		send: () => Promise.resolve([membershipRef, "participant", null, null]),
		serve: () => Promise.resolve(),
		release: (capability: Ref) => released.push(capability),
	} as unknown as Session;
	const failure = await Room.subscribe(session, roomRef, "ada").then(
		() => "",
		(error) => error instanceof Error ? error.message : String(error),
	);
	assertEquals(failure, "the room session ended before the membership arrived");
	assertEquals(released, [inboxRef, membershipRef]);
});

Deno.test("a malformed membership answer releases every unclaimed capability", async () => {
	const roomRef = ref();
	const inboxRef = ref();
	const seat = ref();
	const unexpected = ref();
	const released: Ref[] = [];
	const session = {
		spawn: () => inboxRef,
		send: () => Promise.resolve([seat, "speaker", unexpected]),
		serve: () => new Promise<void>(() => {}),
		release: (capability: Ref) => released.push(capability),
	} as unknown as Session;
	const failure = await Room.subscribe(session, roomRef, "ada").then(
		() => "",
		(error) => error instanceof Error ? error.message : String(error),
	);
	assertEquals(failure, "the room answered subscribe without one membership capability");
	assertEquals(released, [seat, unexpected, inboxRef]);
});
