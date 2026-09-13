// Exercise the installed executable and its socket owner, using the existing
// Rooms client as a compatibility consumer and a local IRC server as the peer.
import { Directory, Room } from "../../lib/room/client.ts";
import { type IrcMessage, readIrcLines } from "../../irc/protocol.ts";
import { assert, dial, roomsTest, ROOT, within } from "../support/rooms_server.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";
import { IRC_BRIDGE as BRIDGE } from "../support/paths.ts";
import { assertEquals } from "../assert.ts";
import { registerSaslFeed, say, writeAll } from "./bridge_fixture.ts";

async function scene(
	tls: boolean,
	run: (directory: Directory, accept: () => Promise<Deno.Conn>, proc: Deno.ChildProcess) => Promise<void>,
) {
	const listener = tls
		? Deno.listenTls({
			hostname: "127.0.0.1",
			port: 0,
			cert: await Deno.readTextFile(`${ROOT}test/net/fixtures/tls_server.pem`),
			key: await Deno.readTextFile(`${ROOT}test/net/fixtures/tls_server.key`),
		})
		: Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const sockets: Deno.Conn[] = [];
	const proc = spawnOwned(BRIDGE, {
		args: [
			"--network=fixture",
			"--channel=#news",
			"--irc-nick=bridgebot",
			"--irc-realname=glowcap bridge bot; admin: fixture-admin",
			"--irc-host=localhost",
			`--irc-port=${listener.addr.port}`,
			`--tls=${tls}`,
			...(tls ? ["--mode=two-way", "--sasl-account=bridge-account"] : []),
		],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
		env: {
			SSL_CERT_FILE: `${ROOT}test/net/fixtures/tls_root.pem`,
			GLOWCAP_ROOMS_IRC_SASL_PASSWORD: "bridge-password",
		},
	});
	const diagnostic = new Response(proc.stderr).text();
	let directory: Directory | undefined;
	try {
		const reader = proc.stdout.getReader();
		let text = "";
		let port: string | undefined;
		try {
			while (!port) {
				const next = await within(reader.read(), "native bridge announcement");
				assert(!next.done, "bridge exited before announcement");
				text += new TextDecoder().decode(next.value);
				port = text.match(/ROOMS-IRC-BRIDGE-LISTENING (\d+) fixture\/#news\n/)?.[1];
			}
		} finally {
			reader.releaseLock();
		}
		directory = await Directory.connect(`127.0.0.1:${port}`, dial);
		await run(directory, async () => {
			const conn = await within<Deno.Conn>(listener.accept(), "IRC connection");
			sockets.push(conn);
			return conn;
		}, proc);
	} finally {
		await directory?.close();
		await stopOwned(proc);
		listener.close();
		for (const conn of sockets) {
			try {
				conn.close();
			} catch { /* already retired */ }
		}
		const status = await proc.status;
		const errors = await diagnostic;
		assert(status.success, `bridge did not shut down successfully: ${errors}`);
	}
}
async function next(lines: AsyncIterator<IrcMessage>, command: string): Promise<IrcMessage> {
	const item = await within(lines.next(), `IRC ${command}`);
	assert(!item.done, `IRC ended before ${command}`);
	assertEquals(item.value.command, command);
	return item.value;
}
async function register(conn: Deno.Conn) {
	const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
	assertEquals((await next(lines, "NICK")).params, ["bridgebot"]);
	assertEquals((await next(lines, "USER")).params, [
		"bridgebot",
		"0",
		"*",
		"glowcap bridge bot; admin: fixture-admin",
	]);
	await writeAll(conn, say(":fixture 005 bridgebot BOT=b :supported"));
	assertEquals((await next(lines, "MODE")).params, ["bridgebot", "+b"]);
	await writeAll(conn, say(":fixture 001 bridgebot :welcome"));
	return lines;
}

roomsTest("native IRC bridge preserves readers and publications across feed reconnection", async () => {
	await scene(false, async (directory, accept) => {
		const conn = await accept();
		const lines = await register(conn);
		const publications = await directory.list();
		assertEquals(publications.map((row) => row.name), ["fixture/#news"]);
		assertEquals((await directory.watch(() => {})).map((row) => row.name), ["fixture/#news"]);
		const reference = await directory.enter("fixture/#news");
		const room = await Room.subscribe(directory.session, reference, "reader");
		const messages = room.messages.getReader();
		assertEquals((await next(lines, "JOIN")).params, ["#news"]);
		await writeAll(conn, say(":bridgebot!u@example JOIN :#news"));
		await writeAll(conn, say(":alice!u@example PRIVMSG #news :first connection"));
		const received = async (text: string) => {
			while (true) {
				const item = await within(messages.read(), text);
				assert(!item.done, "room ended during reconnection");
				if (!item.value.system && item.value.text === text) {
					assertEquals(item.value.from, "irc/alice");
					assertEquals(item.value.change, "said");
					assert(item.value.lineId !== undefined, "IRC line arrived without archive identity");
					return item.value.lineId;
				}
			}
		};
		conn.close();
		const firstLine = await received("first connection");
		const refused = await room.say("not writable").then(() => "accepted", String);
		assert(refused.includes("read-only"), refused);
		const replacement = await accept();
		const replacementLines = await register(replacement);
		await next(replacementLines, "JOIN");
		await writeAll(replacement, say(":bridgebot!u@example JOIN :#news"));
		await writeAll(replacement, say(":alice!u@example PRIVMSG #news :second connection"));
		const secondLine = await received("second connection");
		assert(secondLine > firstLine, "IRC line identity did not advance across feed reconnection");
		const renewed = await Room.subscribe(directory.session, reference, "renewed");
		const stale = await room.say("stale").then(() => "accepted", String);
		assert(stale.includes("not-room-member"), stale);
		await renewed.leave();
		await next(replacementLines, "PART");
		messages.releaseLock();
	});
});

roomsTest("native IRC bridge authenticates, writes before echo, and bounds pending posts at shutdown", async () => {
	await scene(true, async (directory, accept, proc) => {
		const conn = await accept();
		const joining = registerSaslFeed(conn, "bridgebot", "bridge-account", "bridge-password", "#news", true);
		const room = await Room.subscribe(directory.session, await directory.enter("fixture/#news"), "reader");
		const messages = room.messages.getReader();
		const lines = await within(joining, "TLS and SASL registration");
		await room.say("hello IRC");
		assertEquals((await next(lines, "PRIVMSG")).params, ["#news", "<reader> hello IRC"]);
		while (true) {
			const item = await within(messages.read(), "post receipt echo");
			assert(!item.done, "room ended before echo");
			if (!item.value.system && item.value.text === "hello IRC") {
				assertEquals(item.value.from, "reader");
				assertEquals(item.value.change, "said");
				assertEquals(item.value.lineId, 1);
				break;
			}
		}
		// Lose the socket, then withhold registration on its replacement so
		// the accepted queue cannot drain while exercising its exact limit.
		conn.close();
		const replacement = await accept();
		const pending = Array.from({ length: 64 }, (_, at) => room.say(`queued ${at}`).then(() => "accepted", String));
		const full = await within(room.say("one too many").then(() => "accepted", String), "outbound overload refusal");
		assert(full.includes("queue is full"), full);
		await room.leave();
		const resumed = await within(
			registerSaslFeed(replacement, "bridgebot", "bridge-account", "bridge-password", "#news", true),
			"rejoin for accepted posts after the reader leaves",
		);
		assertEquals((await next(resumed, "PRIVMSG")).params, ["#news", "<reader> queued 0"]);
		assertEquals(await pending[0], "accepted");
		proc.kill("SIGTERM");
		const answers = await within(Promise.all(pending), "pending posts at shutdown");
		assert(answers.slice(1).every((answer) => answer !== "accepted"), "unwritten posts succeeded on shutdown");
		assert((await within(proc.status, "native bridge shutdown")).success, "bridge failed to stop");
		messages.releaseLock();
	});
});

roomsTest("the installed IRC bridge rejects a public test endpoint before DNS or dial", async () => {
	const proc = spawnOwned(BRIDGE, {
		args: [
			"--network=blocked",
			"--channel=#never-joined",
			"--irc-nick=bridgebot",
			"--irc-realname=glowcap bridge bot; admin: fixture-admin",
			"--irc-host=irc.libera.chat",
			"--irc-port=6697",
			"--tls=false",
		],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
	let directory: Directory | undefined;
	let room: Room | undefined;
	try {
		const stdout = proc.stdout.getReader();
		let announcement = "";
		try {
			while (!announcement.includes("ROOMS-IRC-BRIDGE-LISTENING")) {
				const next = await within(stdout.read(), "guarded bridge announcement");
				assert(!next.done, "guarded bridge exited before announcement");
				announcement += new TextDecoder().decode(next.value);
			}
		} finally {
			stdout.releaseLock();
		}
		const port = announcement.match(/ROOMS-IRC-BRIDGE-LISTENING (\d+) blocked\/#never-joined/)?.[1];
		assert(port !== undefined, `guarded bridge announced an unexpected endpoint: ${announcement}`);
		directory = await Directory.connect(`127.0.0.1:${port}`, dial);
		room = await Room.subscribe(directory.session, await directory.enter("blocked/#never-joined"), "reader");
		const stderr = proc.stderr.getReader();
		let diagnostic = "";
		try {
			while (!diagnostic.includes("IRC tests may dial only an explicit loopback endpoint")) {
				const next = await within(stderr.read(), "loopback-only process diagnostic");
				assert(!next.done, `guarded bridge ended without rejecting the endpoint: ${diagnostic}`);
				diagnostic += new TextDecoder().decode(next.value);
			}
		} finally {
			stderr.releaseLock();
		}
	} finally {
		await room?.leave();
		await directory?.close();
		await stopOwned(proc);
	}
	assert((await proc.status).success, "guarded bridge did not stop cleanly");
});
