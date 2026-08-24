// The reader connection's own registration walk, SASL included.
//
// The gateway enforces the custody policy (credentials only over TLS); the
// mechanism below is policy-free on purpose, which is what lets a scripted
// cleartext fixture prove the wire walk the way the bridge suite proves the
// shared feed's.

import { openReaderConnection } from "../irc/reader_connection.ts";
import { encodeIrc, readIrcLines } from "../irc/protocol.ts";
import { assert } from "./support/rooms_server.ts";

async function writeAll(conn: Deno.Conn, bytes: Uint8Array): Promise<void> {
	let offset = 0;
	while (offset < bytes.length) offset += await conn.write(bytes.subarray(offset));
}

const say = (line: string) => new TextEncoder().encode(line + "\r\n");

Deno.test("a reader connection authenticates its account and joins", async () => {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	const fixture = (async () => {
		const conn = await listener.accept();
		listener.close();
		try {
			const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
			assert((await lines.next()).value?.command === "CAP", "an account starts with CAP LS");
			assert((await lines.next()).value?.command === "NICK", "then the nick");
			assert((await lines.next()).value?.command === "USER", "then the user line");
			await writeAll(conn, say(":fixture CAP reader LS :sasl=PLAIN"));
			const req = (await lines.next()).value;
			assert(req?.command === "CAP" && req.params[0] === "REQ", "the reader requests sasl");
			await writeAll(conn, say(":fixture CAP reader ACK :sasl"));
			assert((await lines.next()).value?.params[0] === "PLAIN", "PLAIN is the mechanism");
			await writeAll(conn, encodeIrc("AUTHENTICATE", ["+"]));
			const auth = (await lines.next()).value;
			const payload = new TextDecoder().decode(
				Uint8Array.from(atob(auth?.params[0] ?? ""), (char) => char.charCodeAt(0)),
			);
			assert(payload === "\0acct\0pw", `the payload names the account: ${JSON.stringify(payload)}`);
			await writeAll(conn, say(":fixture 903 reader :SASL authentication successful"));
			assert((await lines.next()).value?.command === "CAP", "the reader ends capability negotiation");
			await writeAll(conn, say(":fixture 001 reader :welcome"));
			const join = (await lines.next()).value;
			assert(join?.command === "JOIN" && join.params[0] === "#news", "then joins its channel");
			await writeAll(conn, say(":reader!u@example JOIN :#news"));
		} finally {
			// The link's close arrives after the test's assertions; the fixture
			// holds the socket until then.
			await new Promise((resolve) => setTimeout(resolve, 50));
			try {
				conn.close();
			} catch { /* the reader closed first */ }
		}
	})();
	const link = await openReaderConnection(
		{ hostname: "127.0.0.1", port, tls: false, nick: "reader" },
		"reader",
		"#news",
		{ account: "acct", password: "pw" },
	);
	link.close();
	await fixture;
	await link.down;
});
