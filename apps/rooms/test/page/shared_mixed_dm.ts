// Shared-session to ordinary-browser direct messaging, both directions.

import { Buffer } from "node:buffer";
import type { Browser, Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { awaitBubble, fail, openDmTo } from "./harness.ts";
import { namedDirectRow } from "../support/conversation_row.ts";

export async function proveSharedMixedDirect(
	browser: Browser,
	httpPort: number,
	attached: readonly [Page, Page],
	png: Uint8Array,
	ordinaryOrigin = `http://127.0.0.1:${httpPort}`,
): Promise<void> {
	const [first] = attached;
	const context = await browser.newContext();
	await context.addCookies([{ name: "proof_login", value: "yes", url: ordinaryOrigin }]);
	const ordinary = await context.newPage();
	ordinary.on("pageerror", (error) => console.error(`ORDINARY-PAGE-ERROR: ${error.message}`));
	ordinary.on("console", (message) => {
		if (message.type() === "error" || message.type() === "warning") {
			console.error(`ORDINARY-CONSOLE-${message.type()}: ${message.text()}`);
		}
	});
	await ordinary.goto(`${ordinaryOrigin}/`);
	await establishLocalSession(ordinary);
	await ordinary.fill("#nick", "ordinary-member");
	await ordinary.fill("#room", "mirror-two");
	await ordinary.click("#joinBtn");
	await ordinary.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const state = await ordinary.evaluate(() => ({
			join: document.getElementById("joinForm")?.textContent ?? null,
			composer: document.getElementById("composerAvailability")?.textContent?.trim() ?? null,
		}));
		fail(`the ordinary browser did not join before the mixed DM: ${JSON.stringify(state)}`);
	});
	await openDmTo(first, "ordinary-member").catch(async (error) => {
		const members = await first.locator("#members").textContent();
		fail(`the shared member could not open the ordinary browser DM: ${error}; members=${members}`);
	});
	await first.waitForFunction(
		() => document.getElementById("roomName")?.textContent?.trim() === "ordinary-member",
		undefined,
		{ timeout: 30_000 },
	).catch(async () =>
		fail(`the mixed DM did not select its conversation: ${await first.locator("body").innerText()}`)
	);
	await first.fill("#line", "shared member opened the mixed browser line");
	await first.click("#sendBtn");
	await openDmTo(ordinary, "durable-member");
	await awaitBubble(ordinary, "shared member opened the mixed browser line", "ordinary browser");
	// Both attached views must have consumed the durable conversation feed
	// before testing a transient typing notice from the ordinary browser.
	for (const page of attached) {
		await awaitBubble(page, "shared member opened the mixed browser line", "attached browser");
	}
	await ordinary.type("#line", "ordinary typing");
	await Promise.all(
		attached.map((page, index) =>
			typingShown(page, "ordinary-member", `ordinary typing did not reach attached browser ${index + 1}`).catch(
				async (error) => {
					console.error(
						"MIXED-TYPING-VIEWS",
						await Promise.all([...attached, ordinary].map((view) => view.locator("body").innerText())),
					);
					throw error;
				},
			)
		),
	);
	await ordinary.fill("#line", "");
	await first.type("#line", "shared typing");
	await typingShown(ordinary, "durable-member", "shared typing did not reach the ordinary browser");
	await first.fill("#line", "");
	await ordinary.fill("#line", "ordinary browser replied to the shared member");
	await ordinary.press("#line", "Enter");
	for (const page of attached) {
		await awaitBubble(page, "ordinary browser replied to the shared member", "attached browser");
	}
	await first.setInputFiles("#filePick", {
		name: "shared-to-ordinary.png",
		mimeType: "image/png",
		buffer: Buffer.from(png),
	});
	await first.click("#sendBtn");
	await renderedImage(ordinary, "shared-to-ordinary.png", "the ordinary browser received an empty image");
	await ordinary.setInputFiles("#filePick", {
		name: "ordinary-to-shared.png",
		mimeType: "image/png",
		buffer: Buffer.from(png),
	});
	await ordinary.click("#sendBtn");
	for (const page of attached) {
		await renderedImage(page, "ordinary-to-shared.png", "an attached browser received an empty image");
	}
	await context.close();
	for (const page of attached) {
		await namedDirectRow(page, "ordinary-member").locator(".closed-mark").waitFor({ timeout: 30_000 })
			.catch(() => fail("the disconnected browser's DM did not close automatically"));
		if (await page.locator("#line").isEnabled()) fail("the closed DM still permits sending");
		await awaitBubble(page, "ordinary browser replied to the shared member", "closed attached browser");
	}
}

async function typingShown(page: Page, name: string, refusal: string): Promise<void> {
	await page.waitForFunction(
		(name) => {
			const typing = document.getElementById("typing");
			return typing?.classList.contains("show") === true && (typing.textContent ?? "").includes(name);
		},
		name,
		{ timeout: 30_000 },
	).catch(() => fail(refusal));
}

async function renderedImage(page: Page, name: string, refusal: string): Promise<void> {
	await page.waitForFunction(
		(name) => {
			const image = [...document.querySelectorAll<HTMLImageElement>(".bubble .attach-image img")]
				.find((candidate) => candidate.alt === name);
			return image?.src.startsWith("blob:") === true && image.naturalWidth === 4 && image.naturalHeight === 2;
		},
		name,
		{ timeout: 30_000 },
	).catch(() => fail(refusal));
}
