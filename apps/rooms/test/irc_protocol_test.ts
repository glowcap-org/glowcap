import { assertEquals } from "./assert.ts";
import { encodeIrc, encodeIrcMessage, ircFold, nickFromPrefix, parseIrcLine, readIrcLines } from "../irc/protocol.ts";

Deno.test("IRC grammar keeps tags, prefix, command, and trailing text distinct", () => {
	const message = parseIrcLine("@time=now;draft/example=hello\\sworld :alice!u@example PRIVMSG #ocapn :hello there");
	assertEquals([...message.tags], [["time", "now"], ["draft/example", "hello world"]]);
	assertEquals(message.prefix, "alice!u@example");
	assertEquals(message.command, "PRIVMSG");
	assertEquals(message.params, ["#ocapn", "hello there"]);
	assertEquals(nickFromPrefix(message.prefix), "alice");
});

Deno.test("IRC encoder refuses line injection and protocol-sized overflow", () => {
	assertEquals(
		new TextDecoder().decode(encodeIrc("privmsg", ["#ocapn", "hello there"])),
		"PRIVMSG #ocapn :hello there\r\n",
	);
	let injected = false;
	try {
		encodeIrc("NICK", ["alice\r\nOPER root"]);
	} catch {
		injected = true;
	}
	assertEquals(injected, true, "a parameter could inject another IRC line");
	let oversized = false;
	try {
		encodeIrc("PRIVMSG", ["#ocapn", "x".repeat(512)]);
	} catch {
		oversized = true;
	}
	assertEquals(oversized, true, "an oversized IRC line was emitted");
});

Deno.test("IRC encoder shares one bounded grammar with server prefixes and numerics", () => {
	assertEquals(
		new TextDecoder().decode(encodeIrcMessage("001", ["alice", "welcome"], "rooms.local")),
		":rooms.local 001 alice welcome\r\n",
	);
	let malformed = false;
	try {
		encodeIrcMessage("NOTICE", ["alice", "hello"], "bad server");
	} catch {
		malformed = true;
	}
	assertEquals(malformed, true, "a malformed server prefix was emitted");
});

Deno.test("IRC reader frames arbitrary chunks with one bounded line buffer", async () => {
	const readable = new ReadableStream<Uint8Array>({
		start(controller) {
			controller.enqueue(new TextEncoder().encode(":a PING :one\r"));
			controller.enqueue(new TextEncoder().encode("\n:b PRIVMSG #c :two words\r\n"));
			controller.close();
		},
	});
	const messages = [];
	for await (const message of readIrcLines(readable)) messages.push(message);
	assertEquals(messages.map((message) => [message.command, message.params]), [
		["PING", ["one"]],
		["PRIVMSG", ["#c", "two words"]],
	]);
});

Deno.test("IRC reader fails closed on an overlong or truncated peer", async () => {
	for (const bytes of [new Uint8Array(512).fill(0x61), new TextEncoder().encode("PING :unfinished")]) {
		const readable = new ReadableStream<Uint8Array>({
			start(controller) {
				controller.enqueue(bytes);
				controller.close();
			},
		});
		let refused = false;
		try {
			for await (const _message of readIrcLines(readable)) { /* no complete line */ }
		} catch {
			refused = true;
		}
		assertEquals(refused, true, "malformed stream reached the bridge");
	}
});

Deno.test("IRC casemapping follows RFC 1459 rather than JavaScript lowercase alone", () => {
	assertEquals(ircFold("Nick[\\^"), ircFold("nICK{|~"));
});
