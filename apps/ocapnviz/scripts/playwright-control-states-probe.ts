#!/usr/bin/env -S deno run -A
/**
 * playwright-control-states-probe.ts: what a control looks
 * like at rest, under the pointer, and with the keyboard on it.
 *
 * Usage: playwright-control-states-probe.ts <out-dir> [url]
 *
 * For each theme it prints the computed background, border, text colour
 * and box-shadow of a ghost icon button, a worded button, a segmented
 * cell and a dropdown in each state, then screenshots the two clusters
 * mid-hover. Rest and hover printing the same values is the failure this
 * catches: a state nobody can see is not a state.
 */
import { chromium } from "playwright";

const outDir = Deno.args[0] ?? "/tmp/ocv-states";
const url = Deno.args[1] ?? "http://127.0.0.1:5173/";
await Deno.mkdir(outDir, { recursive: true });

type Probe = { name: string; selector: string };
const probes: Probe[] = [
	{ name: "icon button (ghost)", selector: 'button[aria-label="Save"]' },
	{ name: "worded button", selector: 'button:text("Reset layout")' },
	{
		name: "segmented cell (unchosen)",
		selector: 'button[role="radio"]:text-is("Play")',
	},
	{
		name: "segmented cell (chosen)",
		selector: 'button[role="radio"]:text-is("Build")',
	},
	{ name: "tool button (chosen)", selector: 'button[aria-label="Select"]' },
	{ name: "tool button (unchosen)", selector: 'button[aria-label="Hand"]' },
	{ name: "dropdown", selector: "select" },
];

const marks = (el: Element) => {
	const s = getComputedStyle(el);
	return [
		`bg ${s.backgroundColor}`,
		`border ${s.borderTopColor}`,
		`ink ${s.color}`,
		`shadow ${s.boxShadow === "none" ? "none" : "yes"}`,
		`outline ${s.outlineColor} ${s.outlineWidth}`,
	].join("  ");
};

const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});

for (const theme of ["light", "dark"] as const) {
	const ctx = await browser.newContext({
		viewport: { width: 1600, height: 1000 },
		deviceScaleFactor: 2,
		colorScheme: theme,
	});
	const page = await ctx.newPage();
	await page.addInitScript(() => {
		try {
			localStorage.removeItem("ocapnviz:app-state");
		} catch {
			// first run has nothing to clear
		}
	});
	await page.goto(url, { waitUntil: "networkidle" });
	await page.waitForSelector("canvas#ocv-pixi");
	await page.evaluate((t) => {
		document.documentElement.dataset.theme = t;
	}, theme);
	await page.getByRole("radio", { name: "Build" }).click();
	await page.waitForTimeout(400);

	console.log(`\n──────── ${theme} ────────`);
	for (const { name, selector } of probes) {
		const el = page.locator(selector).first();
		if (!(await el.count())) {
			console.log(`${name}: not present`);
			continue;
		}
		const rest = await el.evaluate(marks);
		await el.hover();
		await page.waitForTimeout(220);
		const hover = await el.evaluate(marks);
		await page.mouse.move(800, 900);
		await page.waitForTimeout(220);
		// `:focus-visible` follows Chromium's last-interaction heuristic, so
		// a scripted `.focus()` after a mouse move reads as a click and
		// shows no ring. Press a key first, the way a keyboard user arrives.
		await page.keyboard.press("Tab");
		await el.focus();
		await page.waitForTimeout(220);
		const focus = await el.evaluate(marks);
		await page.mouse.move(800, 900);
		console.log(`${name}`);
		console.log(`  rest   ${rest}`);
		console.log(
			`  hover  ${hover}${hover === rest ? "   ⚠ SAME AS REST" : ""}`,
		);
		console.log(
			`  focus  ${focus}${focus === rest ? "   ⚠ SAME AS REST" : ""}`,
		);
	}

	// The chevron is a background image, so a `<select>` can carry a
	// perfectly good CSS rule and still paint nothing. A stroke the same
	// colour as the surface, or a glyph clipped by the appearance reset.
	// Report what each dropdown actually resolved, and whether it left
	// room for it.
	for (
		const d of await page.locator("select").evaluateAll((els) =>
			els.map((el) => {
				const s = getComputedStyle(el);
				return {
					label: el.getAttribute("aria-label") ?? "(unlabelled)",
					painted: s.backgroundImage !== "none" && s.backgroundImage !== "",
					size: s.backgroundSize,
					position: s.backgroundPosition,
					room: s.paddingRight,
				};
			})
		)
	) {
		console.log(
			`chevron "${d.label}" painted=${d.painted} size=${d.size} at ${d.position} room=${d.room}`,
		);
	}

	// Hover the save button and shoot the whole top-right cluster.
	await page.locator('button[aria-label="Save"]').first().hover();
	await page.waitForTimeout(250);
	await page.screenshot({
		path: `${outDir}/${theme}-topbar-hover.png`,
		clip: { x: 1150, y: 4, width: 450, height: 40 },
	});

	// Hover an unchosen tool and shoot the palette.
	await page.locator('button[aria-label="Hand"]').first().hover();
	await page.waitForTimeout(250);
	await page.screenshot({
		path: `${outDir}/${theme}-palette-hover.png`,
		clip: { x: 8, y: 88, width: 200, height: 34 },
	});

	await ctx.close();
}

await browser.close();
console.log(`\nshots → ${outDir}/`);
