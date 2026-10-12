// The scripted IRC wire used by native bridge process scenarios. It owns exact
// writes and the server half of one SASL PLAIN registration. Production IRC
// policy remains in the Rust bridge.

import { type IrcMessage, readIrcLines } from "../../irc/protocol.ts";
import { assert } from "../support/rooms_server.ts";

export async function writeAll(conn: Deno.Conn, bytes: Uint8Array): Promise<void> {
	let offset = 0;
	while (offset < bytes.length) offset += await conn.write(bytes.subarray(offset));
}

export const say = (line: string) => new TextEncoder().encode(line + "\r\n");

export async function registerSaslFeed(
	conn: Deno.Conn,
	nick: string,
	account: string,
	password: string,
	channel: string,
	accepted: boolean,
): Promise<AsyncIterableIterator<IrcMessage>> {
	const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
	const cap = (await lines.next()).value;
	const nickLine = (await lines.next()).value;
	const user = (await lines.next()).value;
	assert(cap?.command === "CAP" && cap.params[0] === "LS", "the authenticated seat negotiates capabilities");
	assert(
		nickLine?.command === "NICK" && nickLine.params[0] === nick,
		`the authenticated seat requested ${JSON.stringify(nickLine?.params)}`,
	);
	assert(
		user?.command === "USER" && user.params[0] === nick &&
			user.params[3] === "glowcap bridge bot; admin: fixture-admin",
		`the authenticated seat's user was ${JSON.stringify(user?.params)}`,
	);
	await writeAll(conn, say(`:fixture CAP ${nick} LS :sasl=PLAIN`));
	const requested = (await lines.next()).value;
	assert(requested?.command === "CAP" && requested.params[0] === "REQ", "the seat requests SASL");
	await writeAll(conn, say(`:fixture CAP ${nick} ACK :sasl`));
	const mechanism = (await lines.next()).value;
	assert(
		mechanism?.command === "AUTHENTICATE" && mechanism.params[0] === "PLAIN",
		"the seat requests SASL PLAIN",
	);
	await writeAll(conn, say("AUTHENTICATE +"));
	const authentication = (await lines.next()).value;
	assert(authentication?.command === "AUTHENTICATE", "the seat sends its SASL payload");
	assert(
		atob(authentication.params[0] ?? "") === `\0${account}\0${password}`,
		"the seat authenticated a different account",
	);
	if (!accepted) {
		await writeAll(conn, say(`:fixture 904 ${nick} :SASL authentication failed`));
		return lines;
	}
	await writeAll(conn, say(`:fixture 903 ${nick} :SASL authentication successful`));
	const capEnd = (await lines.next()).value;
	assert(capEnd?.command === "CAP" && capEnd.params[0] === "END", "the seat ends capability negotiation");
	await writeAll(conn, say(`:fixture 005 ${nick} BOT=b :supported`));
	const mode = (await lines.next()).value;
	assert(
		mode?.command === "MODE" && mode.params[0] === nick && mode.params[1] === "+b",
		"the feed enables the server-advertised bot mode",
	);
	await writeAll(conn, say(`:fixture 001 ${nick} :welcome`));
	const join = (await lines.next()).value;
	assert(join?.command === "JOIN" && join.params[0] === channel, "the authenticated seat joins");
	await writeAll(conn, say(`:${nick}!u@example JOIN :${channel}`));
	return lines;
}
