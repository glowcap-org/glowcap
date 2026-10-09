// Posting files, and changing them afterwards.
//
// The second tab is where the proof lands, because it holds none of the bytes:
// anything it draws it fetched over its own session by calling the capability
// the room handed it. Changing a posted line's files is the same claim one step
// on — the room re-broadcasts, and the tab that never had the bytes redraws.

import type { Page } from "playwright";
import { Buffer } from "node:buffer";
import { fail } from "./harness.ts";
import { runChange } from "./files_change.ts";
import { bigPng, png } from "./png.ts";
export async function run(
	tab: Page,
	second: Page,
): Promise<(where: string) => Promise<void>> {
	// ── Posting a file ───────────────────────────────────────────────────
	// A real picture through the real path: the picker takes a file, the page
	// uploads it to the room a chunk at a time, and the room broadcasts a line
	// carrying a capability to the copy it now holds. The *second* peer is
	// where the proof lands, because that tab has none of the bytes — anything
	// it draws it fetched over its own session by calling that capability.
	if (!(await tab.isDisabled("#sendBtn"))) fail("an empty composer presented Send as ready");
	await tab.setInputFiles("#filePick", {
		name: "dot.png",
		mimeType: "image/png",
		buffer: Buffer.from(png),
	});
	await tab.waitForSelector('.composer-file:has-text("dot.png")', { timeout: 10_000 })
		.catch(() => fail("the selected picture was not attached to the composer"));
	if (await tab.isDisabled("#sendBtn")) fail("attaching a picture did not make Send ready");
	const composerRows = await tab.evaluate(() => {
		const chip = document.querySelector(".composer-file")?.getBoundingClientRect();
		const text = document.querySelector("#line")?.getBoundingClientRect();
		const attach = document.querySelector("#attachBtn")?.getBoundingClientRect();
		const send = document.querySelector("#sendBtn")?.getBoundingClientRect();
		return chip && text && attach && send
			? {
				filesAboveText: chip.bottom <= text.top,
				actionsBelowText: attach.top >= text.bottom && send.top >= text.bottom,
				leftAndRightActions: attach.left < send.left,
			}
			: null;
	});
	if (
		composerRows === null || !composerRows.filesAboveText || !composerRows.actionsBelowText ||
		!composerRows.leftAndRightActions
	) {
		fail(`the composer did not keep file, text, and action rows distinct: ${JSON.stringify(composerRows)}`);
	}
	const premature = await second.$(".bubble .attach-image");
	if (premature !== null) fail("selecting a picture posted it before Send");
	await tab.click("#sendBtn");

	// The second tab draws it: an image element inside a bubble, whose source is
	// a blob URL it minted from bytes it read out of the room.
	await second.waitForFunction(
		() => {
			const img = document.querySelector(".bubble .attach-image img") as HTMLImageElement | null;
			return img !== null && img.src.startsWith("blob:") && img.naturalWidth > 0;
		},
		undefined,
		{ timeout: 30_000 },
	).catch(async () => {
		const describe = (page: Page) => page.locator("#log").innerText().catch(() => "log unavailable");
		fail(
			`the second peer never drew the posted image from the room's blob; sender=${
				JSON.stringify(await describe(tab))
			}; receiver=${JSON.stringify(await describe(second))}`,
		);
	});

	// The box was drawn at the picture's own shape, from dimensions the sender
	// measured and the room relayed. That is what stops a log of images from
	// shoving every line below it down the page as each one loads, and it is
	// invisible unless something asserts it.
	const declaredShape = await second.evaluate(() =>
		(document.querySelector(".bubble .attach-image") as HTMLElement | null)?.style.aspectRatio ?? ""
	);
	if (!/^4\s*\/\s*2$/.test(declaredShape)) {
		fail(`the picture's box reserved ${JSON.stringify(declaredShape)}, not its declared 4/2 shape`);
	}

	// Clicking a picture opens it rather than saving it. The viewer covers the
	// whole interface — it is not a panel inside the conversation column — and
	// Escape leaves it, through the same chain that dismisses Settings.
	// Hold the stage without layout to exercise the cached image's mount before
	// showModal gives it dimensions. A zero-sized box is not a fitted size.
	const hiddenStage = await second.addStyleTag({
		content: ".viewer-stage.viewer-image { display: none !important; }",
	});
	await second.click(".bubble .attach-image");
	await second.waitForFunction(() =>
		document.querySelector<HTMLImageElement>("dialog.viewer:modal img")?.naturalWidth === 4
	);
	if (!await second.locator("#viewerZoom").isDisabled()) {
		fail("an image without a laid-out stage offered actual size");
	}
	await hiddenStage.evaluate((style) => (style as ChildNode).remove());
	await second.waitForSelector(".viewer img", { timeout: 10_000 })
		.catch(() => fail("clicking the picture did not open it"));
	const covers = await second.evaluate(() => {
		const viewer = document.querySelector("dialog.viewer")!;
		const box = viewer.getBoundingClientRect();
		return viewer.matches(":modal") && document.activeElement?.getAttribute("aria-label") === "Close" &&
			box.width >= innerWidth - 1 && box.height >= innerHeight - 1 && box.top <= 1 && box.left <= 1;
	});
	if (!covers) fail("the viewer was not the focused native modal covering the interface");
	// A picture has two sizes: fitted, and actual. The tiny gallery pictures
	// land at their own size when fitted, so actual size would show nothing
	// more, and the bar's zoom button says so by being disabled.
	if (!await second.locator("#viewerZoom").isDisabled()) {
		fail("a picture already at its own size offered actual size");
	}
	await second.keyboard.press("Escape");
	await second.waitForSelector(".viewer", { state: "detached", timeout: 10_000 })
		.catch(() => fail("Escape did not close the picture"));
	await second.waitForFunction(() => document.activeElement?.matches(".attach-image") === true)
		.catch(() => fail("closing the viewer did not return focus to its image"));

	// A picture larger than the stage: fitted shows all of it inside the
	// stage (and the window), smaller than life, and the zoom button (or
	// clicking the picture) switches to actual size, where the stage scrolls
	// natively. Posted here and withdrawn below, so the gallery walks earlier
	// and later see the conversation unchanged.
	await tab.setInputFiles("#filePick", {
		name: "big.png",
		mimeType: "image/png",
		buffer: Buffer.from(bigPng(2200, 1400)),
	});
	await tab.waitForSelector('.composer-file:has-text("big.png")', { timeout: 10_000 })
		.catch(() => fail("the large picture was not attached to the composer"));
	await tab.click("#sendBtn");
	await second.waitForSelector('[aria-label="View big.png"]', { timeout: 30_000 })
		.catch(() => fail("the large picture never reached the other peer"));
	await second.click('[aria-label="View big.png"]');
	await second.waitForSelector('.viewer[aria-label="big.png"] img', { timeout: 30_000 });
	await second.waitForFunction(
		() => {
			const stage = document.querySelector(".viewer-stage.viewer-image");
			const pic = stage?.querySelector("img");
			if (stage == null || pic == null || pic.naturalWidth !== 2200) return false;
			if (pic.clientWidth >= pic.naturalWidth) return false;
			const box = stage.getBoundingClientRect();
			const shown = pic.getBoundingClientRect();
			const slack = 1;
			return shown.left >= box.left - slack && shown.right <= box.right + slack &&
				shown.top >= box.top - slack && shown.bottom <= box.bottom + slack &&
				shown.left >= -slack && shown.top >= -slack &&
				shown.right <= innerWidth + slack && shown.bottom <= innerHeight + slack;
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("a large picture did not open fitted inside the stage"));
	// The stage measures the picture after layout, through its load event or
	// a resize observation, so the button can enable a frame after the fitted
	// picture appears.
	await second.waitForFunction(
		() => document.querySelector<HTMLButtonElement>("#viewerZoom")?.disabled === false,
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("a picture larger than the stage did not offer actual size"));
	// Clicking the fitted picture is one handle on the toggle; the bar's
	// button, pressed further down, is the other. Forced, because Playwright's
	// stability heuristic refuses a picture this large while the dialog's open
	// transition settles; the assertions below are what prove the press landed.
	await second.click(".viewer-stage.viewer-image img", { position: { x: 12, y: 12 }, force: true });
	await second.waitForSelector(".viewer-stage.is-actual", { timeout: 10_000 })
		.catch(() => fail("clicking the fitted picture did not put the stage at actual size"));
	const sized = await second.evaluate(() => {
		const box = document.querySelector(".viewer-stage.is-actual");
		const pic = box?.querySelector("img");
		if (box == null || pic == null) return null;
		const centered = box.scrollLeft;
		box.scrollLeft = 40;
		return {
			actual: pic.clientWidth === pic.naturalWidth,
			scrollable: box.scrollWidth > box.clientWidth,
			scrolled: box.scrollLeft !== centered,
		};
	});
	if (sized == null) fail("clicking the fitted picture did not put the stage at actual size");
	// The bar crosses the column the stage draws its scrollbar in, and it cannot
	// answer that by refusing the pointer: what lies under it reads a click as
	// one on the backdrop and closes the viewer. So it stops short by whatever
	// that scrollbar takes. The two links are checked apart, because this
	// browser's scrollbars float over the content and take nothing: the stage
	// reports what it measures, and the bar moves when the report is not zero.
	const gutter = await second.evaluate(() => {
		const stage = document.querySelector(".viewer-stage.is-actual") as HTMLElement | null;
		const dialog = document.querySelector("dialog.viewer") as HTMLElement | null;
		const bar = document.querySelector(".viewer-bar") as HTMLElement | null;
		if (stage == null || dialog == null || bar == null) return null;
		const inset = () => Math.round(innerWidth - bar.getBoundingClientRect().right);
		const reported = dialog.style.getPropertyValue("--viewer-gutter");
		const resting = inset();
		dialog.style.setProperty("--viewer-gutter", "15px");
		const widened = inset();
		dialog.style.setProperty("--viewer-gutter", reported);
		return { measured: stage.offsetWidth - stage.clientWidth, reported, resting, widened };
	});
	if (gutter == null) fail("the viewer bar and its stage were not both on screen at actual size");
	if (gutter.reported !== `${gutter.measured}px`) {
		fail(`the stage did not report the width its scrollbar takes: ${JSON.stringify(gutter)}`);
	}
	if (gutter.resting !== gutter.measured || gutter.widened !== 15) {
		fail(`the viewer bar did not stop short of the stage's scrollbar: ${JSON.stringify(gutter)}`);
	}
	if (!sized.actual) fail("actual size is not one file pixel per CSS pixel");
	if (!sized.scrollable) fail("a picture past the stage does not scroll");
	if (!sized.scrolled) fail("the stage at actual size refused a native scroll");
	await second.click("#viewerZoom");
	await second.waitForFunction(() => document.querySelector(".viewer-stage.is-actual") == null)
		.catch(() => fail("the zoom button did not fit the picture back"));
	// The stage around the picture still leaves, fitted or not.
	await second.click(".viewer-stage.viewer-image", { position: { x: 10, y: 300 } });
	await second.waitForSelector(".viewer", { state: "detached", timeout: 10_000 })
		.catch(() => fail("clicking the stage around the picture did not leave"));
	await tab.fill("#line", "/delete");
	await tab.press("#line", "Enter");
	await second.waitForSelector(".bubble.withdrawn", { timeout: 30_000 })
		.catch(() => fail("withdrawing the large picture never reached the other peer"));

	return await runChange(tab, second);
}
