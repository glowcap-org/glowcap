// Files on a direct message, both directions, and the handle that edits them.

import {
	Attachment,
	attachmentArgs,
	fetchBlob,
	readAttachments,
	readRefileChange,
	sendWithAttachments,
} from "../../lib/attachment.ts";

import { BLOB_CHUNK, MAX_DIRECT_ATTACHMENTS, MAX_MESSAGE_FILES } from "../../lib/limits.ts";
import { loopbackTcpDesignator, roomsHost, roomsListen } from "../../lib/locator.ts";
import { DM, EDIT, REFILE, WITHDRAW } from "../../lib/protocol.ts";

import { assert, dial, roomsTest } from "../support/rooms_server.ts";
import { Argument, currentSession, Ref, Session } from "@pancake/runtime";
roomsTest("files ride a direct message in both directions over its existing transport", async () => {
	const encoder = new TextEncoder();
	const sent = new Uint8Array(BLOB_CHUNK + 17);
	for (let i = 0; i < sent.length; i += 1) sent[i] = i & 0xff;
	const replied = encoder.encode("the reply is a file too");

	let resolveReceived!: (bytes: Uint8Array) => void;
	let rejectReceived!: (reason?: unknown) => void;
	const received = new Promise<Uint8Array>((resolve, reject) => {
		resolveReceived = resolve;
		rejectReceived = reject;
	});
	let resolveReply!: (bytes: Uint8Array) => void;
	let rejectReply!: (reason?: unknown) => void;
	const replyReceived = new Promise<Uint8Array>((resolve, reject) => {
		resolveReply = resolve;
		rejectReply = reject;
	});
	const held: Attachment[] = [];

	const receiverHost = roomsHost();
	let arriving: Session | null = null;
	receiverHost.publishGiftable("dm-files", (verb, args) => {
		if (verb === "hold-file") {
			held.push(...readAttachments(args, 1));
			return null;
		}
		if (verb !== DM) throw new Error(`dm-files has no method ${verb}`);
		const session = currentSession() ?? arriving;
		const reply = args[1];
		const files = readAttachments(args, reply instanceof Ref ? 2 : 1);
		if (session === null || !(reply instanceof Ref) || files.length !== 1) {
			throw new Error(
				`direct file message needs its arriving session, reply, and one file ` +
					`(session=${session !== null}, reply=${reply instanceof Ref}, token=${
						String(args[2])
					}, files=${files.length})`,
			);
		}
		queueMicrotask(() => {
			fetchBlob(session, files[0]).then(resolveReceived, rejectReceived);
			sendWithAttachments(session, reply, DM, ["file reply"], [{
				name: "reply.txt",
				mime: "text/plain",
				bytes: replied,
			}]).catch(rejectReply);
		});
		return null;
	});

	const listener = await roomsListen("127.0.0.1", 0, receiverHost);
	const serving = (async () => {
		for await (const session of listener) {
			arriving = session;
			await session.serve().catch(() => {});
			break;
		}
	})();
	const sender = await dial(loopbackTcpDesignator(listener.port));
	sender.serve().catch(() => {});
	try {
		const target = await sender.fetch("dm-files");
		const reply = sender.spawn((verb, args) => {
			if (verb !== DM) throw new Error(`reply has no method ${verb}`);
			const files = readAttachments(args, 1);
			if (files.length !== 1) throw new Error("reply carried no file");
			queueMicrotask(() => fetchBlob(sender, files[0]).then(resolveReply, rejectReply));
			return null;
		});
		const oneRecord = attachmentArgs({
			name: "bounded.txt",
			mime: "text/plain",
			size: 1,
			blob: reply,
			width: 0,
			height: 0,
		});
		// A direct peer must not make the receiver retain an unbounded file-record
		// suffix. The walk stops at the cap — bounded — and still yields the
		// message's files rather than throwing the whole message away, which the
		// old refusal did, and one record over the cap was enough to cause it.
		const capped = readAttachments(
			["message", ...Array.from({ length: MAX_MESSAGE_FILES + 5 }, () => oneRecord).flat()],
			1,
		);
		assert(
			capped.length === MAX_MESSAGE_FILES,
			`an over-count message was not bounded to the cap: got ${capped.length}`,
		);
		await sendWithAttachments(sender, target, DM, ["file request", reply], [{
			name: "pattern.bin",
			mime: "application/octet-stream",
			bytes: sent,
		}]);

		const [atReceiver, atSender] = await Promise.all([received, replyReceived]);
		assert(
			atReceiver.length === sent.length && atReceiver.every((byte, i) => byte === sent[i]),
			"the direct receiver should fetch every chunk from the sender-hosted blob",
		);
		assert(
			atSender.length === replied.length && atSender.every((byte, i) => byte === replied[i]),
			"the direct reply should carry its own sender-hosted blob on the same connection",
		);

		// A direct sender is the file store, so its process-wide held-source
		// ceiling is as load-bearing as the room server's. Leave one more than the
		// count budget unfetched: the oldest capability must break and the newest
		// must still answer.
		for (let i = 0; i <= MAX_DIRECT_ATTACHMENTS; i += 1) {
			await sendWithAttachments(sender, target, "hold-file", ["held"], [{
				name: `held-${i}.bin`,
				mime: "application/octet-stream",
				bytes: new Uint8Array([i & 0xff]),
			}]);
		}
		assert(held.length === MAX_DIRECT_ATTACHMENTS + 1, "the receiver should hold every file reference");
		let oldestExpired = false;
		try {
			await fetchBlob(arriving!, held[0]);
		} catch {
			oldestExpired = true;
		}
		assert(oldestExpired, "the direct sender should evict its oldest unfetched source at the ceiling");
		const newest = await fetchBlob(arriving!, held[held.length - 1]);
		assert(newest[0] === (MAX_DIRECT_ATTACHMENTS & 0xff), "the newest direct source should remain readable");
	} finally {
		sender.close();
		await sender.serve().catch(() => {});
		listener.close();
		await serving;
	}
});

