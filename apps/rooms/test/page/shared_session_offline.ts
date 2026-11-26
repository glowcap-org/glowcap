/// <reference lib="dom" />

// A phone that loses its network keeps its page. The page says it is offline,
// keeps what is typed, and sends it once, without a reload, when the network is
// back, and a management control it holds is reached again. Only a real
// browser shows the wasm Host retiring its stale session and dialing again
// through the relay.

import type { BrowserContext, Locator, Page, WebSocketRoute } from "playwright";
import { fail } from "../support/fail.ts";
import { sessionOffline, sessionTryNow } from "../../lib/text/page.ts";
import { managedAccessText } from "../../lib/text/managed_access.ts";
import { composerUseSessionDraft } from "../../lib/text/controls.ts";
import { holdControl } from "./shared_session_access.ts";
import { keptItself, markKept } from "./harness.ts";
import { until, within } from "../support/wait.ts";

/** A page's sockets to the relay, which a test can break. A device that loses
 * its network loses them with it, and the browser's own offline switch spares
 * the sockets that are already open. */
export class RelayWire {
	#cut = false;
	/** Sockets that stay open and carry nothing back to the page, as a
	 * connection that breaks on the way back does. */
	readonly #stalled = new WeakSet<WebSocketRoute>();
	readonly #open = new Set<WebSocketRoute>();
	#watch: Watch | null = null;
	/** Route every relay socket the page opens from now on. */
	async install(page: Page): Promise<void> {
		await page.routeWebSocket(/\/relay/, (socket) => {
			if (this.#cut) {
				socket.close();
				return;
			}
			const tripped = this.#watch;
			if (tripped != null && tripped.marker == null) tripped.redialed.resolve();
			const server = socket.connectToServer();
			socket.onMessage((message) => {
				const watch = this.#watch;
				if (watch?.marker != null && carries(message, watch.marker)) {
					// Stalled before the send goes on, so no answer to it can come back.
					this.#stalled.add(socket);
					watch.marker = null;
					watch.stalled.resolve();
				}
				server.send(message);
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
	/** Stall the socket that next sends `text`, from that send on: the send
	 * reaches the session, and no answer comes back over that socket. The
	 * browser leg is cleartext, so the words show in the frame that carries
	 * them. `stalled` settles at that send, and `redialed` once the page opens
	 * another socket after it. */
	stallOnSend(text: string): { stalled: Promise<void>; redialed: Promise<void> } {
		const watch: Watch = {
			marker: new TextEncoder().encode(text),
			stalled: Promise.withResolvers(),
			redialed: Promise.withResolvers(),
		};
		this.#watch = watch;
		return { stalled: watch.stalled.promise, redialed: watch.redialed.promise };
	}
	restore(): void {
		this.#cut = false;
	}
}

interface Watch {
	/** The bytes still waited for, or null once a send carried them. */
	marker: Uint8Array | null;
	readonly stalled: PromiseWithResolvers<void>;
	readonly redialed: PromiseWithResolvers<void>;
}

function carries(message: string | Uint8Array, marker: Uint8Array): boolean {
	const bytes = typeof message === "string" ? new TextEncoder().encode(message) : message;
	search: for (let at = 0; at + marker.length <= bytes.length; at++) {
		for (let i = 0; i < marker.length; i++) if (bytes[at + i] !== marker[i]) continue search;
		return true;
	}
	return false;
}

export async function proveSharedSessionOffline(
	page: Page,
	context: BrowserContext,
	wire: RelayWire,
	line: string,
	/** Another page of the same session, which must see the line too. */
	peer: Page,
): Promise<void> {
	await markKept(page);
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
	if (!await keptItself(page)) fail("a page reloaded instead of reconnecting");
	if (await page.inputValue("#line") !== line) fail("the draft did not survive the network loss");
	await page.press("#line", "Enter");
	const bubbles = page.locator(".bubble").filter({ hasText: line });
	await bubbles.first().waitFor({ timeout: 30_000 }).catch(() =>
		fail("a line sent after the network returned never landed")
	);
	// Count only once the page has settled the line as sent and the other page
	// shows it, so a second copy a resend would have made has been made by now.
	await page.locator(".bubble:not(.sending):not(.unconfirmed):not(.failed)").filter({ hasText: line }).first()
		.waitFor({ timeout: 30_000 }).catch(() => fail("a line sent after the network returned never settled as sent"));
	const seen = peer.locator(".bubble").filter({ hasText: line });
	await seen.first().waitFor({ timeout: 30_000 }).catch(() =>
		fail("a line sent after the network returned never reached the other page")
	);
	for (const [name, copies] of [["this page", bubbles], ["the other page", seen]] as const) {
		if (await copies.count() !== 1) fail(`a line sent after the network returned landed more than once on ${name}`);
	}
}

/** The other view saves its draft while this page is offline. The local
 * draft stays readable until the person explicitly adopts the session copy. */
export async function proveSharedDraftConflict(
	page: Page,
	context: BrowserContext,
	wire: RelayWire,
	peer: Page,
	saved: (text: string) => Promise<boolean>,
): Promise<void> {
	const local = "Private words to keep before choosing";
	const remote = "The draft saved from the other view";
	await context.setOffline(true);
	wire.cut();
	try {
		await page.fill("#line", local);
		await peer.fill("#line", remote);
		await until(() => saved(remote), "the other view's draft to be saved");
	} finally {
		wire.restore();
		await context.setOffline(false);
	}
	const useSession = page.getByRole("button", { name: composerUseSessionDraft, exact: true });
	await useSession.waitFor();
	await page.press("#line", "Enter");
	if (!await page.locator("#sendBtn").isDisabled() || await page.inputValue("#line") !== local) {
		fail("the conflicting draft must stay local and available to copy");
	}
	await useSession.click();
	await page.waitForFunction((text) => document.querySelector<HTMLTextAreaElement>("#line")?.value === text, remote);
	const fresh = "Written after choosing the session draft";
	await page.fill("#line", fresh);
	await page.press("#line", "Enter");
	await peer.locator(".bubble").filter({ hasText: fresh }).first().waitFor();
	for (const text of [local, remote]) {
		if (await peer.locator(".bubble").filter({ hasText: text }).count()) {
			fail("resolving the draft conflict sent a draft");
		}
	}
}

/** A connection that carries the line to the session and nothing back: the
 * line's answer is lost, and the page finds the connection dead, dials again,
 * and settles the line from the session's record. The session then records the
 * line once, both pages show it once, and the page does not send it again.
 * `posted` counts the lines the session records as sent from this workspace. */
export async function proveSharedSessionHalfOpen(
	page: Page,
	wire: RelayWire,
	line: string,
	peer: Page,
	posted: () => Promise<number>,
): Promise<void> {
	await markKept(page);
	const before = await posted();
	await page.fill("#line", line);
	// The draft carries the line's words too. Once the other page shows it, the
	// session holds that draft, and clearing it on Enter carries no words, so
	// the next send that carries them is the line's own. The page prepares the
	// line itself, so that send is its submission.
	await peer.waitForFunction(
		(text) => {
			const field = document.querySelector("#line");
			return field instanceof HTMLTextAreaElement && field.value === text;
		},
		line,
		{ timeout: 30_000 },
	).catch(() => fail("a draft typed on one page never reached the other"));
	const wait = wire.stallOnSend(line);
	await page.press("#line", "Enter");
	await within(wait.stalled, "the line's submission", 30_000).catch(() =>
		fail("a line pressed with Enter never left over the connection")
	);
	await within(wait.redialed, "a new connection", 90_000).catch(async () =>
		fail(
			`a page did not dial again after a connection that carried nothing back: view=${await page.locator("body")
				.innerText()}`,
		)
	);
	// The session records the line it ran whether or not its answer reached the
	// page, so this counts sends, and the bubble below shows the page settled it.
	await until(async () => await posted() > before, "the session to record the line", 90_000).catch(async () =>
		fail(
			`a line whose answer was lost was never settled from the session's record: view=${await page.locator("body")
				.innerText()}`,
		)
	);
	// The line has been sending far longer than the page waits before it marks
	// a line sending, so a bubble without that mark is one the page settled.
	const here = page.locator(".bubble").filter({ hasText: line });
	await page.locator(".bubble:not(.sending):not(.unconfirmed):not(.failed)").filter({ hasText: line }).first()
		.waitFor({ timeout: 30_000 }).catch(async () =>
			fail(`a line whose answer was lost did not settle as sent: view=${await page.locator("body").innerText()}`)
		);
	const there = peer.locator(".bubble").filter({ hasText: line });
	await there.first().waitFor({ timeout: 30_000 }).catch(() =>
		fail("a line whose answer was lost never reached the other page")
	);
	// Counted once the page settled the line and the other page shows it, so a
	// resend that would record it again has been recorded by now.
	if (await posted() !== before + 1) fail("the session recorded a line whose answer was lost more than once");
	if (!await keptItself(page)) fail("the page reloaded to recover from a connection that carried nothing back");
	if (await page.inputValue("#line") !== "") fail("a line that landed came back to the composer");
	const sides: [string, Locator][] = [["this page", here], ["the other page", there]];
	for (const [name, copies] of sides) {
		if (await copies.count() !== 1) fail(`a line whose answer was lost landed more than once on ${name}`);
	}
}

/** A management control this page holds reaches the session over a
 * connection of its own, which the network takes with it. A read through it
 * then shows its row unreached with Try now, and once the network is back the
 * move onto the new link reaches it again, without a reload. `control` is the
 * session's management link. */
export async function proveHeldAccessOffline(
	page: Page,
	context: BrowserContext,
	wire: RelayWire,
	control: string,
): Promise<void> {
	const view = async () => await page.locator("body").innerText();
	await markKept(page);
	await page.click("#settingsBtn");
	await page.click("#sessionTab");
	await page.click("#sessionAccessOpen");
	const access = page.locator(".session-access-modal");
	await holdControl(page, control);
	const manage = page.getByRole("button", { name: managedAccessText.manage, exact: true });
	const held = access.locator("li.entry").filter({ has: manage }).last();
	const tryNow = held.getByRole("button", { name: sessionTryNow, exact: true });
	await held.waitFor({ timeout: 30_000 }).catch(async () =>
		fail(`the held control has no row: view=${await view()}`)
	);
	await context.setOffline(true);
	wire.cut();
	try {
		await page.locator(".session-link-notice").getByText(sessionOffline, { exact: true }).waitFor({
			timeout: 30_000,
		}).catch(async () => fail(`a page holding a control did not say it was offline: view=${await view()}`));
		// Opening the card reads what the access made, through the control.
		await held.getByRole("button", { name: managedAccessText.manage, exact: true }).click();
		const card = page.locator(".session-grant-edit-modal");
		await card.waitFor({ timeout: 10_000 });
		await tryNow.waitFor({ timeout: 30_000 }).catch(async () =>
			fail(`a held control whose connection went with the network was not shown unreached: view=${await view()}`)
		);
		await card.getByRole("button", { name: "Close", exact: true }).click();
		await card.waitFor({ state: "hidden" });
	} finally {
		wire.restore();
		await context.setOffline(false);
	}
	await page.locator(".session-link-notice").waitFor({ state: "detached", timeout: 60_000 }).catch(async () =>
		fail(`a page holding a control did not reconnect: view=${await view()}`)
	);
	await tryNow.waitFor({ state: "detached", timeout: 60_000 }).catch(async () =>
		fail(`a held control was not reached again over the new link: view=${await view()}`)
	);
	await held.getByRole("button", { name: managedAccessText.manage, exact: true }).waitFor({ timeout: 10_000 });
	if (!await keptItself(page)) fail("a page reloaded to reach its held control again");
	await access.getByRole("button", { name: "Close", exact: true }).click();
	await page.click("#settingsClose");
}
