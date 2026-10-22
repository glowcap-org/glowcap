import { spawnWeb } from "../support/web_front.ts";
// The rooms page surviving the loss of its room server, in a real browser.
//
// The Rust application keeps directory connections separate from page intent.
// A directory session dies whenever the room server
// restarts, and everything it held dies with it: the room it had us in, the
// lines redeemed over it, the name it advertised. What the *page* knows does
// not, the conversation you were reading is still yours, and neither does what
// makes this tab reachable, because a cold-dial line runs browser to browser
// through the relay and a room respawn has nothing to do with it.
//
// That distinction cannot be checked by reading. Which state belongs to a
// session is a property of what survives one dying, so it takes a session
// actually dying: this kills the room server out from under a joined page and
// holds the page to what should still be true afterwards.
//
//   1. The page notices. The composer closes rather than accepting lines into a
//      session that is gone, and the room's own row in the rail says its
//      directory is away. That is the one-directory case, where the line is the
//      whole of what a row has to say about where it is.
//   2. It comes back on its own, re-entering the room it was in, with nobody
//      touching the browser.
//   3. The conversation is still there. History belongs to the page, not to the
//      session that happened to deliver it.
//   4. The room works again, a line sent afterwards reaches the room and comes
//      back, so what reconnected is a live capability and not a hopeful button.
//   5. The directory is repopulated, because a new session replays what it knows
//      and the page has thrown the earlier answers away. status-allow: event or source ordering
//   6. The restart in steps 1 to 5 was on the same build and reloaded
//      nothing, and a reload on a private room's address keeps the reader in
//      it.
//   7. A server that comes back on another build takes the page with it. The
//      page reloads once into the build `/ui-version` names and remembers it,
//      so a server whose page and `/ui-version` disagree cannot loop it.
//
// `serve.ts` supervises the room server and respawns it. This remains a
// *reconnect* rather than a restart because the test kills only the room, and
// the page and its relay stay up throughout.
//
// Validated by breaking the code it watches, because a check that has never
// failed says nothing. Dropping the retry from `endSession` fails at (2);
// discarding the conversations with the session fails at (3); reconnecting
// without re-entering the room fails at (1). Each names its own cause, which is
// the reason the disabled-composer check asks for an attached element rather
// than a visible one, a vanished composer also refuses lines, and would
// otherwise be reported as a page that had not noticed.
//
// What a pass here does not cover, so nobody reads more into it than it says:
// the direct lines and reply routes a session holds, and the presence it
// advertised, are all torn down and rebuilt by the same path, but none of that
// is observable with one peer in the room. The other half of the lifetime claim
// (that the inbox host and its rendezvous registration are untouched by a room
// respawn, because a cold-dial line has nothing to do with the room server) is
// two-peer work and lives with `rooms-web-dm-tabs`. So is the line that is in
// flight when the session dies, which should come back with a retry action.
//
// Needs deno, cargo for the iroh sidecar, the wasm module (`zig build
// wasm-driver`), the installed archives, and a Playwright Chromium.
// Run: `deno run --allow-all apps/rooms/test/web/reconnect_test.ts`.

/// <reference lib="dom" />

import { SERVER } from "../support/paths.ts";
import { chromium } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned } from "../support/children.ts";
import { makeRoom, openRailRoom, roomLink } from "../support/private_room_page.ts";
import { freePort, waitForHttp } from "../support/rooms_server.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	throw new Error(message);
}

const httpPort = freePort();
const roomPort = freePort();

const web = spawnWeb({
	args: ["--transport=tcp", String(httpPort), String(roomPort), "--transport=iroh"],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
});

/** Kill the room server, and only it.
 *
 * It is a child of `serve.ts`, not of this test, so it is selected beneath that
 * exact parent and by its server entrypoint: the installed executable. The page's own
 * server is left alone: the point is a lost room, not a lost page. */
async function killRoomServer(): Promise<void> {
	const entrypoint = SERVER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	const killed = await new Deno.Command("pkill", {
		args: ["-P", String(web.pid), "-f", entrypoint],
	}).output();
	if (!killed.success) fail("could not find the room server to kill");
}

