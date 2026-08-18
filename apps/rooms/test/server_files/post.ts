// Uploading files into a room, posting them, and changing them afterwards.

import { Attachment, readAttachments } from "../../lib/attachment.ts";

import { UPLOAD_INCOMPLETE } from "../../lib/errors.ts";
import { BLOB_CHUNK, MAX_MESSAGE_FILES } from "../../lib/limits.ts";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { ATTACH, DIRECTORY, DISCARD, OPEN, POST_FILES, SUBSCRIBE } from "../../lib/protocol.ts";
import { Message, Room } from "../../lib/room_client.ts";
import {
	assert,
	dial,
	enterOrOpen,
	nextMessage,
	refusalCode,
	roomsTest,
	waitForLine,
	watchRoom,
	within,
	withServer,
} from "../support/rooms_server.ts";
import { Argument, Ref } from "@pancake/runtime";
roomsTest("an empty upload can be discarded, and does not ride the next message", async () => {
	// A zero-byte file is complete the instant it is staged, and the spent test
	// used to be exactly that shape — so an empty upload read as spent, could
	// not be discarded, and postFiles glued it onto the reader's next message.
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
			const roomRef = await session.send(directory, OPEN, ["holding"]);
			assert(roomRef instanceof Ref, "open should answer a room");
			const inbox = session.spawn(() => null);
			await session.send(roomRef, SUBSCRIBE, ["ada", inbox]);
			// Stage an empty file and discard it: the discard must succeed.
			const empty = await session.send(roomRef, ATTACH, ["empty.bin", "application/octet-stream", 0n]);
			assert(empty instanceof Ref, "attach should answer an upload capability");
			await within(session.send(empty as Ref, DISCARD, []), "discarding an empty upload", 5_000);
			// Nothing is staged now, so postFiles has no ride-along to send.
			const nothing = await refusalCode(() => session.send(roomRef, POST_FILES, ["a caption"]));
			assert(nothing === UPLOAD_INCOMPLETE, `a discarded empty file still rode a later post, got ${nothing}`);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("a message with too many file records shows the first files, not none", async () => {
	// readAttachments walks a message a peer or room controls. It used to throw
	// past MAX_MESSAGE_FILES, and the throw escaped the receive turn and erased
	// the whole message — while a malformed record one line down merely stops
	// the walk and shows what came before. A sender, or a room,
	// relaying, could bypass the client's send-side cap and make a legitimate
	// message vanish. It stops at the cap now, the same as the malformed arm.
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			// A real Ref per record; a direct-message record layout starts at 1.
			const records: Argument[] = ["a caption"];
			for (let i = 0; i < MAX_MESSAGE_FILES + 3; i += 1) {
				records.push(
					"file",
					`f${i}.bin`,
					"application/octet-stream",
					4n,
					session.spawn(() => null),
					0n,
					0n,
				);
			}
			const seen = readAttachments(records, 1);
			assert(
				seen.length === MAX_MESSAGE_FILES,
				`an over-count message did not degrade to the cap: got ${seen.length}`,
			);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("an uploaded file reaches every member, who read its bytes from the room", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "media"), "poster");

		const receiver = await dial(loopbackTcpDesignator(port));
		const receiverRoom = await Room.subscribe(receiver, await enterOrOpen(receiver, "media"), "reader");

		// A subscriber that reads only (from, text) is what a client predating
		// attachments is: the record is additive, so it must still see a line.
		const legacy = await watchRoom(port, "media", "legacy");

		// Larger than one chunk and not a multiple of it, so the upload and the
		// read both cross a boundary and end on a partial chunk.
		const bytes = Uint8Array.from({ length: BLOB_CHUNK * 2 + 17 }, (_, i) => i % 251);
		const sent: number[] = [];
		await senderRoom.attach(
			{ name: "pattern.bin", mime: "application/octet-stream", bytes },
			"",
			(n) => sent.push(n),
		);
		assert(sent.length === 3, `expected three chunk writes, saw ${sent.length}`);
		assert(sent[sent.length - 1] === bytes.length, "progress should end at the file size");

		let got: Message | null = null;
		for await (const message of receiverRoom.messages) {
			if (message.attachments.length > 0) {
				got = message;
				break;
			}
		}
		assert(got !== null, "the receiver should hear the file line");
		assert(got.from === "poster", `file line from ${got.from}`);
		assert(got.text === "pattern.bin", "an empty caption falls back to the file name");
		const attachment = got.attachments[0];
		assert(attachment.name === "pattern.bin", `record name ${attachment.name}`);
		assert(attachment.mime === "application/octet-stream", `record mime ${attachment.mime}`);
		assert(attachment.size === bytes.length, `record size ${attachment.size}`);

		const fetched = await receiverRoom.fetch(attachment);
		assert(fetched.length === bytes.length, `fetched ${fetched.length} of ${bytes.length}`);
		for (let i = 0; i < bytes.length; i += 1) {
			if (fetched[i] !== bytes[i]) throw new Error(`fetched bytes differ at ${i}`);
		}

		// The room hosts the bytes, so the file outlives the poster's connection.
		sender.close();
		await sender.serve().catch(() => {});
		const afterSenderLeft = await receiverRoom.fetch(attachment);
		assert(afterSenderLeft.length === bytes.length, "a posted file survives its poster leaving");

		await waitForLine(legacy.lines, /^poster: pattern\.bin$/);

		await legacy.leave();
		await receiverRoom.leave();
		receiver.close();
	});
});

