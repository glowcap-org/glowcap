// Joining a room from a fresh browser tab, the way every browser proof starts.
//
// Each tab gets a context of its own, so two members never share a nickname or
// a workspace through localStorage. The page's own errors and warnings are
// mirrored into the proof's output, because a scene that times out otherwise
// reports only the selector it never saw while the page has been saying what
// went wrong the whole time.

import type { Browser, Page } from "playwright";

import { fail } from "./fail.ts";
import { reachDirectoryOnCard } from "../page/harness.ts";
import { establishLocalSession } from "./session_setup.ts";
import { acquireTraceCapability } from "../trace/viewer.ts";

/** The room every proof joins unless it says otherwise. */
export const ROOM = "lobby";

export interface JoinOptions {
	/** The room to enter. */
	room?: string;
	/** A query string for the page address, such as `?dm=webrtc`, which picks
	 * the transport the tab advertises for direct messages. */
	query?: string;
	/** Acquire this exact trace capability before joining. */
	trace?: string;
	/** Press through the join card's directory question before naming the
	 * room. A locator is pasted into the card first, the way a visitor to
	 * somebody else's room arrives; `null` presses through for the page's own
	 * directory. Left out, the card is expected to offer the room directly. */
	directory?: string | null;
	viewport?: { width: number; height: number };
}

/** Open a fresh tab on the page served at `port`, join a room as `nick`, and
 * return the tab once its composer is live: the room session is up and the
 * tab can register for direct messages. `tab.context()` is the context to
 * close when that member leaves for good. */
export async function joinAs(browser: Browser, port: number, nick: string, options: JoinOptions = {}): Promise<Page> {
	const context = await browser.newContext(options.viewport === undefined ? {} : { viewport: options.viewport });
	const tab = await context.newPage();
	tab.on("pageerror", (error) => console.error(`  [${nick} page error]`, error.message));
	tab.on("console", (message) => {
		if (message.type() === "error" || message.type() === "warning") {
			console.error(`  [${nick} console.${message.type()}]`, message.text());
		}
	});
	await tab.goto(`http://127.0.0.1:${port}/${options.query ?? ""}`);
	await establishLocalSession(tab);
	if (options.trace != null) await acquireTraceCapability(tab, options.trace);
	if (options.directory !== undefined) {
		if (options.directory !== null) await tab.fill("#locator", options.directory);
		await tab.fill("#nick", nick);
		await reachDirectoryOnCard(tab);
	} else {
		await tab.fill("#nick", nick);
	}
	await tab.fill("#room", options.room ?? ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return tab;
}
