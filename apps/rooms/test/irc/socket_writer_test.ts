import { IRC_WRITE_QUEUE_BYTES, IRC_WRITE_QUEUE_LINES, IrcSocketWriter } from "../../irc/socket_writer.ts";
import { assertEquals } from "../assert.ts";

Deno.test("IRC socket writer bounds retained output before a slow peer can grow it", async () => {
	let release!: () => void;
	const blocked = new Promise<void>((resolve) => {
		release = resolve;
	});
	let failures = 0;
	const conn = {
		async write(bytes: Uint8Array): Promise<number> {
			await blocked;
			return bytes.length;
		},
	} as Deno.Conn;
	const writer = new IrcSocketWriter(conn, () => failures += 1);
	const pending: Promise<void>[] = [];
	for (let at = 0; at < IRC_WRITE_QUEUE_LINES; at += 1) {
		pending.push(writer.send("NOTICE", ["alice", `line ${at}`]).catch(() => {}));
	}
	assertEquals(writer.queuedLines, IRC_WRITE_QUEUE_LINES);
	assertEquals(writer.queuedBytes <= IRC_WRITE_QUEUE_BYTES, true);
	let refused = "";
	try {
		await writer.send("NOTICE", ["alice", "one too many"]);
	} catch (error) {
		refused = String(error);
	}
	assertEquals(refused.includes("queue is full"), true, refused);
	assertEquals(failures, 1, "queue overflow did not retire the socket exactly once");
	release();
	await Promise.all(pending);
});
