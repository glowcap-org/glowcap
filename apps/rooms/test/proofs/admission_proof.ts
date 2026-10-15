// Shipped browser actions against a small, explicitly configured server budget.
// Cooldown preserves draft custody and never queues a future send.
import { type Browser, chromium, type Page } from "playwright";
import { Buffer } from "node:buffer";
import { spawnWeb } from "../support/web_front.ts";
import { reapOwned } from "../support/children.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { waitForFiniteAnimations } from "../support/animations.ts";
import {
	awaitBubble,
	confirmTitleLeave,
	fail,
	freePort,
	reachDirectoryOnCard,
	ROOT,
	say,
	waitForHttp,
} from "../page/harness.ts";

const port = freePort();
spawnWeb({
	args: [
		"--transport=tcp",
		"--admission-rates=message=1/6,room-join=1/6",
		"--http-admission-rates=preview=1/1",
		"--http-admission-aggregate-scale=1",
		String(port),
		String(freePort()),
	],
	cwd: ROOT,
	stdout: "null",
	stderr: "inherit",
});
const deadline = setTimeout(() => fail("browser admission proof timed out after 90s"), 90_000);
let browser: Browser | null = null;
async function join(page: Page, nick: string) {
	await page.goto(`http://127.0.0.1:${port}/`);
	await establishLocalSession(page);
	await page.fill("#nick", nick);
	await reachDirectoryOnCard(page);
	await page.fill("#room", "admission");
	await page.click("#joinBtn");
	await page.waitForSelector("#line:not([disabled])");
}
try {
	await waitForHttp(port);
	// Failed fetches, cached results and forced refresh all use the actual HTTP
	// owner. Loopback is blocked before any outbound socket opens.
	const preview = (url: string, refresh = false) =>
		fetch(
			`http://127.0.0.1:${port}/link-preview?url=${encodeURIComponent(url)}${refresh ? "&refresh=1" : ""}`,
			{ signal: AbortSignal.timeout(5000) },
		);
	const firstPreview = await preview("http://127.0.0.1/first");
	if (firstPreview.status !== 403 || (await firstPreview.json()).failure.code !== "link-preview-address-blocked") {
		fail("blocked preview did not reach its fetch owner");
	}
	const cached = await preview("http://127.0.0.1/first");
	if (cached.status !== 403) fail("cached failure spent new fetch allowance");
	await cached.body?.cancel();
	for (const [url, refresh] of [["http://127.0.0.1/second", false], ["http://127.0.0.1/first", true]] as const) {
		const refused = await preview(url, refresh);
		if (
			refused.status !== 429 || refused.headers.get("retry-after") == null ||
			(await refused.json()).failure.code !== "rate-limited"
		) fail("distinct or refreshed preview bypassed admission");
	}
	const locator = await fetch(`http://127.0.0.1:${port}/locator`, { signal: AbortSignal.timeout(5000) });
	if (locator.status !== 200) fail("preview exhaustion blocked unrelated HTTP work");
	await locator.body?.cancel();
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const first = await browser.newPage();
	const second = await browser.newPage();
	await join(first, "limited");
	// A healthy member keeps this generation alive across the limited peer's
	// leave. Last-member leave correctly closes the room and its scoped debt.
	await join(second, "healthy");
	// Re-entering immediately meets the exact room's retained debt. The visible
	// membership stays unjoined, and leaving it cancels the worker's only wait.
	await confirmTitleLeave(first);
	await first.waitForSelector("#room");
	await first.fill("#room", "admission");
	await first.click("#joinBtn");
	await first.locator("#roomList .action-feedback").waitFor({ timeout: 10_000 });
	if (await first.locator("#line:not([disabled])").count()) fail("refused join presented an active composer");
	await confirmTitleLeave(first);
	await first.waitForFunction(() =>
		![...document.querySelectorAll("#roomList .rname")].some((row) => row.textContent?.trim() === "admission")
	);
	await first.waitForTimeout(11_000);
	if (await first.locator("#line:not([disabled])").count()) fail("canceled cooldown joined later");
	await first.fill("#room", "admission");
	await first.click("#joinBtn");
	await first.waitForSelector("#line:not([disabled])");
	await say(first, "admitted-first");
	await awaitBubble(second, "admitted-first", "healthy");
	// Holding an attachment proves more than text retention alone. No upload
	// or future post is manufactured by the countdown's expiry.
	await first.setInputFiles("#filePick", {
		name: "kept.txt",
		mimeType: "text/plain",
		buffer: Buffer.from("kept attachment"),
	});
	await first.fill("#line", "kept draft");
	await first.click("#sendBtn");
	const feedback = first.locator(".composer .action-feedback");
	await feedback.waitFor({ timeout: 10_000 });
	if (await first.locator("#line").inputValue() !== "kept draft") fail("refusal discarded the draft");
	if (await first.locator('.composer-file:has-text("kept.txt")').count() !== 1) {
		fail("refusal discarded attachment custody");
	}
	await say(second, "healthy-progress");
	await awaitBubble(first, "healthy-progress", "limited");
	await first.waitForTimeout(11_000);
	if (await second.locator('.bubble:has-text("kept draft")').count()) fail("cooldown sent a hidden future post");
	if (await first.getByText("A session operation needs your decision.", { exact: true }).count()) {
		fail("unsent refusal requested delivery review");
	}
	if (await first.locator('.bubble:has-text("Not confirmed")').count()) {
		fail("refusal retained uncertain presentation");
	}
	for (const width of [1280, 390]) {
		await first.setViewportSize({ width, height: 844 });
		await first.evaluate(() =>
			new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())))
		);
		await waitForFiniteAnimations(first);
		const bounds = await feedback.evaluate((element) => {
			const box = element.getBoundingClientRect();
			const owner = element.closest(".composer")!.getBoundingClientRect();
			return box.left >= owner.left && box.right <= owner.right &&
				document.documentElement.scrollWidth <= innerWidth;
		});
		if (!bounds) fail(`composer refusal escaped its bounds at ${width}px`);
		const screenshot = Deno.env.get("GLOWCAP_ADMISSION_SCREENSHOT");
		if (screenshot) await first.screenshot({ path: `${screenshot}-${width}.png` });
	}
	await confirmTitleLeave(first);
	await first.waitForFunction(() =>
		![...document.querySelectorAll("#roomList .rname")].some((row) => row.textContent?.trim() === "admission")
	);
	console.log(
		"PASS: browser admission preserves draft/attachment, unrelated progress, explicit sends, cleanup and narrow bounds",
	);
} finally {
	clearTimeout(deadline);
	await browser?.close();
	await reapOwned();
}
