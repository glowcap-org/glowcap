// A static Rooms page asks for a server when an attach or navigation needs one.
import type { Browser, Page } from "playwright";
import { fail } from "../support/fail.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { parseLocator } from "@glowcap/runtime";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { formatRoomsSturdyref } from "../support/sturdyref.ts";
import { saveAndReload } from "../../lib/text/controls.ts";
import { joinNeedsAddress } from "../../lib/text/join.ts";
import { PATH_OFFER } from "../../web/ui/page_base.ts";
import {
	serverAskFor,
	serverNeedAddress,
	serverNeedHome,
	sessionServerNone,
	sessionServerSaveAttach,
} from "../../lib/text/session.ts";

/** Serve this server's page to `open` the way a host that serves one file per
 * address serves the static export: marked static, and answering nothing below
 * the page's own address. A deep address reaches such a page under
 * `PATH_OFFER`, which is how that host's 404 page hands one over. */
async function asStaticHost(open: Page, httpPort: number): Promise<void> {
	await open.route(`http://127.0.0.1:${httpPort}/**`, async (route) => {
		if (route.request().resourceType() !== "document") return route.fallback();
		if (new URL(route.request().url()).pathname !== "/") {
			return route.fulfill({ status: 404, contentType: "text/plain", body: "no such file" });
		}
		const served = await route.fetch();
		const page = (await served.text()).replace("<head>", '<head><meta name="rooms-host" content="static" />');
		await route.fulfill({ response: served, body: page });
	});
}

export async function proveStaticServerSetup(browser: Browser, httpPort: number): Promise<void> {
	// A static page names no server under the session choices, and Attach asks
	// for one first. The page here is this server's own, served the way a static
	// host serves its export, so its server answers from the same origin.
	// Saving the server attaches with the link still filled in.
	{
		const bare = await browser.newContext();
		const open = await bare.newPage();
		await asStaticHost(open, httpPort);
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
		await asStaticHost(open, httpPort);
		await open.goto(`http://127.0.0.1:${httpPort}/`);
		await establishLocalSession(open);
		await open.fill("#nick", "asker");
		await open.click("#joinBtn");
		await open.waitForFunction(
			(said) => document.querySelector("#joinAddressFieldSaid .said-clamp")?.textContent === said,
			joinNeedsAddress,
			{ timeout: 10_000 },
		).catch(async () =>
			fail(
				`a blank address was not refused on its field: ${
					JSON.stringify(await open.textContent("#joinAddressFieldSaid .said-clamp").catch(() => null))
				}`,
			)
		);
		if (await open.locator("#serverAddress").count() !== 0) fail("a blank address asked for a Rooms server");
		const elsewhere = loopbackTcpDesignator(httpPort);
		await open.fill("#joinAddressField", elsewhere);
		await open.click("#joinBtn");
		await open.waitForSelector("#serverAddress", { timeout: 30_000 })
			.catch(() => fail("connecting through a Rooms server the page has none of did not ask for one"));
		await open.getByText(serverAskFor(serverNeedAddress), { exact: true }).waitFor({ timeout: 5_000 })
			.catch(() => fail("the server ask did not say what the address needs a server for"));
		if ((await open.textContent("#serverSave")) !== saveAndReload) {
			fail(`the server ask did not say saving reloads: ${JSON.stringify(await open.textContent("#serverSave"))}`);
		}
		if (await open.locator("#joinAddressFieldSaid").count() !== 0) {
			fail(
				`the join form said a failure the ask already answers: ${
					JSON.stringify(await open.textContent("#joinAddressFieldSaid"))
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
		await open.waitForFunction(() => location.pathname === "/join", undefined, { timeout: 30_000 })
			.catch(() => fail(`the reload did not land on the act that asked: ${open.url()}`));
		if (new URLSearchParams(new URL(open.url()).hash.slice(1)).get("address") !== elsewhere) {
			fail(`the reload lost the address in the act that asked: ${open.url()}`);
		}
		await open.waitForSelector("#joinAddressField", { timeout: 60_000 })
			.catch(() => fail("the join form did not come back after the reload"));
		if ((await open.inputValue("#joinAddressField")) !== elsewhere) {
			fail("the reload lost the address being reached");
		}
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
		await asStaticHost(open, httpPort);
		await open.goto(`http://127.0.0.1:${httpPort}/?${PATH_OFFER}=${encodeURIComponent(path.slice(1))}`);
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
		await open.waitForFunction((path) => location.pathname === path, path, { timeout: 30_000 })
			.catch(() => fail(`the reload did not land on the address that asked: ${open.url()}`));
		await bare.close();
	}
}
