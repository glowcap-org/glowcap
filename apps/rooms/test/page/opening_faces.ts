// What the opening screen says when the page cannot become a room: scripting
// off, a bundle that never arrived, an address that is not a secure context,
// a relay that refuses this browser, and a bundle that ran but could not open
// its session.

import type { Browser } from "playwright";
import { fail } from "../support/fail.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { parseLocator } from "@glowcap/runtime";
import { formatRoomsSturdyref, loopbackTcpDesignator } from "../../lib/locator.ts";
import { saveAndReload } from "../../lib/text/controls.ts";
import { joinNeedsAddress } from "../../lib/text/join.ts";
import {
	serverAskFor,
	serverNeedAddress,
	serverNeedHome,
	sessionDidNotOpen,
	sessionServerNone,
	sessionServerSaveAttach,
} from "../../lib/text/session.ts";
import {
	serverAwayRefuses,
	serverConnected,
	serverTestAnswers,
	serverTestRefuses,
	serverTurnsAway,
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

	// A link that offers a shared session opens session choice with it filled
	// in, and takes it out of the address before anything else can read it.
	// Attach is the answer, so the link attaches nothing by itself.
	{
		const linked = await browser.newContext();
		const open = await linked.newPage();
		const capability = "ocapn://offered.example/s/workspace";
		await open.goto(`http://127.0.0.1:${httpPort}/#attach=${encodeURIComponent(capability)}`);
		await open.waitForSelector("#sessionSetupCapability", { timeout: 60_000 })
			.catch(() => fail("a link that offers a shared session did not open session choice"));
		if (new URL(open.url()).hash !== "") fail("the session offer stayed in the address");
		const filled = await open.inputValue("#sessionSetupCapability");
		if (filled !== capability) fail(`the offered session filled ${JSON.stringify(filled)}`);
		await linked.close();
	}

	// A static page names no server under the session choices, and Attach asks
	// for one first. The page here is this server's own, marked the way the
	// static export marks it, so its server answers from the same origin.
	// Saving the server attaches with the link still filled in.
	{
		const bare = await browser.newContext();
		const open = await bare.newPage();
		await open.route(`http://127.0.0.1:${httpPort}/`, async (route) => {
			const served = await route.fetch();
			const page = (await served.text()).replace("<head>", '<head><meta name="rooms-host" content="static" />');
			await route.fulfill({ response: served, body: page });
		});
		await open.goto(`http://127.0.0.1:${httpPort}/`);
		await open.waitForSelector("#sessionServer", { timeout: 60_000 })
			.catch(() => fail("session choice did not name its Rooms server"));
		if (!((await open.textContent("#sessionServer")) ?? "").includes(sessionServerNone)) {
			fail(
				`a static page's server line did not say it has none: ${
					JSON.stringify(await open.textContent("#sessionServer"))
				}`,
			);
		}
		// A session link behind a door only a Rooms server opens.
		const capability = formatRoomsSturdyref(parseLocator("ocapn://offered.example.tcp"), "workspace");
		await open.fill("#sessionSetupCapability", capability);
		await open.click("#sessionAttach");
		await open.waitForSelector("#serverAddress", { timeout: 30_000 })
			.catch(() => fail("Attach with no Rooms server did not ask for one"));
		if ((await open.textContent("#serverSave")) !== sessionServerSaveAttach) {
			fail(
				`the server dialog over Attach did not say saving attaches: ${
					JSON.stringify(await open.textContent("#serverSave"))
				}`,
			);
		}
		await open.fill("#serverAddress", `http://127.0.0.1:${httpPort}/`);
		await open.press("#serverAddress", "Enter");
		await open.waitForSelector("#serverTestSaid", { timeout: 30_000 });
		await open.press("#serverAddress", "Enter");
		await open.waitForSelector("#serverAddress", { state: "detached", timeout: 30_000 })
			.catch(() => fail("saving the server did not close its dialog"));
		if ((await open.textContent("#sessionServerName")) !== `127.0.0.1:${httpPort}`) {
			fail("the saved server was not named under the session choices");
		}
		if ((await open.inputValue("#sessionSetupCapability")) !== capability) {
			fail("choosing a server lost the session link");
		}
		// The attach ran: this link names no reachable session, so it is refused
		// under its own field rather than asking for a server again.
		await open.waitForSelector("#sessionSetupCapability[aria-invalid='true']", { timeout: 45_000 })
			.catch(() => fail("saving the server did not go on to attach"));
		await bare.close();
	}

	// A blank address on a static page with no Rooms server is refused on its
	// own field, because the field is what the reader fills, and no server is
	// asked for. Connecting to a directory address this browser cannot open on
	// its own asks for one in place, the way Attach does, saying what for, and
	// says nothing under the join form. Saving the server reloads the page at
	// that act, with the address still named.
	{
		const bare = await browser.newContext();
		const open = await bare.newPage();
		await open.route(`http://127.0.0.1:${httpPort}/**`, async (route) => {
			if (route.request().resourceType() !== "document") return route.fallback();
			const served = await route.fetch();
			const page = (await served.text()).replace("<head>", '<head><meta name="rooms-host" content="static" />');
			await route.fulfill({ response: served, body: page });
		});
		await open.goto(`http://127.0.0.1:${httpPort}/`);
		await establishLocalSession(open);
		await open.fill("#nick", "asker");
		await open.click("#joinBtn");
		await open.waitForFunction(
			(said) => document.querySelector("#joinError .said-clamp")?.textContent === said,
			joinNeedsAddress,
			{ timeout: 10_000 },
		).catch(async () =>
			fail(
				`a blank address was not refused on its field: ${
					JSON.stringify(await open.textContent("#joinError .said-clamp").catch(() => null))
				}`,
			)
		);
		if (await open.locator("#serverAddress").count() !== 0) fail("a blank address asked for a Rooms server");
		const elsewhere = loopbackTcpDesignator(httpPort);
		await open.fill("#locator", elsewhere);
		await open.click("#joinBtn");
		await open.waitForSelector("#serverAddress", { timeout: 30_000 })
			.catch(() => fail("connecting through a Rooms server the page has none of did not ask for one"));
		await open.getByText(serverAskFor(serverNeedAddress), { exact: true }).waitFor({ timeout: 5_000 })
			.catch(() => fail("the server ask did not say what the address needs a server for"));
		if ((await open.textContent("#serverSave")) !== saveAndReload) {
			fail(`the server ask did not say saving reloads: ${JSON.stringify(await open.textContent("#serverSave"))}`);
		}
		if (await open.locator("#joinError").count() !== 0) {
			fail(
				`the join form said a failure the ask already answers: ${
					JSON.stringify(await open.textContent("#joinError"))
				}`,
			);
		}
		await open.fill("#serverAddress", `http://127.0.0.1:${httpPort}/`);
		await open.press("#serverAddress", "Enter");
		await open.waitForSelector("#serverTestSaid", { timeout: 30_000 });
		await Promise.all([
			open.waitForNavigation({ waitUntil: "domcontentloaded", timeout: 30_000 })
				.catch(() => fail("saving the server did not reload the page")),
			open.press("#serverAddress", "Enter"),
		]);
		const landed = new URL(open.url());
		if (landed.pathname !== "/join" || landed.searchParams.get("locator") !== elsewhere) {
			fail(`the reload did not land on the act that asked: ${landed.pathname}${landed.search}`);
		}
		await open.waitForSelector("#locator", { timeout: 60_000 })
			.catch(() => fail("the join form did not come back after the reload"));
		if ((await open.inputValue("#locator")) !== elsewhere) fail("the reload lost the address being reached");
		await bare.close();
	}

	// A direct-message or directory address opened on a static page with no
	// Rooms server asks for one instead of waiting for a directory that never
	// comes, says that a name alone or a blank address means the home directory
	// the page has none of, and saving the server reloads the page at that same
	// address.
	for (const path of ["/dm/alice", "/directory"]) {
		const bare = await browser.newContext();
		const open = await bare.newPage();
		await open.route(`http://127.0.0.1:${httpPort}/**`, async (route) => {
			if (route.request().resourceType() !== "document") return route.fallback();
			const served = await route.fetch();
			const page = (await served.text()).replace("<head>", '<head><meta name="rooms-host" content="static" />');
			await route.fulfill({ response: served, body: page });
		});
		await open.goto(`http://127.0.0.1:${httpPort}${path}`);
		await establishLocalSession(open);
		await open.waitForSelector("#serverAddress", { timeout: 30_000 })
			.catch(() => fail(`opening ${path} with no Rooms server did not ask for one`));
		await open.getByText(serverAskFor(serverNeedHome), { exact: true }).waitFor({ timeout: 5_000 })
			.catch(() => fail(`the server ask over ${path} did not say what it needs a server for`));
		await open.fill("#serverAddress", `http://127.0.0.1:${httpPort}/`);
		await open.press("#serverAddress", "Enter");
		await open.waitForSelector("#serverTestSaid", { timeout: 30_000 });
		await Promise.all([
			open.waitForNavigation({ waitUntil: "domcontentloaded", timeout: 30_000 })
				.catch(() => fail("saving the server did not reload the page")),
			open.press("#serverAddress", "Enter"),
		]);
		if (new URL(open.url()).pathname !== path) {
			fail(`the reload did not land on the address that asked: ${new URL(open.url()).pathname}`);
		}
		await bare.close();
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
