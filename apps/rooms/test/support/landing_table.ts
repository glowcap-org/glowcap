// The mechanism behind the tables that walk every start against every event
// on a page holding management access. Each cell is a test that brings a
// fresh page to its start, runs the event, lets what it started settle, and
// asserts where the page lands, then closes the page with every handle freed
// once. A cell the table leaves out is counted under the reason it names, and
// the table pins both counts to literals, so a cell that drops out shows.
import { assertEquals } from "../assert.ts";
import { closedClean } from "./held_access_gestures.ts";
import type { Page } from "./held_access_page.ts";

/** One cell: how its page reaches the start, the event, and where it lands. */
export interface Cell<S, M> {
	/** A fresh page at the cell's start, and whatever the cell reads of it. */
	start(): Promise<S>;
	/** Run the event, and answer what it met. */
	event(at: S): Promise<M>;
	/** Wait out what the event started. */
	settle(at: S): Promise<void>;
	/** Where the page landed, in the table's words. */
	landing(at: S, met: M): string;
	readonly expected: string;
	/** What else holds where it landed. */
	check?(at: S, landed: string): void | Promise<void>;
	page(at: S): Page;
}

export class LandingTable {
	readonly #name: string;
	#rows = 0;
	readonly #left = new Map<string, number>();
	#cells = 0;

	constructor(name: string) {
		this.#name = name;
	}
	/** Register `cell` as the test `name`. */
	row<S, M>(name: string, cell: Cell<S, M>): void {
		this.#cells++;
		this.#rows++;
		Deno.test(name, async () => {
			const at = await cell.start();
			const met = await cell.event(at);
			await cell.settle(at);
			const landed = cell.landing(at, met);
			assertEquals(landed, cell.expected);
			await cell.check?.(at, landed);
			await closedClean(cell.page(at));
		});
	}
	/** Count a cell the table leaves out, for `why`. */
	leave(why: string): void {
		this.#cells++;
		this.#left.set(why, (this.#left.get(why) ?? 0) + 1);
	}
	/** Hold the table to `rows` tests, and to `left` cells left out under each
	 * reason, of `cells`, every combination its axes make. */
	pin(cells: number, rows: number, left: Record<string, number>): void {
		Deno.test(`the ${this.#name} rows are every cell, less the named ones left out`, () => {
			const sorted = (counts: Iterable<[string, number]>) => [...counts].sort(([a], [b]) => a < b ? -1 : 1);
			assertEquals(
				[this.#cells, this.#rows, sorted(this.#left)],
				[cells, rows, sorted(Object.entries(left))],
				`the ${this.#name} table's cells`,
			);
		});
	}
}
