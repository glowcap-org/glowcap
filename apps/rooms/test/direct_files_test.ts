import { Ref, type Session } from "@pancake/runtime";
import type { DirectMessage } from "../lib/direct_message.ts";
import { type Attachment, type AttachmentSource, readRefileChange } from "../lib/attachment.ts";
import { directReceivedLineBehavior, DurableDirectLine } from "../session/direct_line.ts";
import { DirectFileCustody } from "../session/direct_files.ts";
import { directInbox } from "../session/directory_directs.ts";
import type { LiveDirectory } from "../session/live.ts";
import { assertEquals } from "./assert.ts";
import { MAX_DIRECT_ATTACHMENTS } from "../lib/limits.ts";
import { EDIT, REFILE } from "../lib/protocol.ts";
import { registrationId } from "./support/registration.ts";
import { DIRECT_NOT_ACCEPTED, roomErrorOf } from "../lib/errors.ts";

function fakeLine(overrides: Partial<DirectMessage> = {}): DirectMessage {
	return {
		send: () => Promise.resolve(null),
		sendFiles: () => Promise.resolve(null),
		fetchChunk: (attachment: Attachment, offset: number, maxLen: number) =>
			Promise.resolve(
				new Uint8Array(
					(attachment as Attachment & { bytes: Uint8Array }).bytes.subarray(offset, offset + maxLen),
				),
			),
		fetch: (attachment: Attachment) =>
			Promise.resolve(new Uint8Array((attachment as Attachment & { bytes: Uint8Array }).bytes)),
		release: () => {},
		close: async () => {},
		...overrides,
	} as unknown as DirectMessage;
}

function source(name: string, bytes: string): AttachmentSource {
	return { name, mime: "text/plain", bytes: new TextEncoder().encode(bytes) };
}

function attachmentSession(
	bytes: Uint8Array,
	onFetch: () => void = () => {},
	onRelease: (ref: Ref) => void = () => {},
): Session {
	return {
		send: (_target: Ref, _verb: string, args: unknown[]) => {
			onFetch();
			const offset = Number(args[0]);
			const length = Number(args[1]);
			return Promise.resolve(bytes.slice(offset, offset + length));
		},
		release: onRelease,
	} as unknown as Session;
}

Deno.test("direct custody retains incoming capabilities and releases them on withdrawal", async () => {
	const released: Ref[] = [];
	const custody = new DirectFileCustody();
	const attachment = {
		name: "reply.txt",
		mime: "text/plain",
		size: 5,
		blob: {} as Ref,
		width: 0,
		height: 0,
		bytes: new TextEncoder().encode("reply"),
	};
	const message = { lineId: 1, change: "said", attachments: [attachment] };
	const session = attachmentSession(attachment.bytes, () => {}, (ref) => released.push(ref));
	const projected = await custody.retainIncoming(message, session);
	assertEquals(new TextDecoder().decode(await projected[0].read(1, 3)), "epl");
	assertEquals(new TextDecoder().decode(await projected[0].read(0, 5)), "reply");
	assertEquals(released.length, 1);
	await custody.retainIncoming({ lineId: 1, change: "withdrawn", attachments: [] }, session);
	assertEquals(released.length, 1);
	assertEquals(await projected[0].read(0, 5).then(() => false, () => true), true);
});

Deno.test("an admitted direct-file read finishes after live custody is withdrawn", async () => {
	const bytes = new TextEncoder().encode("reply");
	const pending = Promise.withResolvers<Uint8Array>();
	const session = {
		send: () => pending.promise,
		release: () => {},
	} as unknown as Session;
	const custody = new DirectFileCustody();
	const attachment = {
		name: "reply.txt",
		mime: "text/plain",
		size: bytes.length,
		blob: {} as Ref,
		width: 0,
		height: 0,
	};
	const [projected] = custody.retainIncoming({ lineId: 1, change: "said", attachments: [attachment] }, session);
	const reading = projected.read(0, bytes.length);
	custody.retainIncoming({ lineId: 1, change: "withdrawn", attachments: [] }, session);
	pending.resolve(bytes);
	assertEquals(await reading, bytes);
	assertEquals(await projected.read(0, bytes.length).then(() => false, () => true), true);
});