roomsTest("a direct message answers a line handle that edits, refiles, and withdraws it", async () => {
	// The receiver records each line and mints a handle that mutates the record,
	// the direct sibling of a room's line reference. This proves the wire contract
	// the browser's own handle relies on: `dm` answers a handle, and that handle
	// takes edit, refile, and withdraw with the argument shapes they document.
	const lines: { text: string; files: string[]; withdrawn: boolean }[] = [];
	const receiverHost = roomsHost();
	receiverHost.publishGiftable("dm-editable", (verb: string, args: Argument[]): Argument => {
		if (verb !== DM) throw new Error(`dm-editable has no method ${verb}`);
		const session = currentSession();
		const reply = args[1];
		const recordAt = reply instanceof Ref ? 2 : 1;
		const line = {
			text: typeof args[0] === "string" ? args[0] : "",
			files: readAttachments(args, recordAt).map((file) => file.name),
			withdrawn: false,
		};
		lines.push(line);
		if (session === null) return null;
		// The handle the sender holds to change this line afterwards.
		return session.spawn((v: string, a: Argument[]): Argument => {
			if (v === EDIT) {
				if (typeof a[0] !== "string") throw new Error("edit needs text");
				line.text = a[0];
				return null;
			}
			if (v === WITHDRAW) {
				line.withdrawn = true;
				return null;
			}
			if (v === REFILE) {
				// The same parse the browser receiver runs, so the wire shape and its
				// bounds have one authority and this test exercises the real one:
				// an out-of-range or repeated index, and a result past the message
				// file cap, refuse here exactly as they do in the page.
				const { caption, keep, records } = readRefileChange(a, line.files.length);
				line.text = caption;
				line.files = [...keep.map((index) => line.files[index]), ...records.map((file) => file.name)];
				return null;
			}
			throw new Error(`a direct line has no method ${v}`);
		});
	});

	const listener = await roomsListen("127.0.0.1", 0, receiverHost);
	const serving = (async () => {
		for await (const session of listener) {
			void session.serve().catch(() => {});
		}
	})();
	const sender = await dial(loopbackTcpDesignator(listener.port));
	sender.serve().catch(() => {});
	try {
		const target = await sender.fetch("dm-editable");
		// A file line, answered with its handle.
		const handle = await sendWithAttachments(sender, target, DM, ["hello"], [
			{ name: "a.txt", mime: "text/plain", bytes: new Uint8Array([1]) },
			{ name: "b.txt", mime: "text/plain", bytes: new Uint8Array([2]) },
		]);
		assert(handle instanceof Ref, "a direct message must answer a line handle");
		assert(lines.length === 1 && lines[0].files.join() === "a.txt,b.txt", "the file line arrived with both files");

		// Editing the caption leaves the files alone. Each caption is read into a
		// fresh local so the assert's narrowing does not pin the mutable field to
		// one literal for the checks that follow.
		await sender.send(handle, EDIT, ["hello again"]);
		const afterEdit: string = lines[0].text;
		assert(afterEdit === "hello again", "the edit changed the caption");
		assert(lines[0].files.join() === "a.txt,b.txt", "the edit kept the files");
		let badEditRefused = false;
		try {
			await sender.send(handle as Ref, EDIT, [false]);
		} catch {
			badEditRefused = true;
		}
		assert(badEditRefused, "an edit without text should be refused");
		assert(lines[0].text === "hello again", "a refused edit left the line unchanged");

		// A refile the shape refuses changes nothing: an index the line does not
		// have, an index kept twice, and a set past the message file cap. Every
		// argument here is the sender's, and a direct line has no server to bound
		// it, so the receiver's own refusal is the whole defense — including
		// against growth compounding across refiles, which is why the cap counts
		// kept and added together.
		for (
			const [badArgs, why] of [
				[[false], "a caption that is not text"],
				[["over", 9n], "an index past the line's files"],
				[["twice", 0n, 0n], "an index kept twice"],
				[["trailing", true], "a trailing argument that is not a file record"],
				[["short-record", "file", "only-a-name"], "a truncated file record"],
				[[
					"crowded",
					0n,
					1n,
					...Array.from(
						{ length: MAX_MESSAGE_FILES - 1 },
						(_, i) =>
							attachmentArgs({
								name: `flood-${i}.txt`,
								mime: "text/plain",
								size: 1,
								blob: handle as Ref,
								width: 0,
								height: 0,
							}),
					).flat(),
				], "kept plus added past the cap"],
			] as [Argument[], string][]
		) {
			let refused = false;
			try {
				await sender.send(handle as Ref, REFILE, badArgs);
			} catch {
				refused = true;
			}
			assert(refused, `a refile with ${why} should be refused`);
		}
		assert(lines[0].files.join() === "a.txt,b.txt", "a refused refile left the files as they were");

		// Refiling keeps b (index 1) and adds c, dropping a — b is never re-sent.
		await sendWithAttachments(sender, handle, REFILE, ["refiled", 1n], [
			{ name: "c.txt", mime: "text/plain", bytes: new Uint8Array([3]) },
		]);
		const afterRefile: string = lines[0].text;
		assert(afterRefile === "refiled", "the refile changed the caption");
		assert(lines[0].files.join() === "b.txt,c.txt", `the refile set was ${lines[0].files.join()}`);

		// Withdrawing takes the whole line back.
		await sender.send(handle, WITHDRAW, []);
		assert(lines[0].withdrawn, "withdraw took the line back");
	} finally {
		sender.close();
		await sender.serve().catch(() => {});
		listener.close();
		await serving;
	}
});
