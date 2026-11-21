// Choosing, testing, saving, and removing the Rooms server used by this browser.
import type { Browser } from "playwright";
import { fail } from "../support/fail.ts";
import {
	serverConnected,
	serverNotConnected,
	serverReplyUnavailable,
	serverTestAnswers,
	settingsRelayAway,
} from "../../lib/text/settings.ts";

export async function proveServerConnection(browser: Browser, httpPort: number): Promise<void> {
	// A relay that refuses registration leaves the session open. Settings says
	// people cannot reach this browser, in the catalog's words.
	{
		const relayless = await browser.newContext();
		const open = await relayless.newPage();
		await open.routeWebSocket(/\/register\b/, (socket) => socket.close());
		await open.goto(`http://127.0.0.1:${httpPort}/`);
		await open.click("#sessionUseLocal", { timeout: 60_000 });
		await open.waitForSelector("#settingsBtn", { timeout: 30_000 })
			.catch(() => fail("a refused relay kept this browser's session from opening"));
		await open.click("#settingsBtn");
		await open.click("#connectionTab");
		const said = await open.waitForSelector("#relayAway .said-clamp", { timeout: 30_000 })
			.catch(() => fail("Settings did not say that a refused relay leaves this browser unreachable"));
		if ((await said.textContent()) !== settingsRelayAway(`127.0.0.1:${httpPort}`)) {
			fail(
				`the unreachable relay was not described in the catalog's words: ${
					JSON.stringify(await said.textContent())
				}`,
			);
		}
		await relayless.close();
	}

	// A server the page was sent to is the one the reopened page uses. The same
	// server under another host name is another origin, so it turns this page
	// away, and the card and the change dialog both say so.
	{
		const elsewhere = await browser.newContext();
		const open = await elsewhere.newPage();
		const away = `http://localhost:${httpPort}/`;
		await open.goto(`http://127.0.0.1:${httpPort}/?server=${encodeURIComponent(away)}`);
		await open.click("#serverOfferUse", { timeout: 60_000 });
		await open.click("#sessionUseLocal", { timeout: 60_000 });
		await open.waitForSelector("#settingsBtn", { timeout: 60_000 })
			.catch(() => fail("a server that turns the page away kept its session from opening"));
		await open.click("#settingsBtn");
		await open.click("#connectionTab");
		// The card names the chosen server, with its address to copy for
		// another browser's server field.
		const shown = {
			name: await open.textContent("#serverName"),
			address: (await open.textContent("#serverBase"))?.trim(),
		};
		const expected = { name: `localhost:${httpPort}`, address: away };
		if (JSON.stringify(shown) !== JSON.stringify(expected)) {
			fail(`the server card did not show the chosen server: ${JSON.stringify(shown)}`);
		}
		// The card and Test report that the browser couldn't read the reply.
		const refusal = serverReplyUnavailable(`http://127.0.0.1:${httpPort}`);
		await open.waitForFunction(
			(text) => document.querySelector("#relayAway")?.textContent?.includes(text) ?? false,
			refusal,
			{ timeout: 30_000 },
		).catch(async () =>
			fail(`the card did not name the refusal: ${JSON.stringify(await open.textContent("#relayAway"))}`)
		);
		if ((await open.textContent("#serverConnection")) !== serverNotConnected) {
			fail(`the card's chip said ${JSON.stringify(await open.textContent("#serverConnection"))}`);
		}
		await open.click("#serverChange");
		if (await open.inputValue("#serverAddress") !== away) {
			fail("the reloaded page did not keep the server it was sent to");
		}
		// An unreadable reply leaves Save off.
		const saveOff = async (why: string) => {
			if (!(await open.isDisabled("#serverSave"))) fail(`Save was on ${why}`);
		};
		await saveOff("with nothing changed");
		const home = `http://127.0.0.1:${httpPort}/`;
		await open.fill("#serverAddress", home);
		await saveOff("before the change was tested");
		await open.fill("#serverAddress", away);
		await open.click("#serverTest");
		const tested = await open.waitForSelector("#serverTestSaid", { timeout: 15_000 })
			.catch(() => fail("testing a server said nothing"));
		if (!(await tested.textContent())?.includes(refusal)) {
			fail(`the server test did not name the refusal: ${JSON.stringify(await tested.textContent())}`);
		}
		await saveOff("after a test that was turned away");
		// The page's own server answers, and Enter saves once it has.
		await open.fill("#serverAddress", home);
		await saveOff("before the change was tested");
		await open.press("#serverAddress", "Enter");
		await open.waitForFunction(
			(said) => document.querySelector("#serverTestSaid")?.textContent?.includes(said) ?? false,
			serverTestAnswers,
			{ timeout: 15_000 },
		).catch(() => fail("Enter on an untested change did not test it"));
		if (await open.isDisabled("#serverSave")) fail("Save stayed off after the change answered");
		await Promise.all([open.waitForEvent("load"), open.press("#serverAddress", "Enter")]);
		await open.waitForSelector("#settingsBtn", { timeout: 60_000 })
			.catch(() => fail("saving a tested server kept the reloaded page from opening"));
		await open.click("#settingsBtn");
		await open.click("#connectionTab");
		await open.waitForFunction(
			(said) => document.querySelector("#serverConnection")?.textContent === said,
			serverConnected,
			{ timeout: 30_000 },
		).catch(async () =>
			fail(`the saved server did not connect: ${JSON.stringify(await open.textContent("#serverConnection"))}`)
		);
		await elsewhere.close();
	}
}

export async function proveServerOffers(browser: Browser, httpPort: number): Promise<void> {
	// A link that offers a relay asks before anything opens, and its offer
	// leaves the address whatever the answer. Only the answer changes the relay.
	for (const use of [true, false]) {
		const linked = await browser.newContext();
		const open = await linked.newPage();
		const offered = `http://localhost:${httpPort}/`;
		await open.goto(`http://127.0.0.1:${httpPort}/?server=${encodeURIComponent(offered)}`);
		await open.waitForSelector("#serverOffer", { timeout: 60_000 })
			.catch(() => fail("a link that offers a relay did not ask"));
		if (new URL(open.url()).searchParams.has("server")) fail("the server offer stayed in the address");
		await open.click(use ? "#serverOfferUse" : "#serverOfferKeep");
		await open.click("#sessionUseLocal", { timeout: 60_000 });
		await open.waitForSelector("#settingsBtn", { timeout: 60_000 });
		await open.click("#settingsBtn");
		await open.click("#connectionTab");
		await open.click("#serverChange");
		const kept = await open.inputValue("#serverAddress");
		if (kept !== (use ? offered : "")) {
			fail(`answering ${use ? "use" : "not now"} left the relay at ${JSON.stringify(kept)}`);
		}
		await open.keyboard.press("Escape");
		// Only a server this browser chose can be removed, and removing it
		// returns the page to the server it came from.
		if (!use) {
			if (await open.isVisible("#serverRemove")) fail("the page's own server offered to be removed");
		} else {
			await open.click("#serverRemove");
			await Promise.all([open.waitForEvent("load"), open.click("#serverRemoveCommit")]);
			await open.waitForSelector("#settingsBtn", { timeout: 60_000 })
				.catch(() => fail("removing the chosen server kept the reloaded page from opening"));
			await open.click("#settingsBtn");
			await open.click("#connectionTab");
			const name = await open.textContent("#serverName");
			if (name !== `127.0.0.1:${httpPort}`) fail(`removing the chosen server left ${JSON.stringify(name)}`);
			if (await open.isVisible("#serverRemove")) fail("the page's own server offered to be removed");
		}
		await linked.close();
	}
}
