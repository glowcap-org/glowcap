import { joinRoom } from "./lib/enter_room.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const WEB = new URL("./web.ts", import.meta.url).pathname;
const DENO_FLAGS = [
	"run",
	"--allow-ffi",
	"--allow-read",
	"--allow-net",
	"--allow-run",
];

type BrowserMessage = {
	from?: string;
	text?: string;
	rooms?: Array<[string, number]>;
	joined?: string;
	nameTaken?: string;
	notice?: string;
	presence?: { kind: string; name?: string; names?: string[] } | null;
	dmable?: string[];
	dmSelf?: { nick: string; transport: string };
	dmReady?: { peer: string; transport: string };
	dmFrom?: { peer: string; text: string };
	dmFailed?: { peer: string; offline: boolean; text?: string };
};

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}

async function waitForHttp(port: number): Promise<string> {
	const deadline = Date.now() + 10_000;
	let lastError: unknown;
	while (Date.now() < deadline) {
		try {
			return await fetch(`http://127.0.0.1:${port}/`).then((response) => response.text());
		} catch (err) {
			lastError = err;
			await delay(50);
		}
	}
	throw new Error(`rooms web UI did not start: ${lastError}`);
}

async function withWeb(
	fn: (httpPort: number, roomPort: number) => Promise<void>,
): Promise<void> {
	const httpPort = freePort();
	const roomPort = freePort();
	const proc = new Deno.Command("deno", {
		args: [...DENO_FLAGS, WEB, String(httpPort), String(roomPort)],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).spawn();
	try {
		await fn(httpPort, roomPort);
	} finally {
		try {
			proc.kill("SIGINT");
		} catch {
			// Already gone.
		}
		await proc.status;
	}
}

// Open a tab's socket and ask to join `room` as `nick` — the page's join over
// the wire (no query params; the connection streams the room list first, then
// the browser sends a `join`).
function openSocket(port: number, room: string, nick: string): Promise<{
	ws: WebSocket;
	messages: BrowserMessage[];
}> {
	const messages: BrowserMessage[] = [];
	const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
	return new Promise((resolve, reject) => {
		ws.onopen = () => {
			ws.send(JSON.stringify({ join: { room, nick } }));
			resolve({ ws, messages });
		};
		ws.onerror = () => reject(new Error("browser WebSocket failed to open"));
		ws.onmessage = (event) => messages.push(JSON.parse(String(event.data)));
	});
}

async function waitForPresence(
	messages: BrowserMessage[],
	match: (message: BrowserMessage) => boolean,
): Promise<BrowserMessage> {
	const deadline = Date.now() + 2_000;
	while (Date.now() < deadline) {
		const found = messages.find(match);
		if (found) return found;
		await delay(25);
	}
	throw new Error(`expected presence message in ${JSON.stringify(messages)}`);
}

async function waitForMessage(
	messages: BrowserMessage[],
	match: (message: BrowserMessage) => boolean,
): Promise<BrowserMessage> {
	const deadline = Date.now() + 2_000;
	while (Date.now() < deadline) {
		const found = messages.find(match);
		if (found) return found;
		await delay(25);
	}
	throw new Error(`expected browser message in ${JSON.stringify(messages)}`);
}

// Wait for a message that arrives at or after `from` in the log, so a test can
// look for a *new* snapshot (a fresh `dmable` set, say) without matching an
// identical one that was already there before the event it is waiting on.
async function waitForMessageFrom(
	messages: BrowserMessage[],
	from: number,
	match: (message: BrowserMessage) => boolean,
): Promise<BrowserMessage> {
	const deadline = Date.now() + 3_000;
	while (Date.now() < deadline) {
		const found = messages.slice(from).find(match);
		if (found) return found;
		await delay(25);
	}
	throw new Error(`expected later browser message in ${JSON.stringify(messages.slice(from))}`);
}

Deno.test("rooms web bridge sends browser presence for all room members", async () => {
	await withWeb(async (httpPort, roomPort) => {
		const page = await waitForHttp(httpPort);
		assert(
			page.includes('id="presenceSummary"'),
			"page should include the presence summary",
		);
		assert(
			page.includes('id="members"'),
			"page should include the presence list",
		);
		assert(
			page.includes('id="nickError"'),
			"page should include a username error region",
		);
		assert(
			page.includes('id="roomList"'),
			"page should include the live room list",
		);

		const { ws, messages } = await openSocket(
			httpPort,
			"general",
			"browser-ada",
		);
		try {
			// The tab is confirmed in its room, and the live room list arrives.
			await waitForMessage(messages, (message) => message.joined === "general");
			await waitForMessage(messages, (message) => Array.isArray(message.rooms));
			await waitForPresence(
				messages,
				(message) =>
					message.presence?.kind === "roster" &&
					message.presence.names?.includes("browser-ada") === true,
			);

			// The CLI joins the same room over the wire; the browser sees it arrive.
			const { dir, room: cli } = await joinRoom(
				`127.0.0.1:${roomPort}`,
				"general",
				"cli-grace",
			);
			await waitForPresence(
				messages,
				(message) =>
					message.presence?.kind === "join" &&
					message.presence.name === "cli-grace",
			);

			await cli.leave();
			await dir.close();
			await waitForPresence(
				messages,
				(message) =>
					message.presence?.kind === "leave" &&
					message.presence.name === "cli-grace",
			);
		} finally {
			ws.close();
		}
	});
});

Deno.test("rooms web bridge introduces two tabs for a direct message", async () => {
	await withWeb(async (httpPort) => {
		await waitForHttp(httpPort);
		const alice = await openSocket(httpPort, "lobby", "alice");
		const bob = await openSocket(httpPort, "lobby", "bob");
		try {
			await waitForMessage(alice.messages, (m) => m.joined === "lobby");
			await waitForMessage(bob.messages, (m) => m.joined === "lobby");

			// Alice can DM bob only once his member registration has completed, which
			// the bridge surfaces by adding him to her DM-able set. Waiting on that is
			// the same readiness the UI waits on before it offers to DM someone.
			await waitForMessage(
				alice.messages,
				(m) => Array.isArray(m.dmable) && m.dmable.includes("bob"),
			);

			// Alice asks to DM bob. The bridge introduces her, redeems the give onto a
			// direct connection to bob, and delivers the line there — bob's tab sees it
			// arrive from alice without the room ever carrying it.
			alice.ws.send(JSON.stringify({ dmSay: { to: "bob", text: "hi bob, privately" } }));
			await waitForMessage(
				bob.messages,
				(m) => m.dmFrom?.peer === "alice" && m.dmFrom?.text === "hi bob, privately",
			);
			// Alice's own tab is told the direct line is live.
			await waitForMessage(alice.messages, (m) => m.dmReady?.peer === "bob");

			// The introduction is a capability, so it outlives the room that arranged
			// it. Bob leaves for another room; alice's direct line to him still works.
			bob.ws.send(JSON.stringify({ join: { room: "elsewhere", nick: "bob" } }));
			await waitForMessage(bob.messages, (m) => m.joined === "elsewhere");
			alice.ws.send(JSON.stringify({ dmSay: { to: "bob", text: "still reachable" } }));
			await waitForMessage(
				bob.messages,
				(m) => m.dmFrom?.peer === "alice" && m.dmFrom?.text === "still reachable",
			);
		} finally {
			alice.ws.close();
			bob.ws.close();
		}
	});
});

Deno.test("rooms web bridge re-introduces a direct line after the peer rejoins under the same nick", async () => {
	await withWeb(async (httpPort) => {
		await waitForHttp(httpPort);
		const alice = await openSocket(httpPort, "lobby", "alice");
		let bob = await openSocket(httpPort, "lobby", "bob");
		try {
			await waitForMessage(alice.messages, (m) => m.joined === "lobby");
			await waitForMessage(bob.messages, (m) => m.joined === "lobby");
			await waitForMessage(
				alice.messages,
				(m) => Array.isArray(m.dmable) && m.dmable.includes("bob"),
			);

			// Alice opens a direct line to bob while his first endpoint is live.
			alice.ws.send(JSON.stringify({ dmSay: { to: "bob", text: "first hello" } }));
			await waitForMessage(
				bob.messages,
				(m) => m.dmFrom?.peer === "alice" && m.dmFrom?.text === "first hello",
			);

			// Bob leaves the app entirely: his tab closes, unregistering his member
			// endpoint. Alice never leaves and still holds the line she opened — a line
			// that names bob's now-dead endpoint. Wait for her to see him drop out of
			// the DM-able set, which is also when the bridge forgets that stale line.
			const beforeClose = alice.messages.length;
			bob.ws.close();
			await waitForMessageFrom(
				alice.messages,
				beforeClose,
				(m) => Array.isArray(m.dmable) && !m.dmable.includes("bob"),
			);

			// Bob rejoins under the same nick. He is a brand-new member at a brand-new
			// endpoint, so the directory introduces alice to *that* endpoint from now on.
			const beforeRejoin = alice.messages.length;
			bob = await openSocket(httpPort, "lobby2", "bob");
			await waitForMessage(bob.messages, (m) => m.joined === "lobby2");
			await waitForMessageFrom(
				alice.messages,
				beforeRejoin,
				(m) => Array.isArray(m.dmable) && m.dmable.includes("bob"),
			);

			// Alice sends again on the same conversation. Reusing the cached line would
			// deliver into bob's dead endpoint and vanish; because the bridge dropped
			// that line when bob unregistered, this re-introduces and reaches his new
			// endpoint. This is the regression: without the drop, bob never sees it.
			alice.ws.send(JSON.stringify({ dmSay: { to: "bob", text: "after rejoin" } }));
			await waitForMessage(
				bob.messages,
				(m) => m.dmFrom?.peer === "alice" && m.dmFrom?.text === "after rejoin",
			);
		} finally {
			alice.ws.close();
			bob.ws.close();
		}
	});
});

Deno.test("rooms web bridge routes two concurrent introductions each to its own member (ADR-0069)", async () => {
	await withWeb(async (httpPort) => {
		await waitForHttp(httpPort);
		// Two members in one room DM each other at the same time. The room fetches a
		// `dm` inbox from both, and those two imports share a wire position (CapTP
		// numbers imports per connection). Before ADR-0069 the node keyed a fetched
		// capability by that position alone, so the second fetch clobbered the first
		// and both introductions resolved to the last-registered member — carol's
		// line to dave and dave's line to carol both landed on the same tab. Holding
		// each import under a node-unique token keeps them distinct.
		const carol = await openSocket(httpPort, "lobby", "carol");
		const dave = await openSocket(httpPort, "lobby", "dave");
		try {
			await waitForMessage(carol.messages, (m) => m.joined === "lobby");
			await waitForMessage(dave.messages, (m) => m.joined === "lobby");
			await waitForMessage(
				carol.messages,
				(m) => Array.isArray(m.dmable) && m.dmable.includes("dave"),
			);
			await waitForMessage(
				dave.messages,
				(m) => Array.isArray(m.dmable) && m.dmable.includes("carol"),
			);

			// Both introductions happen: carol messages dave, dave messages carol.
			carol.ws.send(JSON.stringify({ dmSay: { to: "dave", text: "for dave only" } }));
			dave.ws.send(JSON.stringify({ dmSay: { to: "carol", text: "for carol only" } }));

			// Each line reaches the member it was addressed to.
			await waitForMessage(
				dave.messages,
				(m) => m.dmFrom?.peer === "carol" && m.dmFrom?.text === "for dave only",
			);
			await waitForMessage(
				carol.messages,
				(m) => m.dmFrom?.peer === "dave" && m.dmFrom?.text === "for carol only",
			);

			// And neither line is mis-routed back to its own sender, the collision's
			// symptom where both introductions landed on one member.
			await delay(300);
			assert(
				!carol.messages.some((m) => m.dmFrom?.text === "for dave only"),
				"carol received the line addressed to dave",
			);
			assert(
				!dave.messages.some((m) => m.dmFrom?.text === "for carol only"),
				"dave received the line addressed to carol",
			);
		} finally {
			carol.ws.close();
			dave.ws.close();
		}
	});
});

Deno.test("rooms web bridge reports a direct message to an unreachable member", async () => {
	await withWeb(async (httpPort) => {
		await waitForHttp(httpPort);
		const alice = await openSocket(httpPort, "lobby", "alice");
		try {
			await waitForMessage(alice.messages, (m) => m.joined === "lobby");
			// No member named "nobody" ever registered, so the introduction is refused
			// and the bridge tells the tab why rather than failing silently.
			alice.ws.send(JSON.stringify({ dmSay: { to: "nobody", text: "anyone there?" } }));
			await waitForMessage(
				alice.messages,
				(m) => m.dmFailed?.peer === "nobody" && m.dmFailed?.offline === true,
			);
		} finally {
			alice.ws.close();
		}
	});
});

Deno.test("rooms web bridge rejects a duplicate browser nickname", async () => {
	await withWeb(async (httpPort) => {
		await waitForHttp(httpPort);
		// Let the first tab win the name before the second tries it, so the rejection
		// is the duplicate's, not a race.
		const first = await openSocket(httpPort, "general", "Browser-Ada");
		await waitForPresence(
			first.messages,
			(message) =>
				message.presence?.kind === "roster" &&
				message.presence.names?.includes("Browser-Ada") === true,
		);
		const second = await openSocket(httpPort, "general", "browser-ada");
		try {
			await waitForMessage(
				second.messages,
				// A nameTaken naming the duplicate nick — not the wording of the message.
				(message) =>
					message.nameTaken !== undefined &&
					message.nameTaken.includes("browser-ada"),
			);
		} finally {
			first.ws.close();
			second.ws.close();
		}
	});
});

Deno.test("rooms web UI attaches to a room server already on its port", async () => {
	// Sharing a room port used to be fatal: the second instance's child could not
	// bind and the process failed to start. Now the second attaches to the first.
	const roomPort = freePort();
	const httpFirst = freePort();
	const httpSecond = freePort();
	const spawnWeb = (httpPort: number) =>
		new Deno.Command("deno", {
			args: [...DENO_FLAGS, WEB, String(httpPort), String(roomPort)],
			cwd: ROOT,
			stdout: "piped",
			stderr: "piped",
		}).spawn();

	const first = spawnWeb(httpFirst);
	let second: Deno.ChildProcess | null = null;
	try {
		await waitForHttp(httpFirst); // the first now owns roomPort
		second = spawnWeb(httpSecond);
		// The second must serve rather than crash on AddrInUse.
		const page = await waitForHttp(httpSecond);
		assert(page.includes("pancake rooms"), "the attached instance should serve the page");
		// A tab through the second instance reaches the shared room server.
		const { ws, messages } = await openSocket(httpSecond, "general", "attached-user");
		try {
			await waitForMessage(messages, (m) => m.joined === "general");
		} finally {
			ws.close();
		}
	} finally {
		for (const proc of [second, first]) {
			if (!proc) continue;
			try {
				proc.kill("SIGINT");
			} catch {
				// Already gone.
			}
			await proc.status;
		}
	}
});
