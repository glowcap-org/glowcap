/// <reference lib="dom" />

// A phone that loses its network keeps its page. The page says it is offline,
// keeps what is typed, and sends it once, without a reload, when the network is
// back. Only a real browser shows the wasm Host retiring its stale session and
// dialing again through the relay.

import type { BrowserContext, Page, WebSocketRoute } from "playwright";
import { fail } from "../support/fail.ts";
import { sessionOffline } from "../../lib/text/page.ts";

/** A page's sockets to the relay, which a test can break. A device that loses
 * its network loses them with it, and the browser's own offline switch spares
 * the sockets that are already open. */
export class RelayWire {
	#cut = false;
	/** Sockets that stay open and carry nothing, as a half-open connection does. */
	readonly #stalled = new WeakSet<WebSocketRoute>();
	readonly #open = new Set<WebSocketRoute>();
	/** Route every relay socket the page opens from now on. */
	async install(page: Page): Promise<void> {
		await page.routeWebSocket(/\/relay/, (socket) => {
			if (this.#cut) {
				socket.close();
				return;
			}
			const server = socket.connectToServer();
			socket.onMessage((message) => {
				if (!this.#stalled.has(socket)) server.send(message);
			});
			server.onMessage((message) => {
				if (!this.#stalled.has(socket)) socket.send(message);
			});
			this.#open.add(socket);
			socket.onClose(() => this.#open.delete(socket));
		});
	}
	/** Close the sockets that are open, and refuse new ones. */
	cut(): void {
		this.#cut = true;
		for (const socket of this.#open) socket.close();
	}
	/** Keep the open sockets open, and let nothing through them in either direction. */
	stall(): void {
		for (const socket of this.#open) this.#stalled.add(socket);
	}
	restore(): void {
		this.#cut = false;
	}
}

export async function proveSharedSessionOffline(
	page: Page,
	context: BrowserContext,
	wire: RelayWire,
	line: string,
	/** Another page of the same session, which must see the line too. */
	peer: Page,
): Promise<void> {
	await page.evaluate(() => Reflect.set(window, "keptAcrossNetworkLoss", true));
	await context.setOffline(true);
	wire.cut();
	try {
		await page.locator("#line").fill(line);
		await page.locator(".session-link-notice").getByText(sessionOffline, { exact: true }).waitFor({
			timeout: 30_000,
		}).catch(async () => fail(`a page did not say it was offline: view=${await page.locator("body").innerText()}`));
	} finally {
		wire.restore();
		await context.setOffline(false);
	}
	await page.locator(".session-link-notice").waitFor({ state: "detached", timeout: 60_000 }).catch(async () =>
		fail(`a page did not reconnect after the network returned: view=${await page.locator("body").innerText()}`)
	);
	if (await page.evaluate(() => Reflect.get(window, "keptAcrossNetworkLoss")) !== true) {
		fail("a page reloaded instead of reconnecting");
	}
	if (await page.inputValue("#line") !== line) fail("the draft did not survive the network loss");
	await page.press("#line", "Enter");
	const bubbles = page.locator(".bubble").filter({ hasText: line });
	await bubbles.first().waitFor({ timeout: 30_000 }).catch(() =>
		fail("a line sent after the network returned never landed")
	);
	// Count only once the line has settled on both pages, so a second copy that
	// is still on its way cannot be missed.
	const seen = peer.locator(".bubble").filter({ hasText: line });
	await seen.first().waitFor({ timeout: 30_000 }).catch(() =>
		fail("a line sent after the network returned never reached the other page")
	);
	for (const [name, copies] of [["this page", bubbles], ["the other page", seen]] as const) {
		if (await copies.count() !== 1) fail(`a line sent after the network returned landed more than once on ${name}`);
	}
}

/** A connection that stays open and carries nothing: the page sends into it,
 * finds it dead, dials again, and the line lands once on both pages. */
export async function proveSharedSessionHalfOpen(
	page: Page,
	wire: RelayWire,
	line: string,
	peer: Page,
): Promise<void> {
	// A reload would drop this marker, so it proves the page kept itself.
	await page.evaluate(() => {
		Object.assign(window, { keptThroughRecovery: true });
	});
	wire.stall();
	await page.fill("#line", line);
	await page.press("#line", "Enter");
	const here = page.locator(".bubble").filter({ hasText: line });
	const there = peer.locator(".bubble").filter({ hasText: line });
	await there.first().waitFor({ timeout: 90_000 }).catch(async () =>
		fail(
			`a line sent over a connection that carried nothing never landed: view=${await page.locator("body")
				.innerText()}`,
		)
	);
	await here.first().waitFor({ timeout: 30_000 });
	await page.locator(".session-link-notice").waitFor({ state: "detached", timeout: 60_000 });
	if (!await page.evaluate(() => "keptThroughRecovery" in window)) {
		fail("the page reloaded to recover from a connection that carried nothing");
	}
	for (const [name, copies] of [["this page", here], ["the other page", there]] as const) {
		if (await copies.count() !== 1) fail(`a line sent over a dead connection landed more than once on ${name}`);
	}
}
