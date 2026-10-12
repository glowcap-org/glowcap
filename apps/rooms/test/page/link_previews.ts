// Link previews as somebody actually meets them: inside the composer and a
// delivered message, with the real React state machine and Rooms controls.
// Metadata transport is intercepted so this proof is hermetic. The Rust
// service separately proves provider selection, bounds, and SSRF policy.

import type { Browser, Page, Route } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { fail } from "./harness.ts";

const VIDEO = "https://youtu.be/NdU6UdUKaYc?si=v9JTLhkE5if3tpCq";
const RETRY = "https://writingcooperative.com/a-quick-guide-to-medium-9f61864ab26";
const REFUSED = "https://refused.example/story";
const BROKEN_IMAGE = "https://image.example/story";

function metadata(url: string, values: Record<string, unknown>) {
	return {
		ok: true,
		metadata: { requestedUrl: url, url, images: [], ...values },
	};
}

function refusal() {
	return {
		ok: false,
		failure: {
			code: "link-preview-http-refused",
			summary: "That site refused the preview request.",
			action: "The link still works as written; retry if the site changes.",
			retry: "after-state-change",
		},
	};
}

async function answer(route: Route, value: unknown, status = 200): Promise<void> {
	await route.fulfill({
		status,
		contentType: "application/json; charset=utf-8",
		body: JSON.stringify(value),
	});
}

async function join(browser: Browser, httpPort: number): Promise<Page> {
	const page = await (await browser.newContext({ viewport: { width: 1080, height: 760 } })).newPage();
	page.on("pageerror", (error) => console.error("  [link-preview page error]", error.message));
	page.on("console", (message) => {
		if (message.type() === "error" || message.type() === "warning") {
			console.error(`  [link-preview console.${message.type()}]`, message.text());
		}
	});
	await page.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(page);
	await page.fill("#nick", "preview-reader");
	await page.fill("#room", "preview-lab");
	await page.click("#joinBtn");
	await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("the link-preview reader did not join"));
	return page;
}

