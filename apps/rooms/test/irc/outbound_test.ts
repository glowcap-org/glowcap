import {
	IRC_OUTBOUND_INTERVAL_MS,
	IRC_OUTBOUND_QUEUE_BYTES,
	IRC_OUTBOUND_QUEUE_LINES,
	IrcChannelRelay,
} from "../../irc/bridge/outbound.ts";
import { parseIrcLine } from "../../irc/protocol.ts";
import { assertEquals } from "../assert.ts";

const decode = (bytes: Uint8Array): string => new TextDecoder().decode(bytes).replace(/\r\n$/, "");

Deno.test("IRC channel demand joins, throttles admitted lines, and parts after drain", async () => {
	const sent: string[] = [];
	const pauses: number[] = [];
	const relay = new IrcChannelRelay("#room", "bridgebot", {
		writable: true,
		pause: (milliseconds) => {
			pauses.push(milliseconds);
			return Promise.resolve();
		},
	});
	relay.setReaders(1);
	relay.connected((bytes) => {
		sent.push(decode(bytes));
		return Promise.resolve();
	}, () => {});
	await Promise.resolve();
	assertEquals(sent, ["JOIN #room"]);
	relay.observe(parseIrcLine(":bridgebot!u@example JOIN :#room"));
	await Promise.all([relay.post("alice", "one"), relay.post("bob", "two")]);
	assertEquals(sent.slice(1), ["PRIVMSG #room :<alice> one", "PRIVMSG #room :<bob> two"]);
	assertEquals(pauses, [IRC_OUTBOUND_INTERVAL_MS]);
	relay.setReaders(0);
	await Promise.resolve();
	assertEquals(sent.at(-1), "PART #room :no Rooms readers");
});

Deno.test("IRC kick retires the connection instead of rejoining around backoff", async () => {
	let fail!: (error: Error) => void;
	const failed = new Promise<Error>((resolve) => {
		fail = resolve;
	});
	const sent: string[] = [];
	const relay = new IrcChannelRelay("#room", "bridgebot");
	relay.setReaders(1);
	relay.connected((bytes) => {
		sent.push(decode(bytes));
		return Promise.resolve();
	}, fail);
	relay.observe(parseIrcLine(":bridgebot JOIN :#room"));
	relay.observe(parseIrcLine(":operator KICK #room bridgebot :operator decision"));
	assertEquals((await failed).message, "IRC bridge was kicked from #room");
	await Promise.resolve();
	assertEquals(sent, ["JOIN #room"]);
});

Deno.test("IRC channel join confirmation has a finite connection deadline", async () => {
	let fail!: (error: Error) => void;
	const failed = new Promise<Error>((resolve) => {
		fail = resolve;
	});
	const relay = new IrcChannelRelay("#room", "bridgebot", { joinTimeoutMs: 1 });
	relay.setReaders(1);
	relay.connected(() => Promise.resolve(), fail);
	const error = await failed;
	assertEquals(error.message, "IRC did not confirm joining #room");
	assertEquals(relay.joined, false);
});

Deno.test("IRC outbound retains the exact admitted line across reconnect", async () => {
	const attempts: string[] = [];
	const relay = new IrcChannelRelay("#room", "bridgebot", { writable: true, sendIntervalMs: 0 });
	relay.setReaders(1);
	relay.connected((bytes) => {
		const line = decode(bytes);
		attempts.push(line);
		return line.startsWith("PRIVMSG") ? Promise.reject(new Error("fixture disconnect")) : Promise.resolve();
	}, () => {});
	relay.observe(parseIrcLine(":bridgebot JOIN :#room"));
	const delivered = relay.post("alice", "survives");
	await Promise.resolve();
	assertEquals(relay.queuedLines, 1);
	relay.disconnected();
	relay.connected((bytes) => {
		attempts.push(decode(bytes));
		return Promise.resolve();
	}, () => {});
	relay.observe(parseIrcLine(":bridgebot JOIN :#room"));
	await delivered;
	assertEquals(attempts.filter((line) => line.startsWith("PRIVMSG")), [
		"PRIVMSG #room :<alice> survives",
		"PRIVMSG #room :<alice> survives",
	]);
	assertEquals([relay.queuedLines, relay.queuedBytes], [0, 0]);
});

Deno.test("IRC outbound refuses growth beyond its line and byte budget", () => {
	const relay = new IrcChannelRelay("#room", "bridgebot", { writable: true });
	for (let index = 0; index < IRC_OUTBOUND_QUEUE_LINES; index += 1) void relay.post("reader", `line ${index}`);
	let refused = "";
	try {
		void relay.post("reader", "one too many");
	} catch (error) {
		refused = String(error);
	}
	assertEquals(refused.includes("queue is full"), true, `queue overflow was ${refused}`);
	assertEquals(relay.queuedLines, IRC_OUTBOUND_QUEUE_LINES);
	assertEquals(relay.queuedBytes <= IRC_OUTBOUND_QUEUE_BYTES, true);

	const tooWide = new IrcChannelRelay("#room", "bridgebot", { writable: true });
	let oversized = "";
	try {
		void tooWide.post("reader", "x".repeat(tooWide.lineBytes + 1));
	} catch (error) {
		oversized = String(error);
	}
	assertEquals(oversized.includes(`${tooWide.lineBytes} bytes`), true, `line overflow was ${oversized}`);
	assertEquals([tooWide.queuedLines, tooWide.queuedBytes], [0, 0]);
});
