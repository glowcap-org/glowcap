import { joinRoom } from "./enter_room.ts";

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
				(message) =>
					message.nameTaken !== undefined &&
					/name "browser-ada" is already claimed/.test(message.nameTaken),
			);
		} finally {
			first.ws.close();
			second.ws.close();
		}
	});
});
