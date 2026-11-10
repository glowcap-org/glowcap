import { spawnWeb, webAnnouncements, webPort } from "../support/web_front.ts";
// A browser member on the default direct-message route, **Fastest**, on a
// page with a Rooms server, is reached by a dialing Host that races WebRTC and
// the server's sealed relay (ADR-0036) and keeps the first to prove the key,
// so a network that blocks WebRTC costs nothing: the relay wins while the
// direct attempt is still looking, with no bound to wait out.
//
// Two scenes. In the first, Chromium runs with every non-proxied UDP route
// disabled, so ICE gathers no candidates. The two tabs join with no `?dm` at
// all, Settings opens on Fastest, Alice opens a line to Bob, and the proof
// reads the live timeline: the line that carries the message is a
// noise-relay session, no webrtc session opened, and the open took at most a
// relay dial. Both cards' Path fact names the server. Once the signaling
// exchange budget has passed, neither tab's **Browser trouble** holds a
// signaling failure: Alice's direct attempt lost the race and was cancelled,
// and Bob's answering side waited out its budget and ended quietly.
//
// In the second, UDP is allowed, so ICE finds a loopback route and the race
// is real. Whichever route wins, both cards name it, the message goes both
// ways, and once the exchange budget has passed no session of the losing
// transport stands open and neither tab holds a signaling failure.
//
// Needs deno, the wasm module (`zig build wasm-host`), the installed archives
// (serve.ts's room server is the Rust process), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `zig build rooms-web-dm-fastest`.

import { type Browser, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned } from "../support/children.ts";
import { acquireTraceCapability, connectTraceViewer } from "../trace/viewer.ts";
import { waitForHttp } from "../support/rooms_server.ts";
import { until } from "../support/wait.ts";
import { fail } from "../support/fail.ts";
import { awaitBubble, directOpened, openDmTo, pathSaid, pathTaken } from "../page/harness.ts";
import { takeCapability } from "../page/capability_set.ts";
import { formatRoomsSturdyref, roomsLocator } from "../../lib/locator.ts";
import { SIGNAL_CONNECT_TIMEOUT_MS, SIGNAL_EXCHANGE_TIMEOUT_MS } from "../../lib/limits.ts";
import { factDmRelay } from "../../lib/text/conversation.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi Bob, over the server because it won the race";
const REPLY_TEXT = "got it Alice, same sealed session back";
const RACE_TEXT = "hi Dave, over whichever route won";
const RACE_REPLY = "got it Carol, same route back";
// A local rendezvous through the page's own server. The bound is the WebRTC
// connect bound because a serial fallback, one that tries the relay only after
// WebRTC gives up, cannot open before that bound has passed. A line open
// within it was raced, since both routes start together.
const RELAY_DIAL_ALLOWANCE_MS = SIGNAL_CONNECT_TIMEOUT_MS;

