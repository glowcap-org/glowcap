#!/usr/bin/env -S deno run -A
/**
 * playwright-inspector-overflow-probe.ts: does the Inspector still fit
 * when the names in it are sixty-four characters of hex?
 *
 * Running the rooms app over iroh gives every peer a key for a name, and
 * the Inspector was built against fixtures whose designators are short
 * host:port strings. Nothing in the types says which panel holds a name a
 * person chose and which holds a key, so the only way to find out what
 * overflows is to put a key in every field a key can reach and measure
 * the boxes.
 *
 * The probe authors that document through the app's own Build mode, a
 * peer renamed to a key, its identifier set to a key, both of a
 * session's end claims set to keys, and one end detached so the panel
 * carries its three-word "nothing proved this" badge, and then asks
 * four questions of the Inspector pane:
 *
 *   - is any text cut off with no ellipsis to say it was cut;
 *   - does the pane itself scroll sideways;
 *   - has any connection row grown taller than one line;
 *   - can any badge wrap, which is how a row grows in the first place.
 *
 * It runs at the default pane width and again with the window narrowed,
 * because a layout that survives one width and not the other has not
 * survived.
 *
 * Run against a dev server: `deno task dev`, then
 * `deno run -A scripts/playwright-inspector-overflow-probe.ts http://127.0.0.1:5173/`.
 */
import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5199/";

/** A 64-character hex key, the shape an iroh node id arrives in. */
const KEY_A = "9b5c6e95b0e6bf0151238adc20a3f1c47e0b8d92a4415f6c73ee01d5b8a29f34";
const KEY_B = "c41171f326941a7123aae1687f5d02b93c8ea6410d92bb75f0c31e8a4d6721ab";

/** A connection row holds one line of text and a badge. Two lines of
 *  9px badge plus the row's own padding clears this. One line does not. */
const MAX_ROW_HEIGHT = 34;

const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});
const ctx = await browser.newContext({
	viewport: { width: 1600, height: 1000 },
});
const page = await ctx.newPage();
const failures: string[] = [];
page.on("pageerror", (e) => failures.push(`pageerror: ${e.message}`));
await page.addInitScript(() => {
	try {
		localStorage.removeItem("ocapnviz:app-state");
	} catch { /* ignore */ }
});
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(500);
await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(300);

/** Click the peer the stage draws first, which is what puts the peer
 *  panel in the Inspector. */
const peers = await page.evaluate(() => {
	type Peer = { peer: { id: string }; position?: { x: number; y: number } };
	type VP = { toScreen: (x: number, y: number) => { x: number; y: number } };
	const g = globalThis as unknown as {
		__ocv?: { engine?: { queries?: { peers?: Iterable<Peer> } } };
		__ocvViewport?: VP;
	};
	const list = g.__ocv?.engine?.queries?.peers;
	const vp = g.__ocvViewport;
	if (!list || !vp) return [];
	const out: { id: string; sx: number; sy: number }[] = [];
	for (const p of list) {
		if (!p.position) continue;
		const s = vp.toScreen(p.position.x, p.position.y);
		out.push({ id: p.peer.id, sx: s.x, sy: s.y });
	}
	return out;
});
if (peers.length === 0) {
	console.log("FAIL — no peers on stage");
	await browser.close();
	Deno.exit(1);
}
await page.mouse.click(peers[0]!.sx, peers[0]!.sy);
await page.waitForTimeout(300);

/** Type `text` into a field, replacing whatever it held. */
async function fill(label: string, text: string) {
	const el = page.getByLabel(label).first();
	if (await el.count() === 0) {
		failures.push(`${label}: no such field`);
		return;
	}
	await el.fill(text);
	await el.blur();
	await page.waitForTimeout(200);
}

// A peer whose name and identifier are both keys. The heading, the id
// row, and the identifier row all end up holding one.
await page.getByPlaceholder("Label").first().fill(KEY_A);
await page.getByPlaceholder("Label").first().blur();
await page.waitForTimeout(200);
await fill("peer id", KEY_A);
await page.getByPlaceholder("(none)").first().fill(KEY_B);
await page.getByPlaceholder("(none)").first().blur();
await page.waitForTimeout(300);

