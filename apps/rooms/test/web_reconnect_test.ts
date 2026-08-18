// The rooms page surviving the loss of its room server, in a real browser.
//
// A page holds two things with two lifetimes, and the whole of `ui/net.ts`'s
// shape is that distinction. A directory session dies whenever the room server
// restarts, and everything it held dies with it: the room it had us in, the
// lines redeemed over it, the name it advertised. What the *page* knows does
// not — the conversation you were reading is still yours — and neither does what
// makes this tab reachable, because a cold-dial line runs browser to browser
// through the relay and a room respawn has nothing to do with it.
//
// That distinction cannot be checked by reading. Which state belongs to a
// session is a property of what survives one dying, so it takes a session
// actually dying: this kills the room server out from under a joined page and
// holds the page to what should still be true afterwards.
//
//   1. The page notices. The composer closes rather than accepting lines into a
//      session that is gone.
//   2. It comes back on its own, re-entering the room it was in, with nobody
//      touching the browser.
//   3. The conversation is still there. History belongs to the page, not to the
//      session that happened to deliver it.
//   4. The room works again — a line sent afterwards reaches the room and comes
//      back, so what reconnected is a live capability and not a hopeful button.
//   5. The directory is repopulated, because a new session replays what it knows
//      and the page had thrown the old answers away.
//
// `serve.ts` supervises the room server and respawns it, which is what makes
// this a *reconnect* rather than a restart: this test kills only the room, and
// the page and its relay stay up throughout.
//
// Validated by breaking the code it watches, because a check that has never
// failed says nothing. Dropping the retry from `endSession` fails at (2);
// discarding the conversations with the session fails at (3); reconnecting
// without re-entering the room fails at (1). Each names its own cause, which is
// the reason the disabled-composer check asks for an attached element rather
// than a visible one — a vanished composer also refuses lines, and would
// otherwise be reported as a page that had not noticed.
//
// What a pass here does not cover, so nobody reads more into it than it says:
// the direct lines and reply routes a session holds, and the presence it
// advertised, are all torn down and rebuilt by the same path, but none of that
// is observable with one peer in the room. The other half of the lifetime claim
// — that the inbox host and its rendezvous registration are untouched by a room
// respawn, because a cold-dial line has nothing to do with the room server — is
// two-peer work and lives with `rooms-web-dm-tabs`. So is the line that is in
// flight when the session dies, which should come back with a retry action.
//
// Needs deno, cargo for the iroh sidecar, the wasm module (`zig build
// wasm-driver`), the native archives, and a Playwright Chromium.
// Run: `deno run --allow-all apps/rooms/test/web_reconnect_test.ts`.

import { chromium } from "playwright";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	throw new Error(message);
}

function freePort(): number {
	const l = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (l.addr as Deno.NetAddr).port;
	l.close();
	return port;
}

async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 400; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			await res.body?.cancel();
			if (res.status === 200) return;
		} catch {
			// not up yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("serve.ts did not answer with a room locator");
}

const httpPort = freePort();
const roomPort = freePort();

const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-write",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
		"--transport=iroh",
	],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
}).spawn();

/** Kill the room server, and only it.
 *
 * It is a child of `serve.ts`, not of this test, so it is selected beneath that
 * exact parent and by its server entrypoint. The page's own server is left
 * alone: the point is a lost room, not a lost page. */
async function killRoomServer(): Promise<void> {
	const killed = await new Deno.Command("pkill", {
		args: ["-P", String(web.pid), "-f", "server/main.ts"],
	}).output();
	if (!killed.success) fail("could not find the room server to kill");
}

const deadline = setTimeout(() => {
	console.error("FAIL: reconnect scenario timed out after 180s");
	try {
		web.kill();
	} catch {
		// already gone
	}
	Deno.exit(1);
}, 180_000);

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

	// Stepped away before the ground moves. What the roster shows is the room's
	// word, and a membership belongs to a connection — so a reconnect grants a
	// fresh one with nobody away, which would put this reader back in front of
	// everyone else while their own screen still said they had stepped out.
	await tab.fill("#line", "/away making tea");
	await tab.press("#line", "Enter");
	await tab.waitForSelector("#members li.away", { timeout: 30_000 })
		.catch(() => fail("saying you had stepped away did not show in the room"));

	// ── The room goes away ───────────────────────────────────────────────
	await killRoomServer();

	// The composer closes, which is the page saying it knows: a line typed now
	// would be accepted into a session that no longer exists.
	//
	// Attached rather than visible on purpose. A composer that has *vanished*
	// also refuses lines, but for a different reason — the page has no
	// conversation open at all — and asking for a visible one would report that
	// as this, sending a reader after the wrong thing. The checks below tell the
	// two apart.
	await tab.waitForSelector("#line[disabled]", { state: "attached", timeout: 30_000 })
		.catch(() =>
			fail(
				"the page kept accepting lines after its session died; it never noticed the room was gone",
			)
		);

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
	// reader's own word — which survived the session it was said on, and is
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
	).catch(() => fail("the room did not echo a line sent after the reconnect, so nothing usable came back"));

	// And this reader is still away in it. The room forgot — it granted a
	// membership to a connection that did not exist a moment ago — so what makes
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

	// The directory answers the new session too: the page cleared what the old
	// one told it, so a room in this list is one the new session reported.
	// The room echo and the directory watcher update are separate eventual
	// messages. Neither orders the other, so observe the promised state rather
	// than sampling it immediately after the echo happens to arrive.
	await tab.waitForFunction(
		() => [...document.querySelectorAll("#roomList .rname")].some((r) => r.textContent?.includes("workshop")),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the room list stayed empty after reconnecting, so the directory never replayed"));

	console.log(
		"PASS: the rooms page survived losing its room server — it noticed and closed the " +
			"composer, reconnected and re-entered its room untouched, kept the conversation " +
			"the dead session had delivered, round-tripped a line over the new one, and " +
			"repopulated the directory",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
Deno.exit(0);