const deadline = setTimeout(() => fail("reconnect scenario timed out after 180s"), 180_000);

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);
	const locatorBefore = (await fetch(`http://127.0.0.1:${httpPort}/locator`).then((res) => res.text())).trim();
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("pageerror", (e) => console.error("  [page error]", e.message));
	tab.on("console", (message) => {
		const line = message.text();
		if (line.includes("rooms:") || message.type() === "error") {
			console.error("  [page]", line.slice(0, 400));
		}
	});

	await tab.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(tab);
	await tab.fill("#nick", "ada");
	await tab.fill("#room", "workshop");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });

	const before = "sent before the room went away";
	await tab.fill("#line", before);
	await tab.press("#line", "Enter");
	await tab.waitForFunction(
		(text) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(text)),
		before,
		{ timeout: 30_000 },
	).catch(() => fail("the room never echoed the first line, so there was nothing to survive"));

	// A private room has no directory name to ask for after this session dies.
	// Create its durable bearer authority through the visible Capabilities
	// control, then return to the listed room before the server is killed. The
	// reconnect below has to recover both by their different authorities.
	await makeRoom(tab, "retained", true);
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
	const privateBefore = "private before the room went away";
	await tab.fill("#line", privateBefore);
	await tab.press("#line", "Enter");
	await tab.waitForFunction(
		(text) => [...document.querySelectorAll(".bubble")].some((bubble) => bubble.textContent?.includes(text)),
		privateBefore,
		{ timeout: 30_000 },
	).catch(() => fail("the private room never echoed the line its reconnect should preserve"));
	await roomLink(tab, "ada");
	await openRailRoom(tab, "workshop", false);

	// Stepped away before the ground moves. What the roster shows is the room's
	// word, and a membership belongs to a connection, so a reconnect grants a
	// fresh one with nobody away, which would put this reader back in front of
	// everyone else while their own screen still said they had stepped out.
	await tab.fill("#line", "/away making tea");
	await tab.press("#line", "Enter");
	await tab.waitForSelector("#members li.away", { timeout: 30_000 })
		.catch(() => fail("saying you had stepped away did not show in the room"));

	// ── The room goes away ───────────────────────────────────────────────
	// Hold new relay connections until both signs of the outage appear. The
	// row deliberately withholds reconnecting text for short blips, so an
	// immediate restart could recover before it ever owes the reader a caption.
	// Existing sockets remain live until the real server kill below.
	let holdReconnect = true;
	await tab.routeWebSocket(/\/relay/, (socket) => {
		if (holdReconnect) socket.close();
		else socket.connectToServer();
	});
	await tab.evaluate(() => {
		const seen = { closed: false, rowSaid: false };
		(globalThis as unknown as { __roomGone: typeof seen }).__roomGone = seen;
		const look = () => {
			// Attached rather than visible. A composer that has
			// vanished also refuses lines, but for a different reason (the page
			// has no conversation open at all), and asking for a visible one would
			// report that as this, sending a reader after the wrong thing.
			if (document.querySelector("#line[disabled]") != null) seen.closed = true;
			// A room whose directory is away is a room this reader cannot reach,
			// which is a fact about that row, so the row that carries the
			// directory carries how it is doing. One directory is the case with no
			// name worth drawing beside it, so the line arrives with the news and
			// is the only thing on it. That is exactly the case a caption drawn
			// only when a directory is worth naming would silently lose.
			if (
				[...document.querySelectorAll("#roomList li")].some((row) =>
					(row.querySelector(".rwhere-how")?.textContent ?? "").trim() !== ""
				)
			) seen.rowSaid = true;
		};
		new MutationObserver(look).observe(document.body, {
			subtree: true,
			childList: true,
			attributes: true,
			characterData: true,
		});
	});
	const roomGone = (sign: "closed" | "rowSaid") =>
		tab.waitForFunction(
			(which) => (globalThis as unknown as { __roomGone: Record<string, boolean> }).__roomGone[which],
			sign,
			{ timeout: 30_000 },
		);
	// Every document load from here on is a reload, and the restart below is
	// on the same build, so it must cause none.
	let reloads = 0;
	tab.on("load", () => reloads += 1);
	await killRoomServer();

	// The composer closes, which is the page saying it knows: a line typed now
	// would be accepted into a session that does not exist.
	await roomGone("closed").catch(() =>
		fail("the page kept accepting lines after its session died; it never noticed the room was gone")
	);
	await roomGone("rowSaid").catch(() => fail("the room held on a directory that went away never said so on its row"));
	holdReconnect = false;

	// ── It comes back by itself ──────────────────────────────────────────
	// Nobody touches the browser here. `serve.ts` respawns the room, the page
	// reconnects on its own backoff and re-enters the room it was in.
	await tab.waitForSelector("#line:not([disabled])", { timeout: 90_000 })
		.catch(() => fail("the page never reconnected and re-entered its room"));
	const locatorAfter = (await fetch(`http://127.0.0.1:${httpPort}/locator`).then((res) => res.text())).trim();
	const authority = (locator: string) => {
		const uri = new URL(locator);
		return `${uri.protocol}//${uri.host}`;
	};
	if (authority(locatorAfter) !== authority(locatorBefore)) {
		fail(`the supervised room changed authority across its restart: ${locatorBefore} became ${locatorAfter}`);
	}

	// The foot settles with the connection: once the room is re-entered the
	// state row stops narrating the reconnect and hands the line back to the
	// reader's own word, which survived the session it was said on, and is
	// exactly what this test stepped away to prove. The identity row stays who
	// this tab is; membership itself is the composer above and the rail's row.
	await tab.waitForFunction(
		() => {
			const state = (document.querySelector("#standingBtn #status")?.textContent ?? "").trim();
			const name = (document.querySelector("#standingBtn .foot-names .name")?.textContent ?? "").trim();
			return state === "making tea" && name === "ada";
		},
		undefined,
		{ timeout: 30_000 },
	).catch(async () => {
		const foot = await tab.evaluate(() => ({
			state: document.querySelector("#standingBtn #status")?.textContent ?? "",
			name: document.querySelector("#standingBtn .foot-names .name")?.textContent ?? "",
		}));
		fail(`after reconnecting the foot never settled back onto the reader: ${JSON.stringify(foot)}`);
	});

	// ── What belonged to the page is still the page's ────────────────────
	const kept = await tab.evaluate(
		(text) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(text)),
		before,
	);
	if (!kept) {
		fail(
			"the conversation was thrown away with the session that delivered it; " +
				"history belongs to the page",
		);
	}

	// ── And the room is a live capability again, not a hopeful button ────
	const after = "sent after it came back";
	await tab.fill("#line", after);
	await tab.press("#line", "Enter");
	await tab.waitForFunction(
		(text) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(text)),
		after,
		{ timeout: 30_000 },
	).catch(async () => {
		const state = await tab.evaluate(() => ({
			composer: document.getElementById("composerAvailability")?.textContent ?? "",
			line: (document.getElementById("line") as HTMLInputElement | null)?.value ?? "",
			toasts: document.getElementById("toasts")?.textContent ?? "",
			standing: document.getElementById("standingBtn")?.textContent ?? "",
			log: document.getElementById("log")?.textContent?.slice(-1000) ?? "",
		}));
		fail(
			`the room did not echo a line sent after the reconnect, so nothing usable came back: ${
				JSON.stringify(state)
			}`,
		);
	});

	// And this reader is still away in it. The room forgot, it granted a
	// membership to a connection that did not exist a moment ago, so what makes
	// this true is the page saying it again, and what makes it worth checking is
	// that nobody would have noticed it silently stop being true.
	await tab.waitForSelector("#members li.away", { timeout: 30_000 })
		.catch(async () => {
			const roster = await tab.evaluate(() =>
				[...document.querySelectorAll("#members li")].map((row) =>
					row.className + ": " + (row.textContent ?? "").slice(0, 40)
				)
			);
			fail(`reconnecting walked this reader back in without saying so: ${JSON.stringify(roster)}`);
		});

	// And the row goes quiet again. The line is drawn while a directory has
	// something to say and goes when it stops, because a row repeating
	// "Connected" for the life of the tab is furniture.
	await tab.waitForFunction(
		() =>
			[...document.querySelectorAll("#roomList li")].every((row) =>
				(row.querySelector(".rwhere-how")?.textContent ?? "").trim() === ""
			),
		undefined,
		{ timeout: 30_000 },
	).catch(async () => {
		const rail = await tab.evaluate(() =>
			[...document.querySelectorAll("#roomList li")].map((row) => (row.textContent ?? "").trim())
		);
		fail(`a room whose directory came back is still saying it is away: ${JSON.stringify(rail)}`);
	});

	// The directory answers the new session too: the page cleared what the old status-allow: replacement state identity
	// one told it, so a room in this list is one the new session reported.
	// The room echo and the directory watcher update are separate eventual
	// messages. Neither orders the other, so observe the promised state rather
	// than sampling it immediately after the echo happens to arrive.
	await tab.waitForFunction(
		() => [...document.querySelectorAll("#roomList .rname")].some((r) => r.textContent?.includes("workshop")),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the room list stayed empty after reconnecting, so the directory never replayed"));

	// The private conversation came back by its sturdyref, not by its label.
	// Press its rail row and send over the recovered membership. The old line is status-allow: replacement state identity
	// still page history and the new echo proves the live capability returned.
	await openRailRoom(tab, "retained", true);
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("the linked private room did not re-enter after the directory reconnected"));
	const privateKept = await tab.evaluate(
		(text) => [...document.querySelectorAll(".bubble")].some((bubble) => bubble.textContent?.includes(text)),
		privateBefore,
	);
	if (!privateKept) fail("the private conversation was discarded while its durable room was re-entered");
	const privateAfter = "private after the room came back";
	await tab.fill("#line", privateAfter);
	await tab.press("#line", "Enter");
	await tab.waitForFunction(
		(text) => [...document.querySelectorAll(".bubble")].some((bubble) => bubble.textContent?.includes(text)),
		privateAfter,
		{ timeout: 30_000 },
	).catch(() => fail("the linked private room did not echo over its recovered membership"));

	// ── A same-build restart reloaded nothing ────────────────────────────
	if (reloads !== 0) fail(`the page reloaded ${reloads} times across a restart on its own build`);

	// ── A reload keeps the reader in their private room ───────────────────
	// The room restored from the workspace reads as open until its directory
	// answers, and the private address waits for that answer rather than
	// sending the reader to the join card.
	await tab.reload();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail(`a reload left the private room for ${tab.url()}`));
	if (!new URL(tab.url()).pathname.startsWith("/room/retained")) {
		fail(`a reload left the private room for ${tab.url()}`);
	}

	// ── A server on another build takes the page with it ─────────────────
	// `/ui-version` now names another build, as a server restarted from a new
	// bundle would, and the page reloads into it once the restart drops it.
	await tab.route(
		"**/ui-version",
		(route) => route.fulfill({ status: 200, contentType: "text/plain", body: "a-later-build\n" }),
	);
	const reloaded = tab.waitForEvent("load", { timeout: 60_000 });
	await killRoomServer();
	await reloaded.catch(() => fail("the page stayed on its build after its server came back on another"));
	await tab.waitForSelector("#line:not([disabled])", { timeout: 90_000 })
		.catch(() => fail(`the page reloaded for the new build but never re-entered its room at ${tab.url()}`));
	// The reloaded page still differs from what `/ui-version` names, because the
	// route answers for a build that never arrives. What keeps that from looping
	// is the build the tab remembers across the reload, which only a browser
	// can prove survives it.
	const remembered = await tab.evaluate(() => sessionStorage.getItem("rooms:reloaded-for-build"));
	if (remembered !== "a-later-build") {
		fail(`the tab remembered ${JSON.stringify(remembered)}, so a server that contradicts itself could loop it`);
	}

	console.log(
		"PASS: the rooms page survived losing its room server — it noticed and closed the " +
			"composer, reconnected and re-entered its named room and durable private room, kept " +
			"the conversations the dead session had delivered, round-tripped lines over the new " +
			"memberships, repopulated the directory, stayed put across a same-build restart, kept a " +
			"reloaded private room, and reloaded once into a server's new build",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
