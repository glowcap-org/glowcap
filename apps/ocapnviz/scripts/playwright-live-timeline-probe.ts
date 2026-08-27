#!/usr/bin/env -S deno run -A
/**
 * Live-mode timeline disabled-but-visible screenshot.
 * Switches to Live mode and captures the bottom bar to verify
 * the timeline renders with a LIVE badge + dimmed controls.
 */
import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";
const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});
const ctx = await browser.newContext({
	viewport: { width: 1600, height: 1000 },
	colorScheme: "dark",
});
const page = await ctx.newPage();
page.on("pageerror", (e) => console.log("[pageerror]", e.message));
await page.addInitScript(() => {
	try {
		localStorage.removeItem("ocapnviz:app-state");
	} catch {
		// ignore
	}
});
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(400);

await page.getByRole("radio", { name: "Live" }).click();
await page.waitForTimeout(400);

await page.screenshot({ path: "/tmp/live-timeline.png" });
console.log("Full screenshot → /tmp/live-timeline.png");

await browser.close();
