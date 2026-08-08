#!/usr/bin/env -S deno run -A
/**
 * playwright-trajectory-scrub-probe.ts — does click-and-drag scrub the
 * time on an Inspector TRAJECTORY row the way it does on the start row?
 *
 * A real drag in a real browser is the only proof of this one. Every row
 * in the Timing section renders through the same `OptionalTimeRow`, so
 * nothing about the props tells you whether the gesture reaches the
 * input; what differed was the React key the trajectory list gave each
 * row, and how much of the row the scrub occupied.
 *
 * The probe drags each row a known distance and checks the time moved by
 * the distance the scrub's sensitivity says it should (1px is 10ms). A
 * gesture that dies partway through moves the value a little, which is
 * why "it changed at all" is not the check.
 *
 * Run against a dev server: `deno task dev`, then
 * `deno run -A scripts/playwright-trajectory-scrub-probe.ts http://127.0.0.1:5173/`.
 */
import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5199/";
/** `TimeScrubInput` drags linearly at 0.1 px per ms. */
const MS_PER_PX = 10;
/** A grip narrower than this is a sliver a reader will not find, beside
 *  a value editor that fills the rest of the row and is not draggable. */
const MIN_GRIP_PX = 64;

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

/** Drag a row's time by `dy` px and report what the value did. Upward
 *  drag raises, so the expected delta is `-dy * MS_PER_PX`. */
async function scrub(name: string, dy: number) {
  const el = page.getByRole("spinbutton", { name }).first();
  if (await el.count() === 0) {
    failures.push(`${name}: no such row`);
    return;
  }
  const box = await el.boundingBox();
  if (!box) {
    failures.push(`${name}: row is not laid out`);
    return;
  }
  if (box.width < MIN_GRIP_PX) {
    failures.push(
      `${name}: the grip is ${Math.round(box.width)}px, under ${MIN_GRIP_PX}`,
    );
  }
  const before = Number(await el.getAttribute("aria-valuenow"));
  const cx = box.x + box.width / 2;
  const cy = box.y + box.height / 2;
  await page.mouse.move(cx, cy);
  await page.mouse.down();
  for (let i = 1; i <= 8; i++) {
    await page.mouse.move(cx, cy + (dy * i) / 8);
    await page.waitForTimeout(16);
  }
  await page.mouse.up();
  await page.waitForTimeout(200);
  const after = Number(
    await page.getByRole("spinbutton", { name }).first().getAttribute(
      "aria-valuenow",
    ),
  );
  const want = before + -dy * MS_PER_PX;
  const ok = Math.abs(after - want) < 1;
  console.log(
    `${ok ? "ok  " : "FAIL"} ${name}: ${before} → ${after} (wanted ${want}), ` +
      `grip ${Math.round(box.width)}px`,
  );
  if (!ok) failures.push(`${name}: moved to ${after}, wanted ${want}`);
}

// A peer trajectory needs a moment before it has a row to drag. The
// property picker is the trajectory's own insert control, as against the
// duration row's "Insert @playhead" button beside it.
await page
  .getByRole("combobox", { name: "State a property at the playhead" })
  .selectOption({ index: 1 });
await page.waitForTimeout(400);

await scrub("Time this name took effect", -30);
await scrub("Time this name took effect", 20);
await scrub("Peer start time", -30);

// The session panel's rows, whose list keys once carried the moment's
// own time — the drag died after one step there and nowhere else.
const rows = page.locator("button.ocv-session-row");
if (await rows.count() === 0) {
  failures.push("no session to inspect from the peer's connections");
} else {
  await rows.first().click();
  await page.waitForTimeout(400);
  const picker = page.getByRole("combobox", {
    name: "State a property at the playhead",
  });
  if (await picker.count() > 0) {
    await picker.selectOption({ index: 1 });
    await page.waitForTimeout(400);
  }
  await scrub("Keyframe 1 time", -30);
  await scrub("Keyframe 1 time", 20);

  // What a reader who drags "the row" actually grabs: the value editor,
  // which is not a scrub. It is allowed not to move the time; the check
  // is that it is not the whole row, which `MIN_GRIP_PX` above holds.
  const spin = page.getByRole("spinbutton", { name: "Keyframe 1 time" })
    .first();
  const before = await spin.getAttribute("aria-valuenow");
  const cell = await page.evaluate(() => {
    const el = document.querySelector(
      'aside select[aria-label^="New "], aside input.ocv-input',
    );
    const r = el?.getBoundingClientRect();
    return r ? { x: r.x, y: r.y, w: r.width } : null;
  });
  if (cell) {
    await page.mouse.move(cell.x + cell.w / 2, cell.y + 11);
    await page.mouse.down();
    for (let i = 1; i <= 8; i++) {
      await page.mouse.move(cell.x + cell.w / 2, cell.y + 11 - i * 5);
    }
    await page.mouse.up();
    await page.waitForTimeout(200);
    const after = await page
      .getByRole("spinbutton", { name: "Keyframe 1 time" })
      .first()
      .getAttribute("aria-valuenow");
    console.log(
      `note  dragging the value cell (${Math.round(cell.w)}px) leaves the ` +
        `time at ${after} (was ${before})`,
    );
  }
}

await browser.close();
if (failures.length > 0) {
  console.log(`\nFAIL — ${failures.length}`);
  for (const f of failures) console.log(`  ${f}`);
  Deno.exit(1);
}
console.log("\nPASS — every timing row scrubs by the distance dragged");