roomsTest("a picture's declared shape rides the record to every member", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "shapes"), "poster");
		const receiver = await dial(loopbackTcpDesignator(port));
		const receiverRoom = await Room.subscribe(receiver, await enterOrOpen(receiver, "shapes"), "reader");

		await senderRoom.attach({
			name: "wide.png",
			mime: "image/png",
			bytes: new Uint8Array([1, 2, 3, 4]),
			width: 800,
			height: 450,
		});

		// A file with no shape to declare says so as zero, not as nonsense.
		await senderRoom.attach({ name: "notes.txt", mime: "text/plain", bytes: new Uint8Array([9]) });

		// One reader over the stream: breaking out of a `for await` cancels it,
		// so a second loop would find nothing.
		const byName = new Map<string, Attachment>();
		for await (const message of receiverRoom.messages) {
			for (const attachment of message.attachments) byName.set(attachment.name, attachment);
			if (byName.size === 2) break;
		}
		const wide = byName.get("wide.png");
		const plain = byName.get("notes.txt");
		assert(wide !== undefined && plain !== undefined, "both file lines should arrive");
		// The reader reserves this shape before the bytes arrive, which is what
		// keeps a log of pictures from shoving itself down the page as they load.
		assert(wide.width === 800, `declared width arrived as ${wide.width}`);
		assert(wide.height === 450, `declared height arrived as ${wide.height}`);
		assert(plain.width === 0 && plain.height === 0, "an unmeasured file declares no shape");

		await receiverRoom.leave();
		receiver.close();
		sender.close();
		await sender.serve().catch(() => {});
	});
});

roomsTest("staged files publish together, in order, or not at all", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "album"), "poster");
		const receiver = await dial(loopbackTcpDesignator(port));
		const receiverRoom = await Room.subscribe(receiver, await enterOrOpen(receiver, "album"), "reader");

		const firstSource = { name: "first.txt", mime: "text/plain", bytes: new Uint8Array([1]) };
		const secondSource = { name: "second.txt", mime: "text/plain", bytes: new Uint8Array([2]) };
		const first = await senderRoom.stage(firstSource);
		const second = await senderRoom.stage(secondSource);
		// Publication is atomic and preserves composer order, before either file
		// has moved. Each blob read then waits on its own upload capability.
		await senderRoom.postFiles("two files");
		for await (const message of receiverRoom.messages) {
			if (message.attachments.length === 0) continue;
			assert(message.text === "two files", `caption was ${message.text}`);
			assert(message.attachments.length === 2, `expected two files, got ${message.attachments.length}`);
			assert(message.attachments[0].name === "first.txt", "first staged file moved");
			assert(message.attachments[1].name === "second.txt", "second staged file moved");
			const reads = message.attachments.map((attachment) => receiverRoom.fetch(attachment));
			await Promise.all([
				senderRoom.upload(first, firstSource),
				senderRoom.upload(second, secondSource),
			]);
			const [firstBytes, secondBytes] = await Promise.all(reads);
			assert(firstBytes[0] === 1 && secondBytes[0] === 2, "independent uploads reached their blobs");
			break;
		}

		await receiverRoom.leave();
		receiver.close();
		sender.close();
		await sender.serve().catch(() => {});
	});
});

roomsTest("a file line is a line: its caption changes, its files survive, and withdrawing frees them", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "gallery"), "poster");
		const reader = await dial(loopbackTcpDesignator(port));
		const readerRoom = await Room.subscribe(reader, await enterOrOpen(reader, "gallery"), "reader");

		const source = { name: "pic.txt", mime: "text/plain", bytes: new Uint8Array([7, 7, 7]) };
		const upload = await senderRoom.stage(source);
		// The room now answers a file post with a line reference, the same one a
		// text post gets. A room may grant no editing authority, and a file line could
		// then be neither captioned again nor taken back.
		const line = await senderRoom.postFiles("first caption");
		assert(line !== null, "postFiles should answer a line reference");
		await senderRoom.upload(upload, source);

		const posted = await nextMessage(readerRoom, (m) => m.attachments.length > 0);
		assert(posted.change === "said", `a fresh file line is a new line, got ${posted.change}`);
		assert(posted.lineId !== undefined, "a file line carries an id, like any line");
		assert(posted.text === "first caption", `the caption was ${posted.text}`);
		assert(
			posted.attachments.length === 1 && posted.attachments[0].name === "pic.txt",
			"the file rode the line, read from after the line id",
		);
		const held = posted.attachments[0];
		const bytes = await readerRoom.fetch(held);
		assert(bytes.length === 3 && bytes[0] === 7, "the reader fetched the file");

		// A caption change is text only: the files ride through untouched, so the
		// edit carries no records and the reader keeps the blob it holds.
		await line!.edit("second caption");
		const edited = await nextMessage(readerRoom, (m) => m.change === "edited" && m.lineId === posted.lineId);
		assert(edited.text === "second caption", `the edit did not change the caption: ${edited.text}`);
		assert(edited.attachments.length === 0, "a caption edit must not re-send the files");
		const again = await readerRoom.fetch(held);
		assert(again.length === 3 && again[0] === 7, "the file the reader held still reads after a caption edit");

		// Withdrawing the line takes its file with it: the reader's blob breaks
		// rather than answering an empty or stale file.
		await line!.withdraw();
		await nextMessage(readerRoom, (m) => m.change === "withdrawn" && m.lineId === posted.lineId);
		let broke = false;
		try {
			await readerRoom.fetch(held);
		} catch {
			broke = true;
		}
		assert(broke, "withdrawing a file line frees its file, so the reader's blob must break");

		await readerRoom.leave();
		reader.close();
		await reader.serve().catch(() => {});
		sender.close();
		await sender.serve().catch(() => {});
	});
});

