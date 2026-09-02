// Ceilings a room holds files to: size, count, readers, and giving up.

import { Attachment, fetchBlob } from "../../../lib/attachment.ts";
import { Unanswered } from "../../../lib/deadline.ts";
import {
	ATTACHMENT_REFUSED,
	BAD_ATTACHMENT,
	BLOB_EXPIRED,
	NICK_TOO_LONG,
	roomErrorOf,
	UPLOAD_INCOMPLETE,
} from "../../../lib/errors.ts";
import {
	BLOB_CHUNK,
	MAX_ATTACHMENT_BYTES,
	MAX_BLOB_READERS,
	MAX_LINE,
	MAX_MESSAGE_FILES,
	MAX_NICK,
	MAX_ROOM_ATTACHMENTS,
} from "../../../lib/limits.ts";
import { loopbackTcpDesignator } from "../../../lib/locator.ts";
import { ATTACH, POST, POST_FILES, READ, SUBSCRIBE, WRITE } from "../../../lib/protocol.ts";
import { Room } from "../../../lib/room/client.ts";
import {
	assert,
	dial,
	enterOrOpen,
	refusalCode,
	roomsTest,
	subscribeMembership,
	waitForLine,
	watchRoom,
	within,
	withServer,
} from "../../support/rooms_server.ts";
import { Argument, Ref } from "@glowcap/runtime";
roomsTest("a room refuses a post's own trailing args, an oversize file, and a short upload", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const roomRef = await enterOrOpen(session, "strict");
			const membership = await subscribeMembership(session, roomRef, "poster", session.spawn(() => null));

			// What rides after a line's text is the room's vocabulary; a member
			// supplying its own is refused rather than relayed, so nobody can forge
			// a presence change or a file record.
			for (
				const bad of [
					["hello", "roster", "forged"],
					["hello", "file", "x.bin", "application/octet-stream", 5n],
				] as Argument[][]
			) {
				const code = await refusalCode(() => session.send(membership, POST, bad));
				assert(code === BAD_ATTACHMENT, `expected bad-attachment, got ${code}`);
			}

			// A file the room will not hold is refused at attach, before a byte moves.
			const tooBig = await refusalCode(() =>
				session.send(membership, ATTACH, [
					"big.bin",
					"application/octet-stream",
					BigInt(MAX_ATTACHMENT_BYTES + 1),
				])
			);
			assert(tooBig === ATTACHMENT_REFUSED, `expected attachment-refused, got ${tooBig}`);
			const unnamed = await refusalCode(() =>
				session.send(membership, ATTACH, ["", "application/octet-stream", 4n])
			);
			assert(unnamed === ATTACHMENT_REFUSED, `an unnamed file should be refused, got ${unnamed}`);

			// A name is granted here, and every member carries what this room grants:
			// into the roster, into the line saying somebody joined, and in front of
			// everything they say. The directory holds a registered name to a
			// ceiling; this is where a room hands one out.
			const shouted = await refusalCode(() =>
				session.send(roomRef, SUBSCRIBE, ["n".repeat(MAX_NICK + 1), session.spawn(() => null)])
			);
			assert(shouted === NICK_TOO_LONG, `a room granted a name past its ceiling, got ${shouted}`);

			// Posting exposes the file while it streams. Writing beyond its declared
			// extent is still refused at the upload capability.
			const upload = await session.send(membership, ATTACH, ["short.bin", "application/octet-stream", 8n]);
			assert(upload instanceof Ref, "attach should answer an upload capability");
			await session.send(membership, POST_FILES, ["streaming"]);
			await session.send(upload as Ref, WRITE, [new Uint8Array([1, 2, 3])]);
			const over = await refusalCode(() => session.send(upload as Ref, WRITE, [new Uint8Array(16)]));
			assert(over === UPLOAD_INCOMPLETE, `a write past the declared size should refuse, got ${over}`);

			// Filling it exactly completes the already-published blob and spends the upload.
			await session.send(upload as Ref, WRITE, [new Uint8Array([4, 5, 6, 7, 8])]);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("a room drops its oldest file at the ceiling and says so on read", async () => {
	await withServer(async (port) => {
		const poster = await dial(loopbackTcpDesignator(port));
		const room = await Room.subscribe(poster, await enterOrOpen(poster, "attic"), "poster");

		// Every posted file comes back on our own subscription, so reading the
		// stream is how we get a capability to each one.
		const seen: Attachment[] = [];
		const collecting = (async () => {
			for await (const message of room.messages) {
				seen.push(...message.attachments);
				if (seen.length > MAX_ROOM_ATTACHMENTS) break;
			}
		})();

		// One more file than the room will hold, each a single byte, so the
		// ceiling that trips is the count rather than the byte budget.
		for (let i = 0; i <= MAX_ROOM_ATTACHMENTS; i += 1) {
			await room.attach({
				name: `f${i}.bin`,
				mime: "application/octet-stream",
				bytes: new Uint8Array([i & 0xff]),
			});
		}
		await collecting;
		assert(
			seen.length === MAX_ROOM_ATTACHMENTS + 1,
			`expected every post to come back, saw ${seen.length}`,
		);

		// The newest is readable and the oldest is gone. A dropped file says so
		// rather than answering nothing, which a reader could not tell from a
		// file that really was empty.
		const newest = await room.fetch(seen[seen.length - 1]);
		assert(newest.length === 1, `the newest file should still read, got ${newest.length} bytes`);
		let expiredCode: string | null = null;
		try {
			await room.fetch(seen[0]);
		} catch (err) {
			expiredCode = roomErrorOf(err)?.code ?? null;
		}
		assert(expiredCode === BLOB_EXPIRED, `expected blob-expired for the dropped file, got ${expiredCode}`);

		poster.close();
		await poster.serve().catch(() => {});
	});
});

roomsTest("a member may hold only so many unposted uploads", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const roomRef = await enterOrOpen(session, "patient");
			const membership = await subscribeMembership(session, roomRef, "poster", session.spawn(() => null));
			// An upload holds bytes nobody has seen, so a member that opens them
			// without posting is refused rather than allowed to accumulate.
			for (let i = 0; i < MAX_MESSAGE_FILES; i += 1) {
				const upload = await session.send(membership, ATTACH, [`f${i}.bin`, "application/octet-stream", 1n]);
				assert(upload instanceof Ref, "attach should answer an upload capability");
			}
			const code = await refusalCode(() =>
				session.send(membership, ATTACH, ["one-too-many.bin", "application/octet-stream", 1n])
			);
			assert(code === ATTACHMENT_REFUSED, `expected attachment-refused, got ${code}`);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("a room holds its own line cap, in the bytes the wire counts", async () => {
	await withServer(async (port) => {
		const talker = await dial(loopbackTcpDesignator(port));
		const roomRef = await enterOrOpen(talker, "capped");
		const room = await Room.subscribe(talker, roomRef, "talker");
		const watcher = await watchRoom(port, "capped", "watcher");

		// A client checks before it sends, so a reader is warned while typing. That
		// check is a courtesy to its own reader and nothing a room may lean on: a
		// peer posts what it likes, and every member carries what the room passes
		// on. So the room is asked directly, past any client-side check.
		let refused = "";
		await talker.send(room.membershipReference, POST, ["x".repeat(MAX_LINE + 1)]).catch((err) => {
			refused = err instanceof Error ? err.message : String(err);
		});
		assert(refused !== "", "a room took a line past the cap it states");

		// And counted in bytes rather than in JavaScript's own units, which is what
		// the wire counts and what the composer counts. An emoji is two of those
		// units and four bytes, so counting the wrong way let four times the cap
		// through: this line is inside the cap by one count and well past it by the
		// one that matters.
		const emoji = "🚀".repeat(MAX_LINE / 4);
		assert(emoji.length <= MAX_LINE, "the fixture is not inside the cap by JavaScript's count");
		let refusedEmoji = "";
		await talker.send(room.membershipReference, POST, [emoji + "🚀"]).catch((err) => {
			refusedEmoji = err instanceof Error ? err.message : String(err);
		});
		assert(refusedEmoji !== "", "a room counted a line in units the wire does not use");

		// A line inside the cap still goes, so the check refuses the right side of it.
		await room.say("well within it");
		await waitForLine(watcher.lines, /^talker: well within it$/);

		await room.leave();
		await watcher.leave();
		talker.close();
		await talker.serve().catch(() => {});
	});
});

roomsTest("a file that stops arriving is given up on rather than waited on forever", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "stalling"), "poster");
		const reader = await dial(loopbackTcpDesignator(port));
		const readerRoom = await Room.subscribe(reader, await enterOrOpen(reader, "stalling"), "reader");

		// Published with none of its bytes sent, so the read below parks. Parking is
		// ordinary and a room behaving itself settles it, which is why the deadline
		// this passes is short while the one the app ships sits above the window a
		// room may hold a reader for. What is not ordinary is a partner that never
		// settles it at all, and the reader has no other way out: the row is drawn
		// as still arriving, and a row that is arriving is one nothing restarts.
		const source = { name: "halted.bin", mime: "application/octet-stream", bytes: new Uint8Array([1, 2, 3]) };
		const upload = await senderRoom.stage(source);
		await senderRoom.postFiles("on its way");

		let posted: Attachment | null = null;
		for await (const message of readerRoom.messages) {
			if (message.attachments.length > 0) {
				posted = message.attachments[0];
				break;
			}
		}
		assert(posted !== null, "the staged file was never announced");

		let stalled: unknown = null;
		await fetchBlob(reader, posted, undefined, 200).catch((err) => {
			stalled = err;
		});
		assert(
			stalled instanceof Unanswered,
			`a read nobody answered ended as ${stalled === null ? "success" : String(stalled)}`,
		);

		// And giving up is not giving in: the same file arrives when its bytes do,
		// which is what makes the row's control worth offering again.
		await senderRoom.upload(upload, source);
		const bytes = await within(fetchBlob(reader, posted), "the file to arrive once its bytes were sent");
		assert(bytes.length === 3 && bytes[0] === 1, "the file did not arrive after the transfer resumed");

		await readerRoom.leave();
		reader.close();
		sender.close();
		await sender.serve().catch(() => {});
	});
});