async function joinAs(browser: Browser, port: number, nick: string, trace: string): Promise<Page> {
	const tab = await (await browser.newContext()).newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	tab.on("console", (m) => {
		if (m.type() === "error") console.error(`  [${nick} console.error]`, m.text());
	});
	await tab.goto(`http://127.0.0.1:${port}/`);
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

async function send(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

// Settings on a page with a server draws the radios, on Fastest unless the
// member chose.
async function onFastest(tab: Page): Promise<void> {
	await tab.click("#settingsBtn");
	await tab.click("#connectionTab");
	const checked = await tab.locator('input[name="dm"]:checked').inputValue({ timeout: 5_000 });
	if (checked !== "fastest") fail(`Settings opened on "${checked}", not on Fastest`);
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
}

// The page's **Browser trouble** rows: wasm failures with no surface of their
// own, read under Operations by a member holding the operator capability. The
// operator pane draws the rows from the page's own store in the same render
// as the panel, and draws no section while there are none, so a present panel
// with no rows is the state and not an unread one.
async function pageTrouble(tab: Page, operator: string): Promise<string[]> {
	await tab.click("#settingsBtn");
	await tab.click("#holdingsTab");
	await takeCapability(tab, "#opsOperatorToggle", operator);
	await tab.click("#opsBtn");
	await tab.click("#operatorOpsLink");
	await tab.waitForSelector("#operatorOpsPanel");
	return await tab.$$eval("#pageTrouble li", (rows) => rows.map((row) => row.textContent ?? ""));
}

const deadline = setTimeout(() => fail("web-dm-fastest scenario timed out after 100s"), 100_000);

const state = await Deno.makeTempDir({ prefix: "rooms-dm-fastest-" });
let browser: Browser | null = null;
let viewer: { close(): Promise<void> } | null = null;
try {
	const web = spawnWeb({
		args: ["--transport=tcp", "0", "0"],
		cwd: ROOT,
		env: {
			GLOWCAP_ROOMS_STATE: state,
			GLOWCAP_ROOMS_CAPABILITIES: "trace,operator",
			GLOWCAP_ROOMS_TRACE_PORT: "0",
		},
		stdout: "piped",
		stderr: "piped",
	});
	const traceRef = webAnnouncements(web).line("ROOMS-TRACE-LISTENING", "rooms-web");
	const httpPort = await webPort(web);
	await waitForHttp(httpPort);
	const sturdyref = await traceRef;
	// Every transport a session opened over, and the direct-message
	// sessions still standing by id, so a losing route that opened and was
	// then cancelled counts as gone.
	const transports = new Set<string>();
	const standing = new Map<string, string>();
	viewer = await connectTraceViewer(sturdyref, (record) => {
		const session = String(record.session ?? "");
		if (record.kind === "ocapn.session-opened") {
			const transport = String(record.transport ?? "");
			transports.add(transport);
			if (transport === "webrtc" || transport === "noise-relay") standing.set(session, transport);
		} else if (record.kind === "ocapn.session-closed") {
			standing.delete(session);
		}
	});

	// No non-proxied UDP: ICE gathers nothing, and the direct attempt never
	// proves the key on its own.
	browser = await chromium.launch({
		args: ["--no-sandbox", "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"],
	});

	const alice = await joinAs(browser, httpPort, "web-alice", sturdyref);
	const bob = await joinAs(browser, httpPort, "web-bob", sturdyref);
	await onFastest(alice);

	// Alice's Host dials both routes at once. The relay proves Bob's key first.
	const started = Date.now();
	await alice.locator('#members li:has-text("web-bob") button.dm-btn').click();
	await directOpened(alice, "web-bob", RELAY_DIAL_ALLOWANCE_MS).catch(() =>
		fail(`the direct line did not open over the server within a relay dial (${RELAY_DIAL_ALLOWANCE_MS} ms)`)
	);
	const elapsed = Date.now() - started;
	await pathSaid(alice, factDmRelay, "noise-relay");
	await send(alice, DM_TEXT);

	await openDmTo(bob, "web-alice");
	await awaitBubble(bob, DM_TEXT, "Bob");
	await pathSaid(bob, factDmRelay, "noise-relay");
	await send(bob, REPLY_TEXT);
	await awaitBubble(alice, REPLY_TEXT, "Alice");

	// The losing direct attempt: cancelled on Alice's side when the relay won,
	// and on Bob's side left to its exchange budget, which ends quietly.
	await until(
		() => Date.now() - started > SIGNAL_EXCHANGE_TIMEOUT_MS + 3_000,
		"the signaling exchange budget to pass",
		SIGNAL_EXCHANGE_TIMEOUT_MS + 4_000,
	);
	const locator = await (await fetch(`http://127.0.0.1:${httpPort}/locator`)).text();
	const operator = formatRoomsSturdyref(
		roomsLocator(locator.trim()),
		(await Deno.readTextFile(`${state}/operator`)).trim(),
	);
	for (const [who, tab] of [["Alice", alice], ["Bob", bob]] as const) {
		const signaling = (await pageTrouble(tab, operator)).filter((row) => /signaling/i.test(row));
		if (signaling.length > 0) {
			fail(
				`${who}'s Browser trouble reports a signaling failure for a line that opened: ${signaling.join(" | ")}`,
			);
		}
	}

	await until(() => transports.has("noise-relay"), "the live timeline to observe the noise-relay session", 5_000);
	if (transports.has("webrtc")) fail("a webrtc session opened although ICE had no route");
	console.log(
		`scene 1: with WebRTC unable to find a route, the direct line opened through the sealed relay ` +
			`in ${elapsed} ms (bound ${RELAY_DIAL_ALLOWANCE_MS} ms), both cards said so, the message went ` +
			`both ways, no webrtc session stood in for it, and neither tab holds a signaling failure`,
	);

	// Scene 2: UDP allowed, so both routes can prove the key.
	await browser.close();
	standing.clear();
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const carol = await joinAs(browser, httpPort, "web-carol", sturdyref);
	const dave = await joinAs(browser, httpPort, "web-dave", sturdyref);
	const raced = Date.now();
	await carol.locator('#members li:has-text("web-dave") button.dm-btn').click();
	await directOpened(carol, "web-dave", RELAY_DIAL_ALLOWANCE_MS).catch(() =>
		fail(`the raced direct line did not open within a relay dial (${RELAY_DIAL_ALLOWANCE_MS} ms)`)
	);
	const route = await pathTaken(carol);
	await send(carol, RACE_TEXT);
	await openDmTo(dave, "web-carol");
	await awaitBubble(dave, RACE_TEXT, "Dave");
	const daveRoute = await pathTaken(dave);
	if (daveRoute !== route) fail(`Carol's card names ${route} while Dave's names ${daveRoute}`);
	await send(dave, RACE_REPLY);
	await awaitBubble(carol, RACE_REPLY, "Carol");
	await until(
		() => Date.now() - raced > SIGNAL_EXCHANGE_TIMEOUT_MS + 3_000,
		"the signaling exchange budget to pass",
		SIGNAL_EXCHANGE_TIMEOUT_MS + 4_000,
	);
	for (const [who, tab] of [["Carol", carol], ["Dave", dave]] as const) {
		const signaling = (await pageTrouble(tab, operator)).filter((row) => /signaling/i.test(row));
		if (signaling.length > 0) {
			fail(
				`${who}'s Browser trouble reports a signaling failure for a raced line that opened: ${
					signaling.join(" | ")
				}`,
			);
		}
	}
	const lingering = [...standing.values()].filter((transport) => transport !== route);
	if (lingering.length > 0) {
		fail(`a ${lingering.join(", ")} session stands open after the ${route} route won the race`);
	}
	const loser = route === "webrtc" ? "noise-relay" : "webrtc";
	const loserOpened = transports.has(loser);

	console.log(
		`PASS: on Fastest with a server, the race lands on the relay when WebRTC has no route and on ` +
			`${route} when it has one, both cards name the route taken, messages go both ways, the losing ` +
			`route leaves no session standing (the ${loser} route ${
				loserOpened ? "opened and was closed" : "never opened a session"
			}), and neither tab's Browser trouble holds a signaling failure`,
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	if (viewer) await viewer.close().catch(() => {});
	await reapOwned();
	await Deno.remove(state, { recursive: true }).catch(() => {});
}
Deno.exit(0);
