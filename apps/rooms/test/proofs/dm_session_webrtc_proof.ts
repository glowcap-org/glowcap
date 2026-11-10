import { spawnWeb, webAnnouncements, webPort } from "../support/web_front.ts";
// The Rooms session process and browser members direct-message each other over
// WebRTC DataChannels, with the room directory carrying only the signaling. The
// process opens the first conversation and a second member opens the other.
//
// The member the process dials joins on the page's default route, Fastest,
// and files a signaling inbox with the room directory. The session process
// joins the same room with `--dial-transports=tcp,webrtc` and no relay URL,
// so of the routes that member lists, WebRTC is the one it has a provider
// for, and that dial is what reaches the member: the Host redeems
// the room's introduction, the C WebRTC provider asks the process for
// signaling, and the process carries the offer, answer and candidates through
// the directory that introduced the member. The member replies over the
// arriving connection.
//
// The process also listens for WebRTC: it registers its webrtc locator first,
// with its TCP one as the fallback, and files an answering inbox with the
// room. A second member, one who chose the Rooms server, opens a conversation
// with it. That member registered a relay locator, whose designator is its
// Host key, so the room names its offer by that key and the process answers
// it. Each conversation must open a webrtc session the live trace had not
// seen, and no keyed-relay session may stand in for either.
//
// Needs deno, the wasm module (`zig build wasm-host`), the installed Rooms
// executables, and a Playwright Chromium (the devcontainer image ships one).
// Run: `zig build rooms-web-dm-session-webrtc`.

import { type Browser, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned } from "../support/children.ts";
import { acquireTraceCapability, connectTraceViewer } from "../trace/viewer.ts";
import { roomPortOf, sturdyrefPort } from "../support/rooms_server.ts";
import { until } from "../support/wait.ts";
import { fail } from "../support/fail.ts";
import { awaitBubble, openDmTo } from "../page/harness.ts";
import { startSessionPeer } from "../support/session_peer.ts";
import { readAnnounced } from "../support/announce.ts";
import { ROOT, SESSION } from "../support/paths.ts";

const ROOM = "lobby";
const PROCESS = "durable-member";
const MEMBER = "web-bob";
const OPENER = "web-carol";
const DM_TEXT = "hello from the session process, over a DataChannel the room only signaled";
const REPLY_TEXT = "got it, replying over the same channel";
const OPENING_TEXT = "hello session process, I offered and you answered";
const ANSWER_TEXT = "answered over the channel you opened";

const deadline = setTimeout(() => fail("dm-session-webrtc scenario timed out after 120s"), 120_000);
const state = await Deno.makeTempDir({ prefix: "glowcap-session-webrtc-dm-" });

// Join `ROOM` as `nick` in a fresh tab, in the `dm` connection mode (the page's
// default when null), and wait
// until the composer is live: the keyed session to the room is up and the tab
// is advertising its identity.
async function joinAs(browser: Browser, nick: string, trace: string, dm: "relay" | null): Promise<Page> {
	const tab = await (await browser.newContext()).newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	tab.on("console", (m) => {
		if (m.type() === "error" || m.type() === "warning") console.error(`  [${nick} console.${m.type()}]`, m.text());
	});
	await tab.goto(`http://127.0.0.1:${httpPort}/${dm == null ? "" : `?dm=${dm}`}`);
	await establishLocalSession(tab);
	await acquireTraceCapability(tab, trace);
	await tab.fill("#nick", nick);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return tab;
}

