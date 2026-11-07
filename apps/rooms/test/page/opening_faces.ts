// What the opening screen says when the page cannot become a room: scripting
// off, a bundle that never arrived, an address that is not a secure context,
// a relay that refuses this browser, and a bundle that ran but could not open
// its session.

import type { Browser } from "playwright";
import { fail } from "../support/fail.ts";
import { sessionDidNotOpen } from "../../lib/text/session.ts";
import {
	serverAwayRefuses,
	serverConnected,
	serverTestAnswers,
	serverTestRefuses,
	serverTurnsAway,
	settingsBrowserUnreachable,
	settingsRelayAway,
} from "../../lib/text/settings.ts";

export async function proveOpeningFaces(browser: Browser, httpPort: number): Promise<void> {
	// The other two: a browser with scripting off is told why there is nothing
	// here, and so is one whose bundle never arrived, the case nobody sees until
	// it happens to them.
	{
		const off = await browser.newContext({ javaScriptEnabled: false });
		const quiet = await off.newPage();
		await quiet.goto(`http://127.0.0.1:${httpPort}/`);
		if (!await quiet.locator(".boot-explain").isVisible()) {
			fail("a browser with scripting off is not told why the page is empty");
		}
		if (await quiet.locator(".boot-wait").isVisible()) {
			fail("a browser with scripting off is shown a wait that will never end");
		}
		await off.close();

		const dark = await browser.newContext();
		const blind = await dark.newPage();
		await blind.route("**/page.js", (route) => route.fulfill({ status: 503, body: "" }));
		await blind.goto(`http://127.0.0.1:${httpPort}/`);
		if (!await blind.locator(".boot-explain").isVisible()) {
			fail("a page whose bundle did not load shows a reader nothing at all");
		}
		await dark.close();
	}

	// A browser peer must arrive intact. Plain HTTP on another machine cannot
	// promise that, and its origin is not a secure context. Refuse before loading
	// the application bundle, with the development paths that preserve the
	// boundary instead of letting the first restricted API supply the diagnosis.
	{
		const plainHttp = await browser.newContext();
		const lan = await plainHttp.newPage();
		let bundleAsked = false;
		lan.on("request", (request) => {
			if (new URL(request.url()).pathname === "/page.js") bundleAsked = true;
		});
		const address = Deno.networkInterfaces().find((entry) =>
			entry.family === "IPv4" && !entry.address.startsWith("127.")
		)?.address;
		if (address === undefined) fail("the secure-origin proof found no non-loopback interface");
		await lan.goto(`http://${address}:${httpPort}/`);
		if (await lan.evaluate(() => isSecureContext)) {
			fail("the secure-origin proof reached a trustworthy context over network HTTP");
		}
		if (!await lan.locator(".boot-insecure").isVisible()) {
			fail("plain network HTTP did not explain the secure-origin requirement");
		}
		const explanation = (await lan.locator(".boot-insecure").textContent()) ?? "";
		if (!explanation.includes("localhost") || !explanation.includes("HTTPS")) {
			fail("the secure-origin refusal did not give either development path");
		}
		if (bundleAsked) fail("an insecure page loaded the Rooms peer bundle before refusing");
		await plainHttp.close();
	}

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
		await open.click("#reachabilityTab");
		const said = await open.waitForSelector("#relayAway .said-clamp", { timeout: 30_000 })
			.catch(() => fail("Settings did not say that a refused relay leaves this browser unreachable"));
		if ((await said.textContent()) !== settingsRelayAway(`127.0.0.1:${httpPort}`, `http://127.0.0.1:${httpPort}`)) {
			fail(
				`the unreachable relay was not described in the catalog's words: ${
					JSON.stringify(await said.textContent())
				}`,
			);
		}
		// The address a reader would hand out says it leads nowhere while the relay is away.
		if ((await open.textContent("#selfUnreachable .said-clamp")) !== settingsBrowserUnreachable) {
			fail(
				`the browser's address did not say it is unreachable: ${
					JSON.stringify(await open.textContent("#selfUnreachable"))
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
		await open.click("#reachabilityTab");
		// The card names the chosen server and the WebSockets that one address
		// means, read from the front the session dials through.
		const shown = {
			name: await open.textContent("#serverName"),
			relay: await open.textContent("#serverRelay"),
			register: await open.textContent("#serverRegister"),
		};
		const expected = {
			name: `localhost:${httpPort}`,
			relay: `ws://localhost:${httpPort}/relay`,
			register: `ws://localhost:${httpPort}/register`,
		};
		if (JSON.stringify(shown) !== JSON.stringify(expected)) {
			fail(`the server card did not show the chosen server: ${JSON.stringify(shown)}`);
		}
		// The card asks the server the question Test does, so it names the one
		// cause and its fix rather than both possibilities.
		const refusal = serverAwayRefuses(`http://127.0.0.1:${httpPort}`);
		await open.waitForFunction(
			(text) => document.querySelector("#relayAway")?.textContent?.includes(text) ?? false,
			refusal,
			{ timeout: 30_000 },
		).catch(async () =>
			fail(`the card did not name the refusal: ${JSON.stringify(await open.textContent("#relayAway"))}`)
		);
		if ((await open.textContent("#serverConnection")) !== serverTurnsAway) {
			fail(`the card's chip said ${JSON.stringify(await open.textContent("#serverConnection"))}`);
		}
		await open.click("#serverChange");
		if (await open.inputValue("#serverAddress") !== away) {
			fail("the reloaded page did not keep the server it was sent to");
		}
		// Only a change that answered Test is saved. A refusal names the flag
		// that lets this page in and leaves Save off.
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
		if (!(await tested.textContent())?.includes(serverTestRefuses(`http://127.0.0.1:${httpPort}`))) {
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
		await open.click("#reachabilityTab");
		await open.waitForFunction(
			(said) => document.querySelector("#serverConnection")?.textContent === said,
			serverConnected,
			{ timeout: 30_000 },
		).catch(async () =>
			fail(`the saved server did not connect: ${JSON.stringify(await open.textContent("#serverConnection"))}`)
		);
		await elsewhere.close();
	}

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
		await open.click("#reachabilityTab");
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
			await open.click("#reachabilityTab");
			const name = await open.textContent("#serverName");
			if (name !== `127.0.0.1:${httpPort}`) fail(`removing the chosen server left ${JSON.stringify(name)}`);
			if (await open.isVisible("#serverRemove")) fail("the page's own server offered to be removed");
		}
		await linked.close();
	}

	// A bundle that ran and could not open says why, never that scripting is
	// off, and its one action returns to session setup: a reload would retry the
	// same remembered choice. A relay that never answers leaves the open intact,
	// so the session's own interface failing to load stands in for a failure
	// Rooms cannot name.
	{
		const refused = await browser.newContext();
		const stuck = await refused.newPage();
		await stuck.route("**/established-*.js", (route) => route.fulfill({ status: 503, body: "" }));
		await stuck.goto(`http://127.0.0.1:${httpPort}/`);
		await stuck.click("#sessionUseLocal", { timeout: 60_000 });
		// The document's state, not the element: before the stylesheet arrives
		// every face is laid out.
		await stuck.waitForSelector(':root[data-boot="failed"] .boot-failed', { state: "visible", timeout: 30_000 })
			.catch(() => fail("a session that could not open left no account of why"));
		if (await stuck.locator(".boot-explain").isVisible()) {
			fail("a page whose bundle ran blamed scripting for a failed open");
		}
		if ((await stuck.locator(".boot-failed-why").textContent()) !== sessionDidNotOpen) {
			fail("the failed-open screen did not give a person its plain account and next step");
		}
		await stuck.click(".boot-setup");
		await stuck.waitForSelector("#sessionSetup", { timeout: 30_000 })
			.catch(() => fail("the failed-open action did not return to session setup"));
		await refused.close();
	}
}
