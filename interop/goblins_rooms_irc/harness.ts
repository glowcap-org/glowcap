// Outside-authority proof for both IRC product fronts. One phase puts a real
// Goblins vat inside the shipped IRC-to-Rooms bridge; the other drives the
// shipped Rooms-to-IRC front and proves channel plus introduced DM traffic with
// a real Goblins vat. No browser and no substitute glowcap peer stands in for
// Goblins here.

import { runChild } from "../../apps/_demo/orchestrator.ts";
import { encodeIrc, type IrcMessage, readIrcLines } from "../../apps/rooms/irc/protocol.ts";

const ROOT = Deno.cwd();
const PHASE = Deno.args.find((arg) => arg.startsWith("--phase="))?.slice("--phase=".length);
const WAIT_MS = 60_000;

function fail(message: string): never {
	throw new Error(message);
}

function assert(value: unknown, message: string): asserts value {
	if (!value) fail(message);
}

async function writeAll(conn: Deno.Conn, bytes: Uint8Array): Promise<void> {
	let offset = 0;
	while (offset < bytes.length) {
		const wrote = await conn.write(bytes.subarray(offset));
		if (wrote === 0) fail("socket accepted a zero-byte write");
		offset += wrote;
	}
}

async function nextMatching(
	lines: AsyncIterator<IrcMessage>,
	match: (message: IrcMessage) => boolean,
	what: string,
): Promise<IrcMessage> {
	const deadline = Date.now() + WAIT_MS;
	while (Date.now() < deadline) {
		const remaining = deadline - Date.now();
		let timer: ReturnType<typeof setTimeout> | undefined;
		const timeout = new Promise<never>((_, reject) => {
			timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), remaining);
		});
		let next: IteratorResult<IrcMessage>;
		try {
			next = await Promise.race([lines.next(), timeout]);
		} finally {
			clearTimeout(timer);
		}
		if (next.done) fail(`IRC socket ended while waiting for ${what}`);
		if (match(next.value)) return next.value;
	}
	fail(`timed out waiting for ${what}`);
}

class LiveChild {
	readonly child: Deno.ChildProcess;
	readonly #status: Promise<Deno.CommandStatus>;
	readonly #stdin: WritableStreamDefaultWriter<Uint8Array> | null;
	#out = "";
	#err = "";
	readonly #drains: Promise<void>[];

