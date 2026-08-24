/**
 * Adaptive tick generation for the timeline ruler.
 *
 * Goal: at any zoom level, render major ticks with comfortable
 * pixel spacing (target ~80px) and label them in a unit that's
 * easy to read (1ms, 10ms, 100ms, 1s, 10s, 1min, …). Minor ticks
 * fill in between for visual rhythm without labels.
 *
 * The cascade is a pre-defined power-of-N sequence so transitions
 * between zoom levels feel snappy: as you zoom in, "1s" ticks
 * smoothly hand off to "100ms" ticks at the boundary where 100ms
 * ticks reach the target spacing.
 */

export type TickStep = {
	/** Distance between major ticks in ms. */
	major: number;
	/** Distance between minor ticks in ms (`major / k` for some k). */
	minor: number;
	/**
	 * How to format a major-tick label given its value in ms.
	 * Returns the label string (e.g., "1.5s", "200ms", "1min").
	 */
	format: (ms: number) => string;
};

// Unit anchors. Months and years are NOT calendar-accurate — they
// approximate (30 days / 365 days) because the timeline measures
// elapsed simulation time, not wall-clock dates. This is the same
// approximation Flash / After Effects / Premiere use for their
// long-zoom rulers: the label is a navigational hint, not a date
// stamp.
const SECOND = 1_000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const MONTH = 30 * DAY;
const YEAR = 365 * DAY;

/**
 * Pre-defined tick steps in increasing major-spacing order. The
 * ruler picks the smallest step whose `major` × pxPerMs ≥
 * targetMajorPx. Each entry's `minor` is chosen to give 4–10 minor
 * ticks per major.
 *
 * The cascade extends from `1ms` all the way to `5yr` so Live mode
 * (where `MIN_ZOOM_LIVE` lets the window grow to many times the
 * captured range) can still render meaningful tick labels when the
 * user is staring at "the last year's worth of context" around a
 * recent capture.
 */
const STEPS: TickStep[] = [
	{ major: 1, minor: 1, format: (ms) => `${ms}ms` },
	{ major: 2, minor: 1, format: (ms) => `${ms}ms` },
	{ major: 5, minor: 1, format: (ms) => `${ms}ms` },
	{ major: 10, minor: 2, format: (ms) => `${ms}ms` },
	{ major: 20, minor: 5, format: (ms) => `${ms}ms` },
	{ major: 50, minor: 10, format: (ms) => `${ms}ms` },
	{ major: 100, minor: 20, format: (ms) => `${ms}ms` },
	{ major: 200, minor: 50, format: (ms) => `${ms}ms` },
	{ major: 500, minor: 100, format: (ms) => `${ms}ms` },
	{ major: SECOND, minor: 200, format: formatSeconds },
	{ major: 2 * SECOND, minor: 500, format: formatSeconds },
	{ major: 5 * SECOND, minor: SECOND, format: formatSeconds },
	{ major: 10 * SECOND, minor: 2 * SECOND, format: formatSeconds },
	{ major: 30 * SECOND, minor: 5 * SECOND, format: formatSeconds },
	{ major: MINUTE, minor: 10 * SECOND, format: formatMinutes },
	{ major: 5 * MINUTE, minor: MINUTE, format: formatMinutes },
	{ major: 10 * MINUTE, minor: MINUTE, format: formatMinutes },
	{ major: 30 * MINUTE, minor: 5 * MINUTE, format: formatHours },
	{ major: HOUR, minor: 10 * MINUTE, format: formatHours },
	{ major: 2 * HOUR, minor: 30 * MINUTE, format: formatHours },
	{ major: 6 * HOUR, minor: HOUR, format: formatHours },
	{ major: 12 * HOUR, minor: 2 * HOUR, format: formatHours },
	{ major: DAY, minor: 6 * HOUR, format: formatDays },
	{ major: 2 * DAY, minor: 12 * HOUR, format: formatDays },
	{ major: 7 * DAY, minor: DAY, format: formatDays },
	{ major: 14 * DAY, minor: 7 * DAY, format: formatDays },
	{ major: MONTH, minor: 7 * DAY, format: formatMonths },
	{ major: 3 * MONTH, minor: MONTH, format: formatMonths },
	{ major: 6 * MONTH, minor: MONTH, format: formatMonths },
	{ major: YEAR, minor: 3 * MONTH, format: formatYears },
	{ major: 2 * YEAR, minor: 6 * MONTH, format: formatYears },
	{ major: 5 * YEAR, minor: YEAR, format: formatYears },
	{ major: 10 * YEAR, minor: YEAR, format: formatYears },
];

function formatSeconds(ms: number): string {
	const s = ms / SECOND;
	return Number.isInteger(s) ? `${s}s` : `${s.toFixed(1)}s`;
}

function formatMinutes(ms: number): string {
	const totalSec = Math.round(ms / SECOND);
	const min = Math.floor(totalSec / 60);
	const sec = totalSec - min * 60;
	return sec === 0 ? `${min}min` : `${min}m${sec}s`;
}

function formatHours(ms: number): string {
	const totalMin = Math.round(ms / MINUTE);
	const hr = Math.floor(totalMin / 60);
	const min = totalMin - hr * 60;
	return min === 0 ? `${hr}h` : `${hr}h${min}m`;
}

function formatDays(ms: number): string {
	const d = ms / DAY;
	return Number.isInteger(d) ? `${d}d` : `${d.toFixed(1)}d`;
}

function formatMonths(ms: number): string {
	const mo = ms / MONTH;
	return Number.isInteger(mo) ? `${mo}mo` : `${mo.toFixed(1)}mo`;
}

function formatYears(ms: number): string {
	const y = ms / YEAR;
	return Number.isInteger(y) ? `${y}yr` : `${y.toFixed(1)}yr`;
}

/**
 * Pick the tick step whose major spacing is just large enough to
 * reach the target pixel spacing. Returns the smallest entry whose
 * `major × pxPerMs ≥ targetMajorPx`. Falls back to the largest
 * step at very low zoom; falls back to the smallest at very high
 * zoom (sub-millisecond rendering isn't supported — engine clock
 * is in ms).
 */
export function pickTickStep(
	pxPerMs: number,
	targetMajorPx: number,
): TickStep {
	for (const step of STEPS) {
		if (step.major * pxPerMs >= targetMajorPx) return step;
	}
	return STEPS[STEPS.length - 1]!;
}

/**
 * Generate the major + minor ticks visible inside `[startMs, endMs]`
 * for the chosen `step`. Returns absolute ms positions; caller maps
 * them to pixels via `tToPx`.
 *
 * Snaps to multiples of `major` / `minor` so ticks remain visually
 * stable as the window pans (a `100ms` tick at t=300ms stays at
 * t=300ms, doesn't drift with the window edges).
 */
export function generateTicks(
	startMs: number,
	endMs: number,
	step: TickStep,
): { major: number[]; minor: number[] } {
	const major: number[] = [];
	const minor: number[] = [];
	const firstMajor = Math.ceil(startMs / step.major) * step.major;
	for (let t = firstMajor; t <= endMs; t += step.major) {
		major.push(t);
	}
	if (step.minor < step.major) {
		const firstMinor = Math.ceil(startMs / step.minor) * step.minor;
		for (let t = firstMinor; t <= endMs; t += step.minor) {
			// Skip positions that are already a major tick; major edges
			// own the visual emphasis at that point.
			if (t % step.major !== 0) minor.push(t);
		}
	}
	return { major, minor };
}
