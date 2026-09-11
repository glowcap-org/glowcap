// Changing a posted file line's files.
//
// Called from `files.ts` after the posting phase, so the second tab already
// holds a capability to a file it never uploaded.

import type { Page } from "playwright";
import { Buffer } from "node:buffer";
import { bubbleInkContrast, fail } from "./harness.ts";
import { png } from "./png.ts";
import { runChrome } from "./chrome.ts";

export async function runChange(
	tab: Page,
	second: Page,
): Promise<(where: string) => Promise<void>> {
	// A file line is a line, so its message menu offers Edit — and because the
	// line carries files, Edit opens the composer on them: each file shows as a
	// removable chip rather than only the caption in the field. Post a file, then
	// swap it for a different one and send. The room refiles the line in place,
	// and the second peer, which holds none of the bytes, redraws it from the new
	// blob under the same line. Kept to text files on purpose: they stay out of
	// the image viewer order the picture tests below walk, so this proves the
	// whole edit path without disturbing them.
	{
		await tab.setInputFiles("#filePick", {
			name: "refile-me.txt",
			mimeType: "text/plain",
			buffer: Buffer.from("before"),
		});
		await tab.waitForSelector('.composer-file:has-text("refile-me.txt")', { timeout: 10_000 })
			.catch(() => fail("the file to be refiled was not attached to the composer"));
		await tab.fill("#line", "before refile");
		await tab.click("#sendBtn");
		await second.waitForFunction(
			() =>
				[...document.querySelectorAll(".bubble .attach-file .name")].some((name) =>
					name.textContent === "refile-me.txt"
				),
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("the second peer never saw the file line to be refiled"));

		const line = tab.locator('.bubble:has-text("refile-me.txt")').last();
		await line.hover();
		await line.getByLabel("More for this message").click();
		await tab.locator('.line-menu [role=menuitem]:has-text("Edit")').click();
		await tab.waitForSelector('#changing:has-text("files")', { timeout: 10_000 })
			.catch(() => fail("editing a file line did not open the composer on its files"));
		await tab.waitForSelector('.composer-file:has-text("refile-me.txt")', { timeout: 10_000 })
			.catch(() => fail("the file on the line did not appear as a removable chip"));
		await tab.click('.composer-file:has-text("refile-me.txt") .composer-file-remove');
		await tab.setInputFiles("#filePick", {
			name: "refiled.txt",
			mimeType: "text/plain",
			buffer: Buffer.from("after"),
		});
		await tab.waitForSelector('.composer-file:has-text("refiled.txt")', { timeout: 10_000 })
			.catch(() => fail("the replacement file was not attached to the file-line change"));
		await tab.fill("#line", "after refile");
		await tab.click("#sendBtn");
		// The second peer redraws the same line: its caption changed and its file is
		// the new one. The file it dropped is gone from that line.
		await second.waitForFunction(
			() =>
				[...document.querySelectorAll(".bubble")].some((bubble) => {
					if (!(bubble.textContent ?? "").includes("after refile")) return false;
					const names = [...bubble.querySelectorAll(".attach-file .name")].map((n) => n.textContent);
					return names.includes("refiled.txt") && !names.includes("refile-me.txt");
				}),
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("the second peer did not redraw the refiled line with its new caption and file"));
		// The recipient may receive the edit before its acknowledgement returns.
		// The composer releases the submitted edit only after that acknowledgement.
		await tab.locator("#changing").waitFor({ state: "detached", timeout: 10_000 })
			.catch(() => fail("acknowledging the refile left the composer changing a line"));
		await tab.fill("#line", "");

		// Editing the line down to nothing takes it back, because a message with no
		// files and no caption is not a message. That is a real thing to want — it
		// is how the last file comes off — but it must not arrive as a surprise, so
		// the composer says what sending will do and the control stops calling
		// itself Send. Taking the line back this way also proves a file line
		// withdraws like any other, its file going with it, and leaves no file row
		// behind for the picture and download tests below to trip over.
		const refiled = tab.locator('.bubble:has-text("after refile")').last();
		await refiled.hover();
		await refiled.getByLabel("More for this message").click();
		await tab.locator('.line-menu [role=menuitem]:has-text("Edit")').click();
		await tab.click('.composer-file:has-text("refiled.txt") .composer-file-remove');
		await tab.fill("#line", "");
		await tab.waitForSelector("#changing:has-text('takes it back')", { timeout: 10_000 })
			.catch(() => fail("emptying a file line did not say that sending would take the message back"));
		const saidTakeBack = await tab.getAttribute("#sendBtn", "aria-label");
		if (saidTakeBack !== "Take this message back") {
			fail(`the control still offered to send an empty message: ${JSON.stringify(saidTakeBack)}`);
		}
		await tab.click("#sendBtn");
		await second.waitForFunction(
			() =>
				![...document.querySelectorAll(".attach-file .name")].some((name) =>
					name.textContent === "refiled.txt"
				),
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("withdrawing a file line did not take its file away for the other peer"));
		await tab.locator("#changing").waitFor({ state: "detached", timeout: 10_000 })
			.catch(() => fail("the room withdrew the file line but its matching composer intent stayed active"));
	}

	// Pictures sent together stay one message, but become a compact, independently
	// openable gallery. Rows balance across the full gallery width; exposing a
	// vacant column or shrinking the gallery into a left-aligned island would make
	// the message feel unfinished.
	await tab.setInputFiles(
		"#filePick",
		["one", "two", "three", "four", "five"].map((name) => ({
			name: `${name}.png`,
			mimeType: "image/png",
			buffer: Buffer.from(png),
		})),
	);
	await tab.waitForSelector('.composer-file:has-text("five.png")', { timeout: 10_000 })
		.catch(() => fail("the image set was not attached to the composer"));
	await tab.click("#sendBtn");
	await second.waitForFunction(
		() => {
			const grid = document.querySelector('.attachment-set.image-grid:has([aria-label*="five.png"])');
			const images = [...(grid?.querySelectorAll(".attach-image img") ?? [])] as HTMLImageElement[];
			return images.length === 5 && images.every((image) => image.naturalWidth > 0);
		},
		undefined,
		{ timeout: 30_000 },
	).catch(async () => {
		const describe = (page: Page) =>
			page.evaluate(() => ({
				grids: [...document.querySelectorAll(".attachment-set")].map((grid) => ({
					classes: grid.className,
					files: [...grid.querySelectorAll(".attach-image")].map((image) => ({
						label: image.getAttribute("aria-label"),
						error: image.querySelector(".failure")?.textContent ?? null,
						naturalWidth: (image.querySelector("img") as HTMLImageElement | null)?.naturalWidth ?? null,
					})),
				})),
				log: document.querySelector("#log")?.textContent ?? null,
				composer: document.querySelector(".composer")?.textContent ?? null,
				toasts: [...document.querySelectorAll("[role=status], [role=alert]")].map((notice) =>
					notice.textContent
				),
			}));
		fail(`the image set did not arrive as one thumbnail grid: ${
			JSON.stringify({
				sender: await describe(tab),
				receiver: await describe(second),
			})
		}`);
	});
	const gallery = await second.evaluate(() => {
		const grid = document.querySelector(
			'.attachment-set.image-grid:has([aria-label*="five.png"])',
		) as HTMLElement | null;
		const tiles = [...(grid?.querySelectorAll(".attach-image") ?? [])] as HTMLElement[];
		if (grid === null || tiles.length !== 5) return null;
		const box = grid.getBoundingClientRect();
		const bubble = grid.closest(".bubble")!.getBoundingClientRect();
		const cells = tiles.map((tile) => tile.getBoundingClientRect());
		return {
			oneBubble: grid.closest(".bubble")?.querySelectorAll(".attach-image").length === 5,
			width: box.width,
			bubbleWidth: bubble.width,
			fullWidth: box.width >= 330,
			fitsBubble: bubble.width - box.width <= 29,
			completeFirstRow: Math.abs(cells[0].left - box.left) < 1 &&
				Math.abs(cells[0].top - cells[1].top) < 1 && Math.abs(cells[1].top - cells[2].top) < 1 &&
				cells[1].left > cells[0].left && cells[2].left > cells[1].left &&
				Math.abs(cells[2].right - box.right) < 1,
			completeSecondRow: cells[3].top > cells[0].bottom && Math.abs(cells[3].top - cells[4].top) < 1 &&
				Math.abs(cells[3].left - box.left) < 1 && cells[4].left > cells[3].left &&
				Math.abs(cells[4].right - box.right) < 1,
			compact: box.height < box.width * 0.75,
			thumbnailSized: cells.slice(0, 3).every((cell) => cell.width <= 115),
			squareFirstRow: cells.slice(0, 3).every((cell) => Math.abs(cell.width - cell.height) < 1),
			cropped: getComputedStyle(tiles[0].querySelector("img")!).objectFit === "cover",
		};
	});
	if (
		gallery === null || !gallery.oneBubble || !gallery.fullWidth || !gallery.fitsBubble ||
		!gallery.completeFirstRow || !gallery.completeSecondRow || !gallery.compact || !gallery.thumbnailSized ||
		!gallery.squareFirstRow || !gallery.cropped
	) {
		const state = await second.evaluate(() => ({
			attachments: [...document.querySelectorAll(".attachment-set")].map((set) => ({
				classes: set.className,
				names: [...set.querySelectorAll("[aria-label]")].map((item) => item.getAttribute("aria-label")),
			})),
			log: document.querySelector("#log")?.textContent ?? null,
		}));
		fail(`the multi-image message left an incomplete gallery row: ${JSON.stringify({ gallery, state })}`);
	}

	// The full-screen viewer follows conversation order rather than gallery DOM
	// boundaries: Left crosses from the first gallery image to the earlier
	// standalone picture, and Right walks back into and through the gallery.
	await second.click('[aria-label="View one.png"]');
	await second.waitForSelector('.viewer[aria-label="one.png"] img');
	await second.keyboard.press("ArrowLeft");
	await second.waitForSelector('.viewer[aria-label="dot.png"] img');
	await second.keyboard.press("ArrowRight");
	await second.waitForSelector('.viewer[aria-label="one.png"] img');
	await second.keyboard.press("ArrowRight");
	await second.waitForSelector('.viewer[aria-label="two.png"] img');
	await second.keyboard.press("Escape");
	await second.waitForSelector(".viewer", { state: "detached" });
	await second.waitForFunction(() => document.activeElement?.getAttribute("aria-label") === "View one.png")
		.catch(() => fail("closing a navigated viewer did not return focus to its opening image"));

	// A file that is not an image is a row with a name and one control, and that
	// control does the whole job in one press: fetch the bytes from the room,
	// then hand them to the browser to save. Nothing downloads by itself.
	await tab.setInputFiles("#filePick", [
		{
			name: "notes.txt",
			mimeType: "text/plain",
			buffer: Buffer.from("glowcap"),
		},
		{
			name: "ledger.csv",
			mimeType: "text/csv",
			buffer: Buffer.from("layer,cost\nui,one-bubble\n"),
		},
	]);
	await tab.waitForSelector('.composer-file:has-text("notes.txt")', { timeout: 10_000 })
		.catch(() => fail("the first selected file was not attached to the composer"));
	await tab.waitForSelector('.composer-file:has-text("ledger.csv")', { timeout: 10_000 })
		.catch(() => fail("the second selected file was not attached to the composer"));
	await tab.click("#sendBtn");
	await tab.waitForSelector(".row.mine .attach-file .icon-button", { timeout: 30_000 })
		.catch(() => fail("the sender never saw its own file action"));
	const originalTheme = await tab.getAttribute("html", "data-theme");
	for (const theme of ["light", "dark"] as const) {
		await tab.evaluate((theme) => document.documentElement.setAttribute("data-theme", theme), theme);
		const ratio = await bubbleInkContrast(tab, ".row.mine .attach-file .icon-button");
		if (!("ratio" in ratio) || ratio.ratio < 4.5) {
			const style = await tab.evaluate(() => {
				const action = document.querySelector(".row.mine .attach-file .icon-button") as HTMLElement;
				const bubble = action.closest(".bubble") as HTMLElement;
				return {
					tone: action.dataset.tone,
					color: getComputedStyle(action).color,
					background: getComputedStyle(action).backgroundColor,
					bubble: getComputedStyle(bubble).backgroundImage,
				};
			});
			fail(
				`the ${theme} authored-file action falls to ${
					"ratio" in ratio ? ratio.ratio.toFixed(2) : `unmeasurable (${ratio.why})`
				}:1 on hover: ${JSON.stringify(style)}`,
			);
		}
		for (const selector of [".row.mine .attach-file .glyph", ".row.mine .attach-file .sub"]) {
			const inkRatio = await bubbleInkContrast(tab, selector, ".attach-file");
			if (!("ratio" in inkRatio) || inkRatio.ratio < 4.5) {
				fail(
					`${theme} ${selector} falls to ${
						"ratio" in inkRatio ? inkRatio.ratio.toFixed(2) : `unmeasurable (${inkRatio.why})`
					}:1 in an authored file`,
				);
			}
		}
	}
	await tab.evaluate((theme) => {
		if (theme === null) document.documentElement.removeAttribute("data-theme");
		else document.documentElement.setAttribute("data-theme", theme);
	}, originalTheme);
	await second.waitForFunction(
		() => {
			const rows = [...document.querySelectorAll(".bubble .attach-file")];
			const names = rows.map((row) => row.querySelector(".name")?.textContent);
			return names.includes("notes.txt") && names.includes("ledger.csv");
		},
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the second peer never saw both posted text files"));
	const groupedFiles = await second.evaluate(() => {
		const byName = (name: string) =>
			[...document.querySelectorAll(".attach-file")].find((row) =>
				row.querySelector(".name")?.textContent === name
			);
		const first = byName("notes.txt")?.closest(".bubble");
		const second = byName("ledger.csv")?.closest(".bubble");
		return first !== null && first !== undefined && first === second &&
			first.querySelectorAll(".attach-file").length === 2;
	});
	if (!groupedFiles) fail("one send of two files did not render as one bubble containing both files");
	const fileAction = await second.evaluate(() => {
		const rows = [...document.querySelectorAll(".bubble .attach-file")];
		const row = rows.find((candidate) => candidate.querySelector(".name")?.textContent === "notes.txt");
		const action = row?.querySelector(".icon-button");
		return action
			? { icon: action.querySelector(".icon-svg") !== null, visibleLabel: action.textContent?.trim() ?? "" }
			: null;
	});
	if (fileAction === null || !fileAction.icon || fileAction.visibleLabel !== "") {
		fail(`the file download was not a named icon button: ${JSON.stringify(fileAction)}`);
	}
	// Copying a message is in its menu now, so the mark that opens the menu is the
	// icon button this contract is about: named, drawn as a glyph, and carrying no
	// text of its own.
	const menuMark = await second.evaluate(() => {
		const action = document.querySelector('.line-acts button[aria-label^="More for this message"]');
		return action?.matches(".icon-button") === true && action.querySelector(".icon-svg") !== null &&
			action.textContent?.trim() === "";
	});
	if (!menuMark) fail("the mark that opens a message's menu was not an accessible icon button");
	const iconButtonContract = await second.evaluate(() =>
		[...document.querySelectorAll<HTMLButtonElement>(".icon-button")].flatMap((button) => {
			if (!button.checkVisibility({ visibilityProperty: true })) return [];
			const label = button.getAttribute("aria-label")?.trim() ?? "";
			const size = button.dataset.size;
			const expected = size === "small" ? 26 : size === "normal" ? 36 : size === "large" ? 42 : 0;
			const box = button.getBoundingClientRect();
			return label !== "" && expected > 0 && Math.abs(box.height - expected) <= 0.5
				? []
				: [`${button.id || button.className}: label=${
					JSON.stringify(label)
				}, size=${size}, height=${box.height}`];
		})
	);
	if (iconButtonContract.length > 0) {
		fail(`icon buttons escaped their accessible three-size baseline: ${iconButtonContract.join("; ")}`);
	}
	const saved = second.waitForEvent("download", { timeout: 30_000 });
	await second.click(".bubble .attach-file .icon-button");
	const download = await saved.catch(() =>
		fail("pressing the download icon never produced a download; the reader asked for the file, not its transfer")
	);
	if (download.suggestedFilename() !== "notes.txt") {
		fail(`the download was named ${JSON.stringify(download.suggestedFilename())}`);
	}

	return await runChrome(tab);
}