roomsTest("a file the room is still receiving holds only so many readers waiting on it", async () => {
	await withServer(async (port) => {
		const sender = await dial(loopbackTcpDesignator(port));
		const senderRoom = await Room.subscribe(sender, await enterOrOpen(sender, "queue"), "poster");
		const reader = await dial(loopbackTcpDesignator(port));
		const readerRoom = await Room.subscribe(reader, await enterOrOpen(reader, "queue"), "reader");

		// Staged and published, with none of its bytes sent. A read for bytes the
		// room does not have waits rather than answering short, so every read below
		// parks: this is the one structure here that grows with what a peer sends.
		const source = { name: "slow.bin", mime: "application/octet-stream", bytes: new Uint8Array([7, 7, 7]) };
		const upload = await senderRoom.stage(source);
		await senderRoom.postFiles("coming");

		let posted: Attachment | null = null;
		for await (const message of readerRoom.messages) {
			if (message.attachments.length > 0) {
				posted = message.attachments[0];
				break;
			}
		}
		assert(posted !== null, "the staged file was never announced");

		const parked: Promise<Argument>[] = [];
		for (let i = 0; i < MAX_BLOB_READERS; i++) {
			const waiting = reader.send(posted.blob, READ, [0n, BigInt(BLOB_CHUNK)]) as Promise<Argument>;
			// Refused below, and every one of these settles when the bytes land. An
			// unobserved rejection would take the process down before the assertion.
			void waiting.catch(() => {});
			parked.push(waiting);
		}
		let refused = "";
		await reader.send(posted.blob, READ, [0n, BigInt(BLOB_CHUNK)]).catch((err) => {
			refused = err instanceof Error ? err.message : String(err);
		});
		assert(
			refused.includes(ATTACHMENT_REFUSED) || refused.includes("readers waiting"),
			`a file past its reader ceiling answered ${JSON.stringify(refused)}`,
		);

		// And the ceiling is a ceiling, not a wall: the readers already waiting are
		// owed their bytes, and the upload finishing is what pays them.
		await senderRoom.upload(upload, source);
		const first = await within(parked[0], "a parked read to be paid by the finished upload");
		assert(first instanceof Uint8Array && first[0] === 7, "a parked read did not get the file it waited for");

		await readerRoom.leave();
		reader.close();
		sender.close();
		await sender.serve().catch(() => {});
	});
});
