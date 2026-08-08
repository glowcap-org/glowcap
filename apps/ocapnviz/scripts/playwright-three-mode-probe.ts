#!/usr/bin/env -S deno run -A
/**
 * playwright-three-mode-probe.ts — Verifies that each top-level
 * mode (Live, Play, Build) shows / hides the right UI per the
 * spec. Cycles through all three and asserts the mode-specific
 * affordances are present, the others absent.
 *
 * Setup: dev server running on :5173.
 *
 * Pass: every check across all three modes succeeds.
 * Fail: one or more mode-specific UI gates is wrong.
 */

import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";

const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox", "--disable-gpu"],
});
const ctx = await browser.newContext({
  viewport: { width: 1600, height: 1000 },
});
const page = await ctx.newPage();

page.on("pageerror", (err) => console.log("[pageerror]", err.message));

// Clear any persisted state so we start fresh — the migration
// tests cover that path; this probe is about the live UI.
await page.addInitScript(() => {
  try {
    localStorage.removeItem("ocapnviz:app-state");
  } catch {
    // ignored
  }
});

await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(600);

async function pickMode(mode: "Live" | "Play" | "Build") {
  await page
    .getByRole("radio", { name: mode })
    .click();
  await page.waitForTimeout(250);
}

async function present(name: string): Promise<boolean> {
  return await page.locator(name).count() > 0;
}

async function check(mode: "live" | "play" | "build") {
  const failures: string[] = [];
  const recordBtn = await present('button[aria-label="Start recording"]');
  const wsInput = await present('input[placeholder^="ws://"]');
  const followLive = await page.getByRole("switch", { name: /follow live/i })
    .count();
  // Fixture picker — the dropdown that has an <optgroup label="Fixtures">.
  const fixtureSelect = await page.locator(
    'select.ocv-select optgroup[label="Fixtures"]',
  ).count();

  // TimelinePanel mounts the Play / Pause / Restart toolbar; the
  // Restart button title is stable across modes (and other modes
  // don't have it). Use its presence as the "Timeline visible"
  // signal.
  const timelinePanelPresent = await page.locator(
    'button[title^="Restart"]',
  ).count();
  const timelineMarker = timelinePanelPresent; // alias for legibility below

  if (mode === "live") {
    if (!recordBtn) failures.push("expected Record button");
    if (!wsInput) failures.push("expected WS URL input");
    if (timelineMarker > 0) failures.push("expected Timeline HIDDEN");
    if (fixtureSelect > 0) failures.push("expected NO fixture picker");
    if (followLive > 0) failures.push("Follow Live button should not exist");
  } else if (mode === "play") {
    if (recordBtn) failures.push("expected NO Record button");
    if (wsInput) failures.push("expected NO WS input");
    if (fixtureSelect === 0) failures.push("expected fixture picker");
    if (timelineMarker === 0) failures.push("expected Timeline visible");
    if (followLive > 0) failures.push("Follow Live button removed (any mode)");
  } else if (mode === "build") {
    if (recordBtn) failures.push("expected NO Record button in Build");
    if (wsInput) failures.push("expected NO WS input in Build");
    if (fixtureSelect === 0) failures.push("expected fixture picker");
    if (timelineMarker === 0) failures.push("expected Timeline visible");
    if (followLive > 0) failures.push("Follow Live button removed (any mode)");
  }

  const pass = failures.length === 0;
  console.log(`[${mode}] ${pass ? "PASS" : "FAIL"}`);
  for (const f of failures) console.log(`  - ${f}`);
  return pass;
}

await pickMode("Live");
const liveOk = await check("live");
await pickMode("Play");
const playOk = await check("play");
await pickMode("Build");
const buildOk = await check("build");

const allOk = liveOk && playOk && buildOk;
console.log("");
console.log(allOk ? "ALL PASS" : "FAIL");

await browser.close();
Deno.exit(allOk ? 0 : 1);