Deno.test("incoming direct-file refiles reuse materialized bytes and release each occurrence", async () => {
	const released: Ref[] = [];
	let fetches = 0;
	const custody = new DirectFileCustody();
	const blob = { equals: (other: unknown) => other === blob } as Ref;
	const attachment = {
		name: "kept.bin",
		mime: "application/octet-stream",
		size: 4,
		blob,
		width: 0,
		height: 0,
		bytes: new Uint8Array([1, 2, 3, 4]),
	};
	const session = attachmentSession(attachment.bytes, () => fetches += 1, (ref) => released.push(ref));
	const first = await custody.retainIncoming({ lineId: 1, change: "said", attachments: [attachment] }, session);
	const kept = await custody.retainIncoming({ lineId: 1, change: "refiled", attachments: [attachment] }, session);
	assertEquals(fetches, 1);
	assertEquals(await first[0].read(0, 4), new Uint8Array([1, 2, 3, 4]));
	assertEquals(released.length, 1);
	assertEquals(await kept[0].read(0, 4), new Uint8Array([1, 2, 3, 4]));
	custody.close();
});

Deno.test("an incoming direct refile retires bytes it no longer names", async () => {
	const custody = new DirectFileCustody();
	const firstBlob = { equals: (other: unknown) => other === firstBlob } as Ref;
	const secondBlob = { equals: (other: unknown) => other === secondBlob } as Ref;
	const first = {
		name: "first.bin",
		mime: "application/octet-stream",
		size: 3,
		blob: firstBlob,
		width: 0,
		height: 0,
	};
	const second = { ...first, name: "second.bin", blob: secondBlob };
	const session = attachmentSession(new Uint8Array([1, 2, 3]));
	const [oldView] = custody.retainIncoming({ lineId: 1, change: "said", attachments: [first] }, session);
	assertEquals(await oldView.materialize?.(), new Uint8Array([1, 2, 3]));
	const [newView] = custody.retainIncoming({ lineId: 1, change: "refiled", attachments: [second] }, session);
	assertEquals(await oldView.read(0, 3).then(() => false, () => true), true);
	assertEquals(await newView.read(0, 3), new Uint8Array([1, 2, 3]));
	custody.close();
});

Deno.test("incoming direct-file custody shares one process-wide file ceiling", async () => {
	const custodies: DirectFileCustody[] = [];
	let firstView: ReturnType<DirectFileCustody["retainIncoming"]>[number] | null = null;
	const session = attachmentSession(new Uint8Array());
	for (let index = 0; index <= MAX_DIRECT_ATTACHMENTS; index += 1) {
		const custody = new DirectFileCustody();
		custodies.push(custody);
		const blob = { equals: (other: unknown) => other === blob } as Ref;
		const [view] = custody.retainIncoming({
			lineId: 1,
			change: "said",
			attachments: [{
				name: `empty-${index}.bin`,
				mime: "application/octet-stream",
				size: 0,
				blob,
				width: 0,
				height: 0,
			}],
		}, session);
		await view.materialize?.();
		firstView ??= view;
	}
	assertEquals(await firstView?.read(0, 1).then(() => false, () => true), true);
	for (const custody of custodies) custody.close();
});

