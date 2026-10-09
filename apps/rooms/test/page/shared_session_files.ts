// Files sent through a shared session, and the reloads that follow them.
//
// The image proves the ordinary path: bytes render in both views, and a
// reload draws them again from the session's archive. The large file proves
// the path a tab takes when it reloads while its file is still being taken:
// the posted line stands, the file it can no longer supply is given back, and
// the session loads again with its history and nothing left for a reader to
// decide.

import type { Page } from "playwright";
import { Buffer } from "node:buffer";
import { fail } from "./harness.ts";

/** What a reloaded page shows when it did not come back, read where it stalled. */
async function stalledState(page: Page): Promise<string> {
	const state = await page.evaluate(() => ({
		path: location.pathname,
		boot: document.getElementById("boot")?.textContent ?? null,
		notices: [...document.querySelectorAll(".toast, .sys, .session-effect-notice")].map((row) => row.textContent),
	}));
	return JSON.stringify(state);
}

/** Reload `page` and wait until its composer is usable again. */
async function reloadIntoSession(page: Page, what: string): Promise<void> {
	await page.reload();
	await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await page.waitForSelector("#line:not([disabled])", { timeout: 30_000 }).catch(async () =>
		fail(`the attached session did not load again after ${what}: ${await stalledState(page)}`)
	);
}

/** Send a tiny image from `first`, see it drawn in both views, and again after a reload. */
export async function proveSharedImage(first: Page, second: Page, png: Uint8Array): Promise<void> {
	await first.setInputFiles("#filePick", {
		name: "shared-session.png",
		mimeType: "image/png",
		buffer: Buffer.from(png),
	});
	await first.waitForSelector('.composer-file:has-text("shared-session.png")');
	await first.click("#sendBtn");
	for (const [index, page] of [first, second].entries()) {
		await page.waitForFunction(
			() => {
				const image = [...document.querySelectorAll<HTMLImageElement>(".bubble .attach-image img")]
					.find((candidate) => candidate.alt === "shared-session.png");
				return image?.src.startsWith("blob:") === true && image.naturalWidth === 4 && image.naturalHeight === 2;
			},
			undefined,
			{ timeout: 20_000 },
		).catch(async () => {
			const state = await page.evaluate(() => ({
				text: document.body.innerText,
				attachments: [...document.querySelectorAll(".bubble .attach")].map((row) => row.outerHTML),
			}));
			fail(`shared-session image did not render in view ${index + 1}: ${JSON.stringify(state)}`);
		});
	}
	await reloadIntoSession(first, "a sent image");
	await first.waitForFunction(
		() =>
			[...document.querySelectorAll<HTMLImageElement>(".bubble .attach-image img")]
				.some((image) => image.alt === "shared-session.png" && image.naturalWidth === 4),
		undefined,
		{ timeout: 20_000 },
	).catch(() => fail("a reloaded attached view did not draw the sent image from history"));
}

/** Reload `first` while a file many chunks long is still being taken from it. */
export async function proveReloadMidUpload(first: Page, second: Page): Promise<void> {
	// Hold the second chunk at the real browser byte source. Reload destroys
	// that source while the session peer retains the admitted line and receipt.
	await first.evaluate(() => {
		const slice = File.prototype.slice;
		File.prototype.slice = function (start, end, type) {
			const chunk = slice.call(this, start, end, type);
			if (this.name === "shared-session-large.bin" && (start ?? 0) > 0) {
				chunk.arrayBuffer = () => {
					document.documentElement.dataset.uploadReadBlocked = "true";
					return new Promise<ArrayBuffer>(() => {});
				};
			}
			return chunk;
		};
	});
	await first.setInputFiles("#filePick", {
		name: "shared-session-large.bin",
		mimeType: "application/octet-stream",
		buffer: Buffer.from(new Uint8Array(8 * 1024 * 1024).map((_, at) => (at * 7) & 0xff)),
	});
	await first.waitForSelector('.composer-file:has-text("shared-session-large.bin")');
	await first.click("#sendBtn");
	// The sender paints before admission. Only the other view proves the
	// session process posted the line before its browser source disappears.
	await second.waitForSelector('.bubble:has-text("shared-session-large.bin")', { timeout: 30_000 })
		.catch(() => fail("a large shared file did not post to the other view"));
	await first.waitForFunction(() => document.documentElement.dataset.uploadReadBlocked === "true")
		.catch(() => fail("the real browser upload never reached its second chunk"));
	await reloadIntoSession(first, "a reload mid-upload");
	for (const page of [first, second]) {
		await page.waitForSelector('.bubble:has-text("shared-session-large.bin")', { timeout: 30_000 })
			.catch(() => fail("the line posted before the reload did not stay in both views"));
	}
	const undecided = await first.locator(".session-effect-notice").count();
	if (undecided !== 0) {
		fail("a file lost with its tab left a session operation waiting on a decision");
	}
}