	constructor(command: string, args: string[], options: { env?: Record<string, string>; stdin?: boolean } = {}) {
		this.child = new Deno.Command(command, {
			args,
			cwd: ROOT,
			env: options.env,
			stdin: options.stdin ? "piped" : "null",
			stdout: "piped",
			stderr: "piped",
		}).spawn();
		this.#status = this.child.status;
		this.#stdin = options.stdin ? this.child.stdin.getWriter() : null;
		this.#drains = [
			this.#drain(this.child.stdout, (text) => this.#out += text),
			this.#drain(this.child.stderr, (text) => this.#err += text),
		];
	}

	async #drain(stream: ReadableStream<Uint8Array>, append: (text: string) => void): Promise<void> {
		const reader = stream.getReader();
		const decoder = new TextDecoder();
		try {
			while (true) {
				const { value, done } = await reader.read();
				if (done) break;
				append(decoder.decode(value, { stream: true }));
			}
			append(decoder.decode());
		} finally {
			reader.releaseLock();
		}
	}

	async waitFor(pattern: RegExp, what: string, timeoutMs = WAIT_MS): Promise<RegExpMatchArray> {
		const deadline = Date.now() + timeoutMs;
		while (Date.now() < deadline) {
			const match = this.#out.match(pattern);
			if (match !== null) return match;
			const status = await Promise.race([
				this.#status.then((value) => ({ done: true, value })),
				new Promise<{ done: false }>((resolve) => setTimeout(() => resolve({ done: false }), 25)),
			]);
			if (status.done) fail(`${what}: child exited ${status.value.code}\n${this.log()}`);
		}
		fail(`timed out waiting for ${what}\n${this.log()}`);
	}

	async line(text: string): Promise<void> {
		if (this.#stdin === null) fail("child has no stdin");
		await this.#stdin.write(new TextEncoder().encode(`${text}\n`));
	}

	log(): string {
		return `stdout:\n${this.#out}\nstderr:\n${this.#err}`;
	}

	async stop(): Promise<void> {
		try {
			await this.#stdin?.close();
		} catch { /* child already closed */ }
		try {
			this.child.kill("SIGTERM");
		} catch { /* child already closed */ }
		const stopped = await Promise.race([
			this.#status.then(() => true),
			new Promise<false>((resolve) => setTimeout(() => resolve(false), 500)),
		]);
		if (!stopped) {
			try {
				this.child.kill("SIGKILL");
			} catch { /* child stopped after the race */ }
		}
		await this.#status;
		await Promise.allSettled(this.#drains);
	}
}

async function bridgePhase(): Promise<void> {
	const cert = await Deno.readTextFile(`${ROOT}/test/net/fixtures/tls_server.pem`);
	const key = await Deno.readTextFile(`${ROOT}/test/net/fixtures/tls_server.key`);
	const listener = Deno.listenTls({ hostname: "127.0.0.1", port: 0, cert, key });
	let inboundSent = false;
	let outbound = "";
	const fixture = (async () => {
		const conn = await listener.accept();
		listener.close();
		try {
			const lines = readIrcLines(conn.readable)[Symbol.asyncIterator]();
			await nextMatching(lines, (line) => line.command === "CAP", "bridge CAP LS");
			await nextMatching(lines, (line) => line.command === "NICK", "bridge NICK");
			const user = await nextMatching(lines, (line) => line.command === "USER", "bridge USER");
			assert(
				user.params[3] === "glowcap bridge bot; admin: fixture-admin",
				`bridge sent the wrong public identity: ${JSON.stringify(user.params)}`,
			);
			await writeAll(conn, new TextEncoder().encode(":fixture CAP bridgebot LS :sasl=PLAIN\r\n"));
			await nextMatching(lines, (line) => line.command === "CAP" && line.params[0] === "REQ", "bridge CAP REQ");
			await writeAll(conn, new TextEncoder().encode(":fixture CAP bridgebot ACK :sasl\r\n"));
			await nextMatching(
				lines,
				(line) => line.command === "AUTHENTICATE" && line.params[0] === "PLAIN",
				"SASL PLAIN",
			);
			await writeAll(conn, encodeIrc("AUTHENTICATE", ["+"]));
			await nextMatching(lines, (line) => line.command === "AUTHENTICATE", "SASL credentials");
			await writeAll(conn, new TextEncoder().encode(":fixture 903 bridgebot :SASL ok\r\n"));
			await nextMatching(lines, (line) => line.command === "CAP" && line.params[0] === "END", "CAP END");
			await writeAll(conn, new TextEncoder().encode(":fixture 005 bridgebot BOT=b :supported\r\n"));
			await nextMatching(
				lines,
				(line) => line.command === "MODE" && line.params[0] === "bridgebot" && line.params[1] === "+b",
				"advertised bot mode",
			);
			await writeAll(conn, new TextEncoder().encode(":fixture 001 bridgebot :welcome\r\n"));
			await nextMatching(lines, (line) => line.command === "JOIN", "bridge JOIN");
			await writeAll(conn, new TextEncoder().encode(":bridgebot!u@fixture JOIN :#ocapn\r\n"));
			const post = await nextMatching(
				lines,
				(line) => line.command === "PRIVMSG" && line.params[0] === "#ocapn",
				"Goblins line reaching IRC",
			);
			outbound = post.params[1] ?? "";
			await writeAll(
				conn,
				new TextEncoder().encode(":alice!u@fixture PRIVMSG #ocapn :hello Goblins from IRC\r\n"),
			);
			inboundSent = true;
		} finally {
			conn.close();
		}
	})();
	// The Goblins process starts before the fixture is awaited. Attach the
	// observer now so an early socket failure remains scenario evidence instead
	// of becoming an unhandled-rejection process abort.
	void fixture.catch(() => {});

	const bridge = new LiveChild(
		Deno.env.get("GLOWCAP_ROOMS_IRC_BRIDGE_BIN") || `${ROOT}/zig-out/bin/rooms-irc-bridge`,
		[
			"--network=fixture",
			"--channel=#ocapn",
			"--irc-host=localhost",
			`--irc-port=${(listener.addr as Deno.NetAddr).port}`,
			"--irc-nick=bridgebot",
			"--irc-realname=glowcap bridge bot; admin: fixture-admin",
			"--mode=two-way",
			"--sasl-account=bridge-account",
			"--tls=true",
		],
		{
			env: {
				GLOWCAP_ROOMS_IRC_SASL_PASSWORD: "bridge-password",
				SSL_CERT_FILE: `${ROOT}/test/net/fixtures/tls_root.pem`,
			},
		},
	);
	try {
		const announced = await bridge.waitFor(
			/ROOMS-IRC-BRIDGE-LISTENING (\d+) (\S+)/,
			"IRC bridge announcement",
		);
		const goblins = await runChild("racket", [
			"-y",
			`${ROOT}/conformance/goblins-peer/racket/rooms-member.rkt`,
			`127.0.0.1:${announced[1]}`,
			announced[2],
			"goblins-carol",
			"hello IRC from Goblins",
			"irc/alice",
		], ROOT);
		try {
			await fixture;
		} catch (error) {
			fail(`fixture IRC failed: ${error}\n${bridge.log()}`);
		}
		assert(goblins.code === 0 && goblins.out.includes("ROOMS OK"), `Goblins bridge member failed\n${goblins.out}`);
		assert(
			goblins.out.includes("hello Goblins from IRC"),
			`Goblins never received fixture IRC traffic\n${goblins.out}`,
		);
		assert(inboundSent, "fixture never sent its IRC line");
		assert(outbound === "<goblins-carol> hello IRC from Goblins", `unexpected IRC outbound line: ${outbound}`);
		console.log(
			"PASS (goblins-rooms-irc-bridge): real Goblins and fixture IRC exchanged a room line both ways through the shipped bridge",
		);
	} finally {
		try {
			listener.close();
		} catch { /* accepted or already closed */ }
		await bridge.stop();
	}
}

async function frontPhase(): Promise<void> {
	const room = new LiveChild(Deno.env.get("GLOWCAP_ROOMS_SERVER_BIN") || `${ROOT}/zig-out/bin/rooms-server`, [
		"--transport=tcp",
		"--port=0",
	]);
	let goblins: LiveChild | null = null;
	let front: LiveChild | null = null;
	let irc: Deno.Conn | null = null;
	try {
		const token = (await room.waitFor(/ROOMS-SERVER-LISTENING (\S+)/, "Rooms server announcement"))[1];
		const locator = /^\d+$/.test(token) ? `127.0.0.1:${token}` : token;
		goblins = new LiveChild("racket", [
			"-y",
			`${ROOT}/conformance/goblins-peer/racket/rooms-chat.rkt`,
			locator,
			"irc-front-live",
			"goblins-carol",
			"0",
		], { stdin: true });
		await goblins.waitFor(/\* you are in irc-front-live/, "Goblins room join");
		await goblins.waitFor(/\* the room granted you the name goblins-carol/, "Goblins DM registration");

		front = new LiveChild(Deno.env.get("GLOWCAP_ROOMS_IRC_FRONT_BIN") || `${ROOT}/zig-out/bin/rooms-irc-front`, [
			`--directory=${locator}`,
			"--port=0",
			"--dm-transport=tcp",
		]);
		const frontPort = Number(
			(await front.waitFor(/ROOMS-IRC-FRONT-LISTENING (\d+) /, "IRC front announcement"))[1],
		);
		irc = await Deno.connect({ hostname: "127.0.0.1", port: frontPort });
		const lines = readIrcLines(irc.readable)[Symbol.asyncIterator]();
		await writeAll(irc, encodeIrc("NICK", ["irc-alice"]));
		await writeAll(irc, encodeIrc("USER", ["alice", "0", "*", "Alice over IRC"]));
		await nextMatching(lines, (line) => line.command === "001", "IRC welcome");
		await writeAll(irc, encodeIrc("JOIN", ["#irc-front-live"]));
		await nextMatching(lines, (line) => line.command === "JOIN", "IRC room join");
		await nextMatching(
			lines,
			(line) => line.command === "353" && line.params.at(-1)?.includes("goblins-carol") === true,
			"Goblins in IRC NAMES",
		);

		await writeAll(irc, encodeIrc("PRIVMSG", ["#irc-front-live", "hello Goblins from IRC front"]));
		await goblins.waitFor(/<irc-alice> hello Goblins from IRC front/, "IRC channel line at Goblins");
		await goblins.line("hello IRC from a real Goblins vat");
		await nextMatching(
			lines,
			(line) =>
				line.command === "PRIVMSG" && line.params[0] === "#irc-front-live" &&
				line.params[1] === "hello IRC from a real Goblins vat",
			"Goblins channel line at IRC",
		);

		await writeAll(irc, encodeIrc("PRIVMSG", ["goblins-carol", "private hello from IRC"]));
		await goblins.waitFor(/\(dm\) <irc-alice> private hello from IRC/, "IRC-initiated Goblins DM");
		await goblins.line("/dm irc-alice private reply from Goblins");
		await nextMatching(
			lines,
			(line) =>
				line.command === "PRIVMSG" && line.params[0] === "irc-alice" &&
				line.params[1] === "private reply from Goblins",
			"Goblins reply on the arriving DM session",
		);
		console.log(
			"PASS (goblins-rooms-irc-front): IRC and real Goblins exchanged channel traffic, then Goblins replied on the IRC-initiated direct session over v1/Syrup TCP",
		);
	} finally {
		try {
			irc?.close();
		} catch { /* already closed */ }
		await front?.stop();
		await goblins?.stop();
		await room.stop();
	}
}

try {
	if (PHASE === "bridge") await bridgePhase();
	else if (PHASE === "front") await frontPhase();
	else fail("usage: harness.ts --phase=bridge|front");
} catch (error) {
	console.error(
		`FAIL (goblins-rooms-irc-${PHASE ?? "unknown"}): ${error instanceof Error ? error.message : String(error)}`,
	);
	Deno.exit(1);
}
