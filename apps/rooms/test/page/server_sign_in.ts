// The server's own page uses its browser login for directory and preview reads.
import type { Browser } from "playwright";
import { fail } from "../support/fail.ts";
import { establishLocalSession } from "../support/session_setup.ts";

export async function proveSignedInPage(browser: Browser, httpPort: number): Promise<void> {
	const context = await browser.newContext();
	try {
		const page = await context.newPage();
		const base = `http://127.0.0.1:${httpPort}/`;
		const signIn = new URL("sign-in", base);
		const cookie = "rooms_test_login=confirmed";
		let readLocator = false;
		let readPreview = false;
		const target = "https://signed-in.example/article";
		await context.route(`${base}**`, async (route) => {
			const request = route.request();
			if (request.url() === signIn.href) {
				return route.fulfill({ body: "Signed in", headers: { "set-cookie": `${cookie}; Path=/; HttpOnly` } });
			}
			const sent = (await request.allHeaders()).cookie?.split("; ").includes(cookie);
			if (!sent) {
				return route.fulfill({ status: 401, contentType: "text/html", body: '<a href="/sign-in">Sign in</a>' });
			}
			const address = new URL(request.url());
			if (address.pathname === "/locator") readLocator = true;
			if (address.pathname === "/link-preview" && address.searchParams.get("url") === target) {
				readPreview = true;
				return route.fulfill({
					contentType: "application/json",
					body: JSON.stringify({
						ok: true,
						metadata: { requestedUrl: target, title: "Signed-in preview", images: [] },
					}),
				});
			}
			return route.continue();
		});
		const anonymous = await page.goto(base);
		if (anonymous?.status() !== 401) fail("the protected Rooms page skipped sign-in");
		await page.getByRole("link", { name: "Sign in" }).click();
		await page.waitForURL(signIn.href);
		await page.goto(base);
		await establishLocalSession(page);
		await page.fill("#nick", "signed-in");
		await page.fill("#room", "signed-in-room");
		await page.click("#joinBtn");
		await page.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
		if (!readLocator) fail("the Rooms page never read its directory with the browser login");
		await page.fill("#line", target);
		await page.locator(".draft-link-previews .link-preview-card.ready").waitFor({ timeout: 10_000 });
		if (!readPreview) fail("the Rooms page never read its preview with the browser login");
	} finally {
		await context.close();
	}
}
