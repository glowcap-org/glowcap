// Where the rows of a log stand on screen, read before React changes the log
// and answered after it: a row the change moved travels to its new place.
//
// A line that lands moves every row above it by its own height in one frame.
// Here those rows cover that distance over a few frames, and the line rises
// with them from behind the composer. Nothing waits. The log is laid out and
// scrolled at once, and only the drawing trails it.
//
// Each move adds to whatever move is still running, so lines that land close
// together carry the rows on and never restart them. A new row is never drawn
// over the row that is leaving its place, and never past the end of a log
// that scrolls, where it would lengthen what the log can scroll. A row that
// grew starts where it stood, and that can be past the end: `overhang` says
// how far, for whoever reads where the log ends.

import { Component, type RefObject } from "react";
import { still, TRAVEL } from "../motion.ts";

/** One row as it stood, and what each of its parts said. */
type Stood = { box: DOMRect; said: readonly string[] };
/** The rows near the reader before a change. */
export type LogStanding = ReadonlyMap<Element, Stood>;

/** The part of the log a reader can see. */
function view(log: Element): { top: number; bottom: number } {
	const box = log.getBoundingClientRect();
	return { top: Math.max(box.top, 0), bottom: Math.min(box.bottom, globalThis.innerHeight) };
}

/** The rows within one screen of what the reader sees, first to last. A row
 * farther off cannot travel into view. The rows stand in order down the log,
 * so the first of them is found by halving, and a long log costs no more
 * than a short one. */
function rowsNear(log: Element): [Element, DOMRect][] {
	const { top, bottom } = view(log);
	const screen = bottom - top;
	const all = log.children;
	let first = 0;
	let after = all.length;
	while (first < after) {
		const middle = (first + after) >> 1;
		if (all[middle].getBoundingClientRect().bottom < top - screen) first = middle + 1;
		else after = middle;
	}
	const rows: [Element, DOMRect][] = [];
	for (let at = first; at < all.length; at++) {
		const box = all[at].getBoundingClientRect();
		if (box.top > bottom + screen) break;
		rows.push([all[at], box]);
	}
	return rows;
}

/** A row that says `data-motion="reflow"` changes size where it stands. Every
 * other row grows at its end, as a group does when a line joins it. */
function reflows(row: Element): boolean {
	return row.getAttribute("data-motion") === "reflow";
}

function read(log: Element): LogStanding {
	const stood = new Map<Element, Stood>();
	for (const [row, box] of rowsNear(log)) {
		stood.set(row, { box, said: reflows(row) ? [...row.children].map((part) => part.textContent ?? "") : [] });
	}
	return stood;
}

/** One row for planning a move: where it stood, or null when it is new, where
 * the log puts it now, and how far the moves still running draw it from there. */
export type TravelRow = {
	was: { top: number; bottom: number } | null;
	now: { top: number; bottom: number };
	reflows: boolean;
	underway: number;
};

/** Where a row starts its move. It is drawn `by` from its place. `covered` of
 * its top is not drawn, and that much is let out evenly until the move is
 * `until` of the way there. */
export type TravelStart = { by: number; covered: number; until: number };

/** Where each row starts, first row to last.
 *
 * A row that stood before starts where it stood. One that moved farther than
 * `screen` is at a different place in the log, and is drawn there.
 *
 * New rows that land together move together. With a row that stood before
 * after them, they move as it does. At the end of the log they move as the
 * row before them does, and start no lower than `end`. The row before them
 * may start farther off than they do, and then it stands over their place:
 * each is covered down to that row's edge, and let out as the edge passes. */
export function planTravel(rows: readonly TravelRow[], screen: number, end: number): TravelStart[] {
	const room = (row: TravelRow) => Math.max(0, end - row.now.bottom);
	/** How far each row that stood before is drawn from its place as it starts. */
	const stood = rows.map((row) => {
		if (row.was == null) return null;
		const moved = row.reflows ? row.was.bottom - row.now.bottom : row.was.top - row.now.top;
		return row.underway + (Math.abs(moved) > screen ? 0 : moved);
	});
	const starts: TravelStart[] = [];
	let before = 0;
	for (let at = 0; at < rows.length;) {
		const drawn = stood[at];
		if (drawn != null) {
			starts.push({ by: drawn - rows[at].underway, covered: 0, until: 1 });
			before = drawn;
			at++;
			continue;
		}
		let next = at;
		while (next < rows.length && stood[next] == null) next++;
		const by = stood[next] ?? Math.min(before, room(rows[next - 1]));
		const over = before - by;
		const top = rows[at].now.top;
		for (; at < next; at++) {
			const covered = Math.max(0, over - (rows[at].now.top - top));
			starts.push({ by, covered, until: covered > 0 ? covered / over : 1 });
		}
	}
	return starts;
}

/** How far a row is drawn from where the log puts it, by moves still running. */
function underway(row: Element): number {
	return row.getAnimations().length === 0 ? 0 : new DOMMatrixReadOnly(getComputedStyle(row).transform).m42;
}

