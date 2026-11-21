// Opening failures: missing scripting, an unavailable bundle, an insecure origin, or a session that cannot open.
import type { Browser } from "playwright";
import { fail } from "../support/fail.ts";
import { sessionDidNotOpen } from "../../lib/text/session.ts";

export async function proveUnavailablePage(browser: Browser, httpPort: number): Promise<void> {
	// Disabled scripting and a missing bundle each leave an explanation.
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
}

export async function proveSessionOpenFailure(browser: Browser, httpPort: number): Promise<void> {
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