roomsTest("refile keeps a file by index without re-upload, adds a staged one, and frees what it drops", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "album2"), "poster");
		const reader = await dial(loopbackTcpDesignator(port));
		const readerRoom = await Room.subscribe(reader, await enterOrOpen(reader, "album2"), "reader");

		const a = { name: "a.txt", mime: "text/plain", bytes: new Uint8Array([1]) };
		const b = { name: "b.txt", mime: "text/plain", bytes: new Uint8Array([2]) };
		const ua = await senderRoom.stage(a);
		const ub = await senderRoom.stage(b);
		const line = await senderRoom.postFiles("two files");
		assert(line !== null, "postFiles should answer a line reference");
		await senderRoom.upload(ua, a);
		await senderRoom.upload(ub, b);

		const posted = await nextMessage(readerRoom, (m) => m.attachments.length === 2);
		assert(
			posted.attachments[0].name === "a.txt" && posted.attachments[1].name === "b.txt",
			"the two files posted in order",
		);
		const dropped = posted.attachments[1];

		// Keep index 0 (a), add a freshly staged c, and let b go. The kept file is
		// named by its position, not re-uploaded.
		const c = { name: "c.txt", mime: "text/plain", bytes: new Uint8Array([3]) };
		const uc = await senderRoom.stage(c);
		await line!.refile("kept a plus c", [0]);
		await senderRoom.upload(uc, c);

		const refiled = await nextMessage(readerRoom, (m) => m.change === "refiled");
		assert(refiled.lineId === posted.lineId, "the refile named the same line");
		assert(refiled.text === "kept a plus c", `the refile caption was ${refiled.text}`);
		assert(refiled.attachments.length === 2, `the refiled set had ${refiled.attachments.length} files`);
		assert(refiled.attachments[0].name === "a.txt", "the kept file stayed first");
		assert(refiled.attachments[1].name === "c.txt", "the added file came after it");
		// The kept file reads even though this refile never re-uploaded it: the
		// room held its bytes across the change.
		const keptBytes = await readerRoom.fetch(refiled.attachments[0]);
		assert(keptBytes.length === 1 && keptBytes[0] === 1, "the kept file reads without a re-upload");
		const addedBytes = await readerRoom.fetch(refiled.attachments[1]);
		assert(addedBytes.length === 1 && addedBytes[0] === 3, "the added file reads");
		// The dropped file is freed, so the blob the reader still held for it breaks.
		let broke = false;
		try {
			await readerRoom.fetch(dropped);
		} catch {
			broke = true;
		}
		assert(broke, "a file a refile drops is freed, so its blob must break");

		await readerRoom.leave();
		reader.close();
		await reader.serve().catch(() => {});
		sender.close();
		await sender.serve().catch(() => {});
	});
});

roomsTest("refiling a file line down to nothing takes it back, and its reference stops answering", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "album3"), "poster");
		const reader = await dial(loopbackTcpDesignator(port));
		const readerRoom = await Room.subscribe(reader, await enterOrOpen(reader, "album3"), "reader");

		const source = { name: "solo.txt", mime: "text/plain", bytes: new Uint8Array([9]) };
		const upload = await senderRoom.stage(source);
		const line = await senderRoom.postFiles("bye soon");
		assert(line !== null, "postFiles should answer a line reference");
		await senderRoom.upload(upload, source);
		const posted = await nextMessage(readerRoom, (m) => m.attachments.length > 0);

		// No kept files, none staged, no caption: an empty line is nothing, so the
		// refile takes it down rather than posting a blank bubble.
		await line!.refile("", []);
		const gone = await nextMessage(readerRoom, (m) => m.change === "withdrawn" && m.lineId === posted.lineId);
		assert(gone.change === "withdrawn", "an emptied refile withdraws the line");

		// The line is withdrawn, so its reference refuses a later edit the same way
		// a `withdraw` leaves it.
		let refused = false;
		try {
			await line!.edit("back?");
		} catch {
			refused = true;
		}
		assert(refused, "a line a refile withdrew refuses further edits");

		await readerRoom.leave();
		reader.close();
		await reader.serve().catch(() => {});
		sender.close();
		await sender.serve().catch(() => {});
	});
});