// One typed operation on the session process through its local control socket.
async function control(verb: string, named: Record<string, string[]>) {
	const output = await new Deno.Command(SESSION, {
		args: ["control", JSON.stringify({ verb, state, named, arguments: [] })],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).output();
	if (!output.success) fail(`process ${verb} refused: ${new TextDecoder().decode(output.stderr)}`);
	return JSON.parse(new TextDecoder().decode(output.stdout));
}

// The process's pending events, until a direct message carrying `text` is among them.
async function receivedDirect(text: string): Promise<void> {
	await until(
		async () => {
			const batch = await control("tick", { wait: ["0"] });
			const pending: Array<{ event: { target: { kind: string }; notice: { text?: string } } }> = batch.pending ??
				[];
			return pending.some((p) => p.event?.target?.kind === "direct" && p.event?.notice?.text === text);
		},
		`the session process to receive "${text}"`,
		20_000,
	);
}

// Delivery alone is not transport evidence. The live timeline must observe a
// webrtc session beyond the `seen` it had observed before.
async function openedWebrtc(sessions: Set<string>, seen: number, what: string): Promise<void> {
	await until(() => sessions.size > seen, `a new webrtc session on the live timeline after ${what} arrived`, 5_000);
}

// serve.ts serves the page and runs the room over plain TCP. The DM channel is
// WebRTC. The browser may reach the process's TCP listener through the web
// forward, so the process's own dial is the only path that must be WebRTC.
const peer = startSessionPeer(state, [
	"--transport=tcp",
	"--port=0",
	"--dial-transports=tcp,webrtc",
	"--ice-servers=",
	"--local-control",
]);
// The front's relay may dial only the addresses it is told, and this process's
// listener is one of them, so the process starts first and its port is read.
const sessionPort = sturdyrefPort(
	await readAnnounced(peer, { token: "ROOMS-SESSION-LISTENING", who: "session process" }),
);
const web = spawnWeb({
	args: ["--transport=tcp", "0", "0"],
	cwd: ROOT,
	env: {
		GLOWCAP_ROOMS_CAPABILITIES: "trace",
		GLOWCAP_ROOMS_TRACE_PORT: "0",
		GLOWCAP_RELAY_TCP_PEERS: `127.0.0.1:${sessionPort}`,
	},
	stdout: "piped",
	stderr: "piped",
});
const traceRef = webAnnouncements(web).line("ROOMS-TRACE-LISTENING", "rooms-web");
const httpPort = await webPort(web);

let browser: Browser | null = null;
let viewer: { close(): Promise<void> } | null = null;
try {
	const roomPort = await roomPortOf(httpPort);
	const sturdyref = await traceRef;
	const webrtcSessions = new Set<string>();
	let sawRelay = false;
	viewer = await connectTraceViewer(sturdyref, (record) => {
		if (record.kind !== "ocapn.session-opened") return;
		if (record.transport === "webrtc") webrtcSessions.add(String(record.session_id ?? ""));
		if (record.transport === "keyed-relay") sawRelay = true;
	});

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const bob = await joinAs(browser, MEMBER, sturdyref, null);

	// The process has no relay and gathers only host candidates, so the dial
	// stays on this machine.
	await control("join", { locator: [`127.0.0.1:${roomPort}`], nick: [PROCESS], room: [ROOM] });
	await bob.waitForSelector(`#members li:has-text("${PROCESS}")`, { timeout: 30_000 }).catch(() =>
		fail(`${MEMBER} never saw ${PROCESS} in the room`)
	);

	// The process direct-messages the member: the room introduces the member,
	// the Host dials its webrtc locator, and the signaling rides the room.
	const sent = await control("reply", { dm: [MEMBER], text: [DM_TEXT] });
	if (sent.status !== "committed") fail(`the direct message was not committed: ${JSON.stringify(sent)}`);
	await openDmTo(bob, PROCESS);
	await awaitBubble(bob, DM_TEXT, "Bob");

	// The member replies over the connection the message arrived on.
	await bob.fill("#line", REPLY_TEXT);
	await bob.press("#line", "Enter");
	await receivedDirect(REPLY_TEXT);

	await openedWebrtc(webrtcSessions, 0, "the process's messages");

	// A member who chose the relay opens the conversation. Its offer reaches
	// the process's answering inbox through the room, named by the Host key
	// its relay locator carries, and the process answers.
	const seen = webrtcSessions.size;
	const carol = await joinAs(browser, OPENER, sturdyref, "relay");
	await openDmTo(carol, PROCESS);
	await carol.fill("#line", OPENING_TEXT);
	await carol.press("#line", "Enter");
	await receivedDirect(OPENING_TEXT);
	const answered = await control("reply", { dm: [OPENER], text: [ANSWER_TEXT] });
	if (answered.status !== "committed") fail(`the answer was not committed: ${JSON.stringify(answered)}`);
	await awaitBubble(carol, ANSWER_TEXT, "Carol");
	await openedWebrtc(webrtcSessions, seen, "the member's messages");
	if (sawRelay) fail("a keyed-relay session stood in for WebRTC");

	console.log(
		"PASS: the session process direct-messaged a browser member over a WebRTC DataChannel the " +
			"introducing room signaled, and answered a relay member's WebRTC offer that rode the room " +
			"to its answering inbox, with every reply over the arriving connection",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	if (viewer) await viewer.close().catch(() => {});
	await reapOwned();
	await Deno.remove(state, { recursive: true }).catch(() => {});
}
Deno.exit(0);