export async function run(browser: Browser, httpPort: number): Promise<void> {
	const page = await join(browser, httpPort);
	let retryRequests = 0;
	let retryRefreshed = false;
	try {
		await page.route("**/link-preview/image?*", async (route) => {
			const target = new URL(route.request().url()).searchParams.get("url");
			if (target?.includes("broken.jpg")) {
				await route.abort("failed");
				return;
			}
			await route.fulfill({
				status: 200,
				contentType: "image/svg+xml",
				body:
					'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 360"><defs><linearGradient id="g"><stop stop-color="#d99b37"/><stop offset="1" stop-color="#3c7775"/></linearGradient></defs><rect width="480" height="360" fill="url(#g)"/><circle cx="240" cy="180" r="52" fill="#fff" fill-opacity=".9"/><path d="m225 145 55 35-55 35z" fill="#553b2e"/></svg>',
			});
		});
		await page.route("**/link-preview?*", async (route) => {
			const target = new URL(route.request().url()).searchParams.get("url") ?? "";
			if (target === VIDEO) {
				await answer(
					route,
					metadata(target, {
						title: "Scott Galloway: The Rich Are Quietly Preparing For The AI Collapse",
						siteName: "YouTube",
						objectType: "video",
						images: [{ url: "https://i.example/video.jpg", width: 480, height: 360 }],
					}),
				);
			} else if (target === RETRY && ++retryRequests > 1) {
				retryRefreshed = new URL(route.request().url()).searchParams.get("refresh") === "1";
				await answer(route, metadata(target, { title: "A Quick Guide to Medium", siteName: "Medium" }));
			} else if (target === BROKEN_IMAGE) {
				await answer(
					route,
					metadata(target, {
						title: "The article survives its image",
						siteName: "Example",
						images: [{ url: "https://i.example/broken.jpg", width: 640, height: 360 }],
					}),
				);
			} else {
				await answer(route, refusal(), 502);
			}
		});

		// Ready is a composed card, not a loose thumbnail and text. The image is
		// on the reading edge, and the remove action is the shared icon control.
		await page.fill("#line", VIDEO);
		const ready = page.locator(".draft-link-previews .link-preview-card.ready");
		await ready.waitFor({ timeout: 10_000 });
		await ready.locator("img").waitFor({ timeout: 10_000 });
		const geometry = await ready.evaluate((card) => {
			const box = (node: Element) => node.getBoundingClientRect();
			const copy = card.querySelector(".link-preview-copy")!;
			const image = card.querySelector("img")!;
			const remove = card.querySelector(".link-preview-remove")!;
			return { card: box(card), copy: box(copy), image: box(image), remove: box(remove) };
		});
		if (geometry.copy.right > geometry.image.left || geometry.image.right > geometry.card.right + 1) {
			fail(`preview copy and image are not aligned: ${JSON.stringify(geometry)}`);
		}
		if (
			geometry.remove.left < geometry.card.left || geometry.remove.right > geometry.card.right + 1 ||
			geometry.remove.width < 26 || geometry.remove.height < 26
		) {
			fail(`the preview remove action is misplaced or undersized: ${JSON.stringify(geometry.remove)}`);
		}
		const removeControl = ready.locator("button.link-preview-remove.icon-button[data-variant=solid]");
		if (await removeControl.count() !== 1) fail("the preview remove action bypassed the shared icon control");

		const capture = Deno.env.get("GLOWCAP_ROOMS_LINK_PREVIEW_CAPTURE");
		if (capture) {
			await page.evaluate(() => document.documentElement.dataset.theme = "light");
			await page.locator(".composer").screenshot({ path: `${capture}/link-preview-light.png` });
			await page.evaluate(() => document.documentElement.dataset.theme = "dark");
			await page.locator(".composer").screenshot({ path: `${capture}/link-preview-dark.png` });
			await page.evaluate(() => document.documentElement.dataset.theme = "light");
		}
		await page.press("#line", "Enter");
		const videoMessage = page.locator(".bubble", { hasText: VIDEO }).last();
		await videoMessage.locator(".message-link-previews .link-preview-card.ready").waitFor({ timeout: 10_000 });
		if (await videoMessage.locator(".link-preview-remove").count() !== 0) {
			fail("a delivered preview kept the draft-only remove action");
		}
		if (capture) {
			await videoMessage.screenshot({ path: `${capture}/link-preview-message-light.png` });
		}

		// A refusal preserves the draft intent and offers an explicit retry. Both
		// actions come from the design system, and retry reconciles the same card
		// to the successful attempt instead of creating a sibling.
		await page.fill("#line", RETRY);
		const failed = page.locator(".draft-link-previews .link-preview-card.failed");
		await failed.waitFor({ timeout: 10_000 });
		const retry = failed.locator("button.link-preview-retry.button[data-variant=quiet]");
		if (await retry.count() !== 1) fail("preview retry bypassed the shared text button");
		if (await failed.locator("button.link-preview-remove.icon-button").count() !== 1) {
			fail("a failed preview lost the shared remove action");
		}
		if (capture) await page.locator(".composer").screenshot({ path: `${capture}/link-preview-failure.png` });
		await retry.click();
		await failed.waitFor({ state: "detached", timeout: 10_000 });
		await page.locator(".draft-link-previews .link-preview-card.ready").waitFor({ timeout: 10_000 });
		if (!retryRefreshed) fail("an explicit preview retry reused the cached outcome");

		// The image proxy has its own failure boundary. Losing an optional image
		// removes the image track too, leaving no blank column beside useful copy.
		await page.fill("#line", BROKEN_IMAGE);
		const broken = page.locator(".draft-link-previews .link-preview-card.ready");
		await broken.waitFor({ timeout: 10_000 });
		await broken.locator("img").waitFor({ state: "detached", timeout: 10_000 });
		const tracks = await broken.locator("a").evaluate((link) =>
			getComputedStyle(link).gridTemplateColumns.split(" ")
		);
		if (tracks.length !== 1) fail(`a failed preview image left ${tracks.length} layout tracks behind`);

		// Once sent, the authored link is the fallback. A reader-side refusal
		// draws neither an error card nor the wrapper's otherwise empty margin.
		await page.fill("#line", REFUSED);
		await failed.waitFor({ timeout: 10_000 });
		await page.press("#line", "Enter");
		const delivered = page.locator(".bubble", { hasText: REFUSED }).last();
		await delivered.waitFor({ timeout: 10_000 });
		await delivered.locator(".link-preview-card.loading").waitFor({ state: "detached", timeout: 10_000 });
		if (await delivered.locator(".link-preview-card.failed, .link-preview-retry").count() !== 0) {
			fail("a delivered link refusal became a persistent error card");
		}
		const wrapperDisplay = await delivered.locator(".message-link-previews").evaluate((wrapper) =>
			getComputedStyle(wrapper).display
		);
		if (wrapperDisplay !== "none") fail("a refused delivered preview reserved an empty line in the message");
	} finally {
		await page.context().close();
	}
}