Deno.test("direct custody projects sent files without copying their bytes", async () => {
	const bytes = new TextEncoder().encode("sent file");
	const custody = new DirectFileCustody();
	const files = custody.retainOutgoing(1, [{ name: "sent.txt", mime: "text/plain", bytes }]);
	assertEquals(files[0]?.name, "sent.txt");
	const chunk = await files[0]?.read(0, bytes.length);
	assertEquals(chunk, bytes);
	custody.releaseOutgoing(1);
	assertEquals(custody.projectOutgoing(1), []);
	let refused = false;
	try {
		await files[0]?.read(0, bytes.length);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
});

Deno.test("a direct line keeps posted file authority and custody together through close", async () => {
	let closed = 0;
	let released = 0;
	const incoming = {
		name: "reply.txt",
		mime: "text/plain",
		size: 5,
		blob: {} as Ref,
		width: 0,
		height: 0,
		bytes: new TextEncoder().encode("reply"),
	};
	const line = fakeLine({
		sendFiles: () => Promise.resolve(null),
		release: () => released += 1,
		close: () => {
			closed += 1;
			return Promise.resolve();
		},
	});
	const direct = new DurableDirectLine("direct", line);
	const session = attachmentSession(incoming.bytes, () => {}, () => released += 1);
	await direct.files.retainIncoming({ lineId: 2, change: "said", attachments: [incoming] }, session);
	const sent = await direct.sendFiles("me", "caption", [source("sent.txt", "bytes")]);
	assertEquals(sent.files.length, 1);
	await direct.close();
	assertEquals(closed, 1);
	assertEquals(released, 1);
});

Deno.test("direct inbox routes typing as an ephemeral conversation event", () => {
	const seen: { conversationId: string; peer: string; on: boolean }[] = [];
	const held = {
		directConversationByRegistration: new Map([[registrationId(1), "conversation"]]),
	} as unknown as LiveDirectory;
	const inbox = directInbox(held, "bob", registrationId(1), {
		setIssue: () => false,
		subjects: () => [],
		receive: () => ({} as Ref),
		emit: () => {},
		onInvitation: () => {},
		handRoom: () => {},
		typing: (_held, conversationId, peer, on) => seen.push({ conversationId, peer, on }),
		cleanup: async (work) => {
			await work;
		},
	});
	inbox("typing", [true]);
	inbox("typing", [false]);
	assertEquals(seen, [
		{ conversationId: "conversation", peer: "bob", on: true },
		{ conversationId: "conversation", peer: "bob", on: false },
	]);
});

Deno.test("a direct inbox gives an exact retired conversation a typed refusal", () => {
	const held = { directConversationByRegistration: new Map() } as unknown as LiveDirectory;
	const inbox = directInbox(held, "bob", registrationId(1), {
		setIssue: () => false,
		subjects: () => [],
		receive: () => ({} as Ref),
		emit: () => {},
		onInvitation: () => {},
		handRoom: () => {},
		cleanup: async (work) => {
			await work;
		},
	});
	let code = "";
	try {
		inbox("typing", [true]);
	} catch (error) {
		code = roomErrorOf(error)?.code ?? "";
	}
	assertEquals(code, DIRECT_NOT_ACCEPTED);
});

Deno.test("refile parsing rejects malformed spans and repeated kept indices", () => {
	let refused = false;
	try {
		readRefileChange(["caption", 0n, "file"], 1);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	refused = false;
	try {
		readRefileChange(["caption", 0n, 0n], 1);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
});

Deno.test("a received direct-line capability returns malformed capability arguments", () => {
	const released: Ref[] = [];
	const session = { release: (capability: Ref) => released.push(capability) } as unknown as Session;
	const line = directReceivedLineBehavior("peer", 1, [], () => {}, () => session);
	const refused = (verb: string, args: Parameters<typeof line>[1]): boolean => {
		try {
			line(verb, args);
			return false;
		} catch {
			return true;
		}
	};
	const editCapability = Object.create(Ref.prototype) as Ref;
	assertEquals(refused(EDIT, [editCapability]), true);
	assertEquals(released, [editCapability]);
	const refileCapability = Object.create(Ref.prototype) as Ref;
	assertEquals(refused(REFILE, ["caption", refileCapability]), true);
	assertEquals(released, [editCapability, refileCapability]);
});