/** Every box inside the Inspector pane, measured against the pane. */
async function measure(where: string) {
	const report = await page.evaluate((maxRow: number) => {
		// The Inspector is the right-hand pane; the left one is the source
		// and layers column.
		const panes = [...document.querySelectorAll("aside.ocv-pane")];
		const pane = panes[panes.length - 1];
		if (!pane) return { missing: true, over: [], tall: [], scroll: 0 };
		// Content cut off without saying so.
		//
		// Geometry alone is the wrong question here: the pane hides its own
		// horizontal overflow, so a box sticking out is clipped either way
		// and a heading whose children spill is doing exactly what its
		// ellipsis promises. What a reader actually loses is text cut with
		// no mark to say it was cut. So the check is: a box narrower than
		// its content has to be one that declared an ellipsis, or a form
		// control, which clips by its own nature and the user has said is
		// fine.
		const over: string[] = [];
		for (const el of pane.querySelectorAll("*")) {
			const tag = el.tagName;
			if (tag === "INPUT" || tag === "SELECT" || tag === "TEXTAREA") continue;
			if (el.scrollWidth <= el.clientWidth + 1) continue;
			if (el.clientWidth === 0) continue;
			const s = globalThis.getComputedStyle(el);
			if (s.textOverflow === "ellipsis") continue;
			const text = (el.textContent ?? "").trim().slice(0, 28);
			if (text === "") continue;
			over.push(
				`${tag.toLowerCase()} "${text}" is cut by ${el.scrollWidth - el.clientWidth}px with no ellipsis`,
			);
		}
		const tall: string[] = [];
		for (const row of pane.querySelectorAll("button.ocv-session-row")) {
			const h = row.getBoundingClientRect().height;
			if (h > maxRow) {
				tall.push(
					`row "${(row.textContent ?? "").slice(0, 28)}" is ${Math.round(h)}px tall`,
				);
			}
		}
		// Every badge in the pane, found by the shape they share: a flex box
		// of tracked uppercase. (`inline-flex` computes to `flex` when the
		// badge is itself a grid or flex item, which most of them are, so
		// both spellings count.)
		//
		// The check is that none of them may wrap. Height would be the more
		// direct measurement and it is not the one to make: a badge only
		// wraps once its row is narrow enough and its words are many enough,
		// so a height that passes proves the document rather than the
		// layout. `nowrap` is the property that makes the wrap impossible at
		// every width, and the row-height check above is what catches the
		// consequence when a badge slips out of this family.
		const badges: string[] = [];
		for (const el of pane.querySelectorAll("span, div")) {
			const s = globalThis.getComputedStyle(el);
			const flexish = s.display === "inline-flex" || s.display === "flex";
			if (!flexish || s.textTransform !== "uppercase") continue;
			const text = (el.textContent ?? "").trim();
			if (text === "") continue;
			if (s.whiteSpace !== "nowrap") {
				badges.push(`badge "${text}" can wrap (white-space: ${s.whiteSpace})`);
			}
		}
		return {
			missing: false,
			over: over.slice(0, 8),
			tall: [...tall, ...badges],
			scroll: pane.scrollWidth - pane.clientWidth,
		};
	}, MAX_ROW_HEIGHT);

	if (report.missing) {
		failures.push(`${where}: no Inspector pane on the page`);
		return;
	}
	for (const line of report.over) failures.push(`${where}: ${line}`);
	for (const line of report.tall) failures.push(`${where}: ${line}`);
	if (report.scroll > 1) {
		failures.push(`${where}: the pane scrolls ${report.scroll}px sideways`);
	}
	const verdict = report.over.length + report.tall.length === 0 &&
		report.scroll <= 1;
	console.log(
		`${verdict ? "ok  " : "FAIL"} ${where}: ${report.over.length} boxes cut ` +
			`with no ellipsis, ${report.tall.length} problem rows or badges, ` +
			`${report.scroll}px of sideways scroll`,
	);
}

await measure("peer panel, 1600px window");

// The session the peer is on, whose two ends are the fields the
// screenshot showed clipped.
const rows = page.locator("button.ocv-session-row");
if (await rows.count() === 0) {
	failures.push("no session to inspect from the peer's connections");
} else {
	await rows.first().click();
	await page.waitForTimeout(400);
	const claims = page.getByPlaceholder("nothing");
	const count = await claims.count();
	for (let i = 0; i < count; i++) {
		await claims.nth(i).fill(i === 0 ? KEY_A : KEY_B);
		await claims.nth(i).blur();
		await page.waitForTimeout(150);
	}
	await measure("session panel, 1600px window");

	// Detach end B, which is the state this whole endpoint model exists to
	// draw: a claim nothing proved, and no peer on that end. Read-only it
	// wears a three-word badge, "nothing proved this", which is the shape
	// that was wrapping to three lines inside a one-line row.
	const attached = page.getByLabel("Peer attached to end b").first();
	if (await attached.count() > 0) {
		// By value, not by label: the empty string is what the picker holds
		// for "no peer", and the probe should not have an opinion about the
		// word beside it.
		await attached.selectOption({ value: "" });
		await page.waitForTimeout(300);
	}

	await page.setViewportSize({ width: 1100, height: 900 });
	await page.waitForTimeout(400);
	await measure("session panel, 1100px window");

	// Play mode renders the same session read-only, which is where the
	// badges are: the attribution chip in the end block and the claim row
	// in Connections.
	await page.getByRole("radio", { name: "Play" }).click();
	await page.waitForTimeout(500);
	const seen = await page.evaluate(() => {
		const panes = [...document.querySelectorAll("aside.ocv-pane")];
		const pane = panes[panes.length - 1];
		if (!pane) return "(no pane)";
		const out: string[] = [];
		for (const el of pane.querySelectorAll("span, div")) {
			const s = globalThis.getComputedStyle(el);
			const flexish = s.display === "inline-flex" || s.display === "flex";
			if (flexish && s.textTransform === "uppercase") {
				const t = (el.textContent ?? "").trim();
				if (t !== "") {
					out.push(`${t} (${Math.round(el.getBoundingClientRect().height)}px)`);
				}
			}
		}
		return out.join(" | ");
	});
	console.log(`note  badges on screen: ${seen}`);
	await measure("session panel read-only, 1100px window");
}

await browser.close();
if (failures.length > 0) {
	console.log(`\nFAIL — ${failures.length}`);
	for (const f of failures) console.log(`  ${f}`);
	Deno.exit(1);
}
console.log("\nPASS — the Inspector holds its box with keys in every field");
