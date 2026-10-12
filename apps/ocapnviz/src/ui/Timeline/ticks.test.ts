/**
 * Tick cascade smoke tests. The cascade transitions through ms →
 * s → min → hr → day → mo → yr units. These tests pin down the
 * unit-label boundaries so a future re-ordering of `STEPS` can't
 * silently swap a "1d" tick for "24h" (which would be visually
 * jumpy at the day/hour boundary).
 */
import { assertEquals } from "@std/assert";
import { generateTicks, pickTickStep } from "./ticks.ts";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const MONTH = 30 * DAY;
const YEAR = 365 * DAY;

Deno.test("pickTickStep: 1-second spacing at modest zoom", () => {
	// pxPerMs = 0.1 → 100ms = 10px, 1s = 100px. Target 80px so we
	// pick the smallest step ≥ 80px: that's 1s (100px).
	const step = pickTickStep(0.1, 80);
	assertEquals(step.format(1000), "1s");
});

Deno.test("pickTickStep: 1-hour ticks at multi-hour zoom-out", () => {
	// pxPerMs = 80 / HOUR → exactly one major every 80px when major=1h.
	const step = pickTickStep(80 / HOUR, 80);
	assertEquals(step.major, HOUR);
	assertEquals(step.format(HOUR), "1h");
	assertEquals(step.format(3 * HOUR), "3h");
});

Deno.test("pickTickStep: day-scale ticks land in days", () => {
	const step = pickTickStep(80 / DAY, 80);
	assertEquals(step.major, DAY);
	assertEquals(step.format(DAY), "1d");
	assertEquals(step.format(7 * DAY), "7d");
});

Deno.test("pickTickStep: month-scale ticks land in months", () => {
	const step = pickTickStep(80 / MONTH, 80);
	assertEquals(step.major, MONTH);
	assertEquals(step.format(MONTH), "1mo");
	assertEquals(step.format(3 * MONTH), "3mo");
});

Deno.test("pickTickStep: year-scale ticks land in years", () => {
	const step = pickTickStep(80 / YEAR, 80);
	assertEquals(step.major, YEAR);
	assertEquals(step.format(YEAR), "1yr");
	assertEquals(step.format(2 * YEAR), "2yr");
});

Deno.test("pickTickStep: extreme zoom-out caps at largest step", () => {
	// Even at "100yr fits in 1px" levels, picker returns the last
	// (largest) step instead of NaN-ing or throwing.
	const step = pickTickStep(1e-15, 80);
	assertEquals(step.major, 10 * YEAR);
});

Deno.test("generateTicks: year-scale window emits year-spaced majors", () => {
	// Window covers ~3 years; expect majors at 0, 1yr, 2yr, 3yr.
	const step = pickTickStep(80 / YEAR, 80);
	const { major } = generateTicks(0, 3 * YEAR, step);
	assertEquals(major.length, 4);
	assertEquals(major[0], 0);
	assertEquals(major[major.length - 1], 3 * YEAR);
});