/** How far a log that scrolls reports itself longer than it is. A scroll
 * region counts what is drawn in it, so a row drawn past the log's end
 * lengthens it until the row arrives. Every row in motion is measured: a row
 * can still be past the end when a line lands after it. */
export function overhang(log: Element): number {
	const last = log.lastElementChild;
	if (last == null) return 0;
	let farthest = -Infinity;
	for (const move of log.getAnimations({ subtree: true })) {
		const row = move.effect instanceof KeyframeEffect ? move.effect.target : null;
		if (row?.parentElement === log) farthest = Math.max(farthest, row.getBoundingClientRect().bottom);
	}
	if (farthest === -Infinity) return 0;
	const under = (parseFloat(getComputedStyle(log).paddingBottom) || 0) +
		(parseFloat(getComputedStyle(last).marginBottom) || 0);
	const end = last.getBoundingClientRect().bottom - underway(last) + under;
	return Math.max(0, Math.floor(farthest - end));
}

/** The place a new row drawn lower would lengthen what the log can scroll:
 * the end of a log that scrolls, under its last row and the room the composer
 * stands in. A log that cuts off what passes its end, as the page that
 * scrolls whole does, has no such place. */
function endOf(log: Element): number {
	const style = getComputedStyle(log);
	if (style.overflowY === "clip") return Infinity;
	return (log.lastElementChild?.getBoundingClientRect().bottom ?? 0) + (parseFloat(style.paddingBottom) || 0);
}

/** Send each row from where it stood to where the log now puts it. */
export function travel(log: Element, stood: LogStanding): void {
	const { top, bottom } = view(log);
	const rows = rowsNear(log);
	const end = endOf(log);
	const starts = planTravel(
		rows.map(([row, now]) => {
			const was = stood.get(row)?.box ?? null;
			return { was, now, reflows: reflows(row), underway: was == null ? 0 : underway(row) };
		}),
		bottom - top,
		end,
	);
	rows.forEach(([row, box], at) => {
		const { by, covered, until } = starts[at];
		move(row, by);
		uncover(row, covered, until);
		const was = stood.get(row);
		if (was != null && reflows(row)) reveal(row, was, box);
	});
}

function move(row: Element, by: number): void {
	if (Math.abs(by) < 1) return;
	row.animate([{ transform: `translateY(${by}px)` }, { transform: "translateY(0)" }], {
		...TRAVEL,
		composite: "add",
	});
}

/** Everything of a row but its top edge is drawn, however far it reaches. */
const REACH = "-100vmax";

function uncover(row: Element, covered: number, until: number): void {
	if (covered < 1) return;
	const open = { clipPath: `inset(0px ${REACH} ${REACH} ${REACH})` };
	row.animate(
		[
			{ clipPath: `inset(${covered}px ${REACH} ${REACH} ${REACH})`, offset: 0 },
			...(until < 1 ? [{ ...open, offset: until }] : []),
			{ ...open, offset: 1 },
		],
		TRAVEL,
	);
}

/** A row that grew where it stands opens from the box it was, and a part of
 * it that says something new fades in. A row that shrank is drawn as it is. */
function reveal(row: Element, was: Stood, box: DOMRect): void {
	const up = Math.max(0, box.height - was.box.height);
	const out = Math.max(0, box.width - was.box.width);
	if (up >= 1 || out >= 1) {
		const round = getComputedStyle(row).borderRadius;
		row.animate(
			[{ clipPath: `inset(${up}px ${out}px 0 0 round ${round})` }, { clipPath: `inset(0 round ${round})` }],
			TRAVEL,
		);
	}
	[...row.children].forEach((part, at) => {
		const said = was.said[at];
		if (said != null && said !== (part.textContent ?? "")) part.animate([{ opacity: 0 }, { opacity: 1 }], TRAVEL);
	});
}

/** Reads the log at the one moment before React changes it, which only a
 * class component is given, and leaves the reading for the owner of the
 * scroll position to answer once that position is set. `drawn` is what the
 * log is given to draw, and the reading is taken when one of those is
 * replaced within one conversation, so a keystroke costs no layout. A change
 * the log draws from its own reading of the store is drawn where it lands. */
export class LogStood extends Component<{
	log: RefObject<HTMLElement | null>;
	conversation: string | null;
	drawn: Readonly<Record<string, unknown>>;
	into: RefObject<LogStanding | null>;
}> {
	override getSnapshotBeforeUpdate(before: Readonly<LogStood["props"]>): LogStanding | null {
		const { log, conversation, drawn } = this.props;
		if (conversation == null || before.conversation !== conversation) return null;
		if (Object.keys(drawn).every((name) => drawn[name] === before.drawn[name])) return null;
		return log.current == null || still() ? null : read(log.current);
	}
	override componentDidUpdate(_props: unknown, _state: unknown, stood: LogStanding | null): void {
		this.props.into.current = stood;
	}
	override render(): null {
		return null;
	}
}
