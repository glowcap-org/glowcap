// What the reopen proof keeps so a failure explains itself.
//
// `dm_reopen_proof.ts` fails when a reopened conversation has no second
// connection, and a single failure says only that the timeline did not show
// one. This capture keeps the evidence that tells the next failure apart:
// the viewer's own arrivals, the proof's wait boundaries, and what each
// WebRTC tab's peer connections and DataChannels did. A failing proof prints
// one snapshot before cleanup. A passing proof emits none.
//
// What it can show. A viewer arrival is a record the live trace delivered to
// this process. A page event is something the browser did on a channel, or a
// peer's signaling, ICE connection or connection event, whose `ready` holds
// the state read when the event was dispatched. The last such state seen can
// differ from the peer's current one. A phase marker is where the proof stood,
// with the number of viewer arrivals at that moment.
// Times are each process's own `performance.now()`, plus
// `performance.timeOrigin + performance.now()` for placing them against each
// other on one machine. That placement is approximate: clocks differ and a
// page snapshot is read after the failure, so no exact order across processes
// is claimed. Each tab also lists the documents that installed the observer,
// told to the host at startup, so a reload shows as a second install and a
// same-document navigation does not.
//
// What it cannot show. The trace publisher drops its oldest queued records
// under pressure and discards non-replayed records while disconnected,
// without setting `dropped`, and the server can omit records for an open it
// never saw. A gap or an absence in these records is therefore never proof
// that nothing happened. A page that reports a message arrived in the browser
// does not show the Rust queue, the reader or the core received it. Records
// older than a ring's oldest retained entry are gone, and the counts say how
// many. No window of time is guaranteed to be covered, because that depends on
// traffic.
//
// Bounds. The host keeps the most recent 4000 viewer arrivals, 500 phase
// markers, and per tab 50 document installs and 50 navigation events. Each
// page keeps its most recent 2000 events. A viewer arrival holds only the
// allowlisted fields, and every string in it is cut to 120 UTF-16 code units.
// Phase and tab labels are cut to 60 code units and details and errors to 160.
// These limits count code units, not bytes, so the serialized and in-memory
// size of a record depends on its content, on JSON escaping and on the
// engine's heap layout. No byte total is claimed.
//
// What the endpoint stamps. This Rooms trace endpoint overwrites each record's
// `sim_t_ns` with its own clock and adds `seq` and `epoch`. They order records
// within the endpoint and name its process lifetime. They are not producer
// clocks, and they have no fixed offset to the host or page `performance`
// clocks. On connect, a viewer first receives a replay of the current live
// topology (the open sessions and their latest annotations), flagged `replay`
// and ended by `trace.replay-end`. The replay is not earlier protocol traffic.
//
// Recording and report emission are contained: a failure there is counted and
// never reaches the proof, the timeline or the page. `instrument` awaits
// browser setup and can fail the proof before the scenario starts. The global
// proof deadline fires from a timer and cannot be caught here, so a run that
// hangs for its whole deadline prints no snapshot.

import type { BrowserContext, Page } from "playwright";
import {
	type DocumentInstall,
	installPageCapture,
	PAGE_CAPTURE_BINDING,
	PAGE_CAPTURE_KEY,
	type PageSnapshot,
} from "./reopen_capture_page.ts";

/** Viewer arrivals kept. */
const VIEWER_CAPACITY = 4000;
/** Events kept per page document. */
const PAGE_CAPACITY = 2000;
/** Phase markers kept. */
const PHASE_CAPACITY = 500;
/** Document installs and navigation events kept per tab. */
const TAB_HISTORY_CAPACITY = 50;
/** How long one page gets to answer a snapshot. */
const SNAPSHOT_MS = 3_000;
/** Longest stored text from a viewer record. */
const FIELD_TEXT = 120;
/** Longest stored label from the proof. */
const LABEL_TEXT = 60;
/** Longest stored detail or error. */
const DETAIL_TEXT = 160;

/** A fixed-capacity ring that keeps the most recent items and counts what it
 * evicted. */
export class Ring<T> {
	readonly #items: T[] = [];
	#seen = 0;
	readonly capacity: number;

	constructor(capacity: number) {
		this.capacity = capacity;
	}

	push(item: T): void {
		this.#seen++;
		this.#items.push(item);
		if (this.#items.length > this.capacity) this.#items.shift();
	}

	get seen(): number {
		return this.#seen;
	}
	get retained(): number {
		return this.#items.length;
	}
	get evicted(): number {
		return this.#seen - this.#items.length;
	}
	items(): T[] {
		return [...this.#items];
	}
}

/** A name and the first line of a message, bounded. Never the stack, and never
 * anything else the error carries. */
export function clipError(error: unknown): string {
	try {
		const name = error instanceof Error ? error.name : "error";
		const message = error instanceof Error ? error.message : String(error);
		return `${name}: ${message}`.split("\n")[0].slice(0, DETAIL_TEXT);
	} catch {
		return "unreadable error"; // tolerant: the label is a diagnostic and never worth failing a report.
	}
}

/** The record fields kept. Message bodies, capabilities, sturdyrefs, locator
 * hints, bytes and arbitrary meta are not among them. */
const VIEWER_FIELDS = [
	"kind",
	"session",
	"session_id",
	"transport",
	"a_label",
	"outbound",
	"sim_t_ns",
	"seq",
	"epoch",
	"replay",
	"dropped",
] as const;

export interface ViewerArrival {
	/** Arrival sequence in this viewer, from 1. */
	i: number;
	/** Host `performance.now()`, or null when the clock failed. */
	t: number | null;
	[field: string]: string | number | boolean | null;
}

export interface PhaseMarker {
	n: number;
	t: number | null;
	phase: string;
	who: string;
	event: "begin" | "end" | "fail" | "failure";
	/** Viewer arrivals seen when the marker was written. */
	arrivals: number;
	detail?: string;
	error?: string;
}

/** The proof's way to reach a tab: evaluate an expression in it and hear of its
 * navigations. A Playwright page adapts through `fromPlaywright`. */
export interface CapturePage {
	evaluate(expression: string): Promise<unknown>;
	onNavigate(listener: () => void): void;
}

export function fromPlaywright(page: Page): CapturePage {
	return {
		evaluate: (expression) => page.evaluate(expression),
		onNavigate: (listener) => {
			page.on("framenavigated", (frame) => {
				if (frame === page.mainFrame()) listener();
			});
		},
	};
}

interface Stamped {
	/** Host `performance.now()`, or null when the clock failed. */
	t: number | null;
}

interface DocumentRecord extends Stamped, DocumentInstall {}

/** What the host heard about one tab's documents and navigations. */
class Ledger {
	readonly documents: Ring<DocumentRecord>;
	readonly navigations: Ring<Stamped & { n: number }>;
	malformed = 0;
	childFrames = 0;

	constructor(capacity: number) {
		this.documents = new Ring(capacity);
		this.navigations = new Ring(capacity);
	}
}

interface Tab {
	name: string;
	mode: string;
	instrumented: boolean;
	page: CapturePage;
}

/** What the documents a tab installed say about resets. `unknown`: the host
 * heard no install, or heard a malformed one it cannot place. `single`: one
 * install and no malformed one, so no reset. `reset`: more than one top-level
 * document installed, so the page snapshot covers only the last. */
export type DocumentHistory = "unknown" | "single" | "reset" | "not-instrumented";

export interface TabReport {
	name: string;
	mode: string;
	/** `not-instrumented`: this tab's mode installs no page capture.
	 * `uninstalled`: the document answered with no capture installed.
	 * `unavailable`: the document did not answer, or its read failed. `ok`: a
	 * snapshot follows. */
	status: "ok" | "not-instrumented" | "uninstalled" | "unavailable";
	reason?: string;
	history: DocumentHistory;
	documents: {
		seen: number;
		evicted: number;
		/** Notifications the host could not read. */
		malformed: number;
		/** Installs from child frames, which a top-level tab ignores. */
		childFrames: number;
		retained: DocumentRecord[];
	};
	/** Main-frame navigation events, same-document ones included, so a count
	 * says nothing about resets. */
	navigations: { seen: number; evicted: number; retained: Array<Stamped & { n: number }> };
	hostBefore: number | null;
	hostAfter: number | null;
	/** Whether the snapshot's document is the newest install the host heard. */
	snapshotIsNewestInstall: boolean | null;
	page?: PageSnapshot;
}

export interface FailureReport {
	error: string;
	host: { timeOrigin: number; now: number | null };
	faults: number;
	viewer: {
		capacity: number;
		/** Records that reached the viewer callback, whether or not kept. */
		arrived: number;
		/** Arrivals whose projection failed, so they are in `arrived` only. */
		projectionFailures: number;
		retained: number;
		evicted: number;
		oldest: { i: number; t: number | null } | null;
		newest: { i: number; t: number | null } | null;
		closed: { t: number | null; error?: string } | "open";
		arrivals: ViewerArrival[];
	};
	phases: { seen: number; evicted: number; markers: PhaseMarker[] };
	tabs: TabReport[];
	timeline: string;
}

/** Run `work` and report its value or a bounded error, never rejecting. A late
 * completion after the bound is observed and discarded, and the timer is
 * cleared either way. */
async function bounded<T>(
	work: Promise<T>,
	ms: number,
): Promise<{ ok: true; value: T } | { ok: false; error: string }> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	const settled = work.then(
		(value) => ({ ok: true, value }) as const,
		(error) => ({ ok: false, error: clipError(error) }) as const,
	);
	const expiry = new Promise<{ ok: false; error: string }>((resolve) => {
		timer = setTimeout(() => resolve({ ok: false, error: `no answer within ${ms}ms` }), ms);
	});
	try {
		return await Promise.race([settled, expiry]);
	} finally {
		clearTimeout(timer);
	}
}

export interface CaptureOptions {
	clock?: { now(): number; timeOrigin: number };
	snapshotMs?: number;
	/** Capacity of each tab's document and navigation rings. */
	historyCapacity?: number;
}

export class ReopenCapture {
	readonly #arrivals = new Ring<ViewerArrival>(VIEWER_CAPACITY);
	readonly #phases = new Ring<PhaseMarker>(PHASE_CAPACITY);
	readonly #tabs = new Map<object, Tab>();
	readonly #ledgers = new Map<object, Ledger>();
	#arrived = 0;
	#projectionFailures = 0;
	#faults = 0;
	#closed: { t: number | null; error?: string } | "open" = "open";
	#markers = 0;
	readonly #clock: { now(): number; timeOrigin: number };
	readonly #snapshotMs: number;
	readonly #historyCapacity: number;

	constructor(options: CaptureOptions = {}) {
		this.#clock = options.clock ?? performance;
		this.#snapshotMs = options.snapshotMs ?? SNAPSHOT_MS;
		this.#historyCapacity = options.historyCapacity ?? TAB_HISTORY_CAPACITY;
	}

	/** The host clock, or null when it fails. A failed clock never loses a
	 * record: the record is kept without its time. */
	#stamp(): number | null {
		try {
			return this.#clock.now();
		} catch {
			this.#faults++; // tolerant: a record without a time is still a record, and the count says the clock failed.
			return null;
		}
	}

	#epoch(stamp: number | null): number | null {
		return stamp === null ? null : this.#clock.timeOrigin + stamp;
	}

	/** Keep the allowlisted fields of one viewer record. Called before the
	 * timeline filters the record. It never throws, and it counts the arrival
	 * before anything that can fail, so `arrived` is every record delivered. */
	viewer(record: unknown): void {
		const i = ++this.#arrived;
		try {
			const raw = record as Record<string, unknown>;
			const kept: ViewerArrival = { i, t: this.#stamp() };
			const fields: readonly string[] = raw.kind === "trace.producer-left"
				? [...VIEWER_FIELDS, "scope"]
				: VIEWER_FIELDS;
			for (const field of fields) {
				const value = raw[field];
				if (typeof value === "string") kept[field] = value.slice(0, FIELD_TEXT);
				else if (typeof value === "number" || typeof value === "boolean") kept[field] = value;
			}
			this.#arrivals.push(kept);
		} catch {
			this.#projectionFailures++; // tolerant: the arrival is counted, and the timeline still gets the record.
		}
	}

	/** Note when the viewer session ends, however it ends. The whole chain is
	 * observed here, and the promise still belongs to its owner. The closure is
	 * recorded even if its time cannot be read. */
	observeClosed(closed: Promise<void>): void {
		const settle = (error?: string): void => {
			const t = this.#stamp();
			this.#closed = error === undefined ? { t } : { t, error };
		};
		closed.then(
			() => settle(),
			(error) => settle(clipError(error)),
		).catch(() => {
			this.#faults++; // tolerant: the closure bookkeeping failed and the count says so.
		});
	}

	/** Install the page observer in every document `context` loads, and the
	 * binding each document tells the host its identity through. The binding
	 * goes first so it exists before the observer runs. */
	async instrument(context: BrowserContext): Promise<void> {
		await context.exposeBinding(PAGE_CAPTURE_BINDING, (source, payload) => {
			this.documentInstalled(source.page, source.frame === source.page.mainFrame(), payload);
		});
		const call = `(${installPageCapture.toString()})(globalThis, ${JSON.stringify(PAGE_CAPTURE_KEY)}, ${
			JSON.stringify(PAGE_CAPTURE_BINDING)
		}, ${PAGE_CAPACITY});`;
		await context.addInitScript({ content: call });
	}

	#ledger(key: object): Ledger {
		let ledger = this.#ledgers.get(key);
		if (ledger === undefined) {
			ledger = new Ledger(this.#historyCapacity);
			this.#ledgers.set(key, ledger);
		}
		return ledger;
	}

	/** A document told the host it installed the observer. `topLevel` is whether
	 * it is the tab's main frame: a child frame is counted and ignored. A payload
	 * the host cannot read is counted, never thrown. */
	documentInstalled(key: object, topLevel: boolean, payload: unknown): void {
		try {
			const ledger = this.#ledger(key);
			if (!topLevel) {
				ledger.childFrames++;
				return;
			}
			const raw = payload as Partial<Record<keyof DocumentInstall, unknown>> | null;
			const installId = raw?.installId;
			const timeOrigin = raw?.timeOrigin;
			const origin = raw?.origin;
			if (typeof installId !== "string" || typeof timeOrigin !== "number" || typeof origin !== "string") {
				ledger.malformed++;
				return;
			}
			ledger.documents.push({
				installId: installId.slice(0, FIELD_TEXT),
				timeOrigin,
				origin: origin.slice(0, FIELD_TEXT),
				t: this.#stamp(),
			});
		} catch {
			this.#faults++; // tolerant: an unplaced notification shows as unknown history.
		}
	}

	/** Register a tab under `name`. `instrumented` is whether `instrument` ran
	 * on its context. */
	register(key: object, name: string, mode: string, instrumented: boolean, page: CapturePage): void {
		this.#tabs.set(key, { name: name.slice(0, LABEL_TEXT), mode: mode.slice(0, LABEL_TEXT), instrumented, page });
		const ledger = this.#ledger(key);
		page.onNavigate(() => {
			try {
				ledger.navigations.push({ n: ledger.navigations.seen + 1, t: this.#stamp() });
			} catch {
				this.#faults++; // tolerant: a missed navigation shows as a lower count.
			}
		});
	}

	/** The name a tab was registered under. */
	who(key: object): string {
		return this.#tabs.get(key)?.name ?? "unregistered";
	}

	#mark(event: PhaseMarker["event"], phase: string, who: string, detail?: string, error?: string): void {
		try {
			const marker: PhaseMarker = {
				n: ++this.#markers,
				t: this.#stamp(),
				phase: phase.slice(0, LABEL_TEXT),
				who: who.slice(0, LABEL_TEXT),
				event,
				arrivals: this.#arrived,
			};
			if (detail !== undefined) marker.detail = detail.slice(0, DETAIL_TEXT);
			if (error !== undefined) marker.error = error;
			this.#phases.push(marker);
		} catch {
			this.#faults++; // tolerant: a missing marker is visible as a gap in `n`.
		}
	}

	/** Run one of the proof's waits between a begin and an end marker. Returns
	 * what `work` returns and rethrows what it throws, unchanged. */
	async phase<T>(phase: string, who: string, work: () => Promise<T>, detail?: string): Promise<T> {
		this.#mark("begin", phase, who, detail);
		try {
			const value = await work();
			this.#mark("end", phase, who, detail);
			return value;
		} catch (error) {
			this.#mark("fail", phase, who, detail, clipError(error));
			throw error;
		}
	}

	#history(ledger: Ledger): DocumentHistory {
		const seen = ledger.documents.seen;
		if (seen > 1) return "reset";
		if (seen === 1 && ledger.malformed === 0) return "single";
		return "unknown";
	}

	#tabBase(tab: Tab, key: object): TabReport {
		const ledger = this.#ledger(key);
		const before = this.#epoch(this.#stamp());
		return {
			name: tab.name,
			mode: tab.mode,
			status: "unavailable",
			history: tab.instrumented ? this.#history(ledger) : "not-instrumented",
			documents: {
				seen: ledger.documents.seen,
				evicted: ledger.documents.evicted,
				malformed: ledger.malformed,
				childFrames: ledger.childFrames,
				retained: ledger.documents.items(),
			},
			navigations: {
				seen: ledger.navigations.seen,
				evicted: ledger.navigations.evicted,
				retained: ledger.navigations.items(),
			},
			hostBefore: before,
			hostAfter: before,
			snapshotIsNewestInstall: null,
		};
	}

	async #tab(key: object, tab: Tab): Promise<TabReport> {
		let report: TabReport | undefined;
		try {
			report = this.#tabBase(tab, key);
			if (!tab.instrumented) return { ...report, status: "not-instrumented" };
			const answer = await bounded(
				Promise.resolve().then(() =>
					tab.page.evaluate(`globalThis[${JSON.stringify(PAGE_CAPTURE_KEY)}]?.snapshot() ?? null`)
				),
				this.#snapshotMs,
			);
			report.hostAfter = this.#epoch(this.#stamp());
			if (!answer.ok) return { ...report, status: "unavailable", reason: answer.error };
			if (answer.value == null) return { ...report, status: "uninstalled" };
			const page = answer.value as PageSnapshot;
			const newest = report.documents.retained.at(-1);
			return {
				...report,
				status: "ok",
				page,
				snapshotIsNewestInstall: newest === undefined ? null : newest.installId === page.installId,
			};
		} catch (error) {
			this.#faults++; // tolerant: this tab reads as unavailable and the report goes on without it.
			return {
				...(report ?? {
					name: tab.name,
					mode: tab.mode,
					history: "unknown" as const,
					documents: { seen: 0, evicted: 0, malformed: 0, childFrames: 0, retained: [] },
					navigations: { seen: 0, evicted: 0, retained: [] },
					hostBefore: null,
					hostAfter: null,
					snapshotIsNewestInstall: null,
				}),
				status: "unavailable",
				reason: clipError(error),
			};
		}
	}

	/** Everything kept, as it stands. Reads every page in parallel, each bounded,
	 * and contains each page read and each `now` read. The clock's `timeOrigin`
	 * is read uncontained in the final assembly, so `report` is the boundary
	 * that keeps a failed snapshot from escaping. `timeline` is the proof's own
	 * description of the live sessions. */
	async snapshot(error: unknown, timeline: string): Promise<FailureReport> {
		this.#mark("failure", "failure", "proof", undefined, clipError(error));
		const tabs = await Promise.all([...this.#tabs].map(([key, tab]) => this.#tab(key, tab)));
		const items = this.#arrivals.items();
		return {
			error: clipError(error),
			host: { timeOrigin: this.#clock.timeOrigin, now: this.#stamp() },
			faults: this.#faults,
			viewer: {
				capacity: this.#arrivals.capacity,
				arrived: this.#arrived,
				projectionFailures: this.#projectionFailures,
				retained: this.#arrivals.retained,
				evicted: this.#arrivals.evicted,
				oldest: items.length > 0 ? { i: items[0].i, t: items[0].t } : null,
				newest: items.length > 0 ? { i: items[items.length - 1].i, t: items[items.length - 1].t } : null,
				closed: this.#closed,
				arrivals: items,
			},
			phases: { seen: this.#phases.seen, evicted: this.#phases.evicted, markers: this.#phases.items() },
			tabs,
			timeline: timeline.slice(0, 400),
		};
	}

	/** Print one snapshot for a failing proof. Contained end to end: a failed
	 * snapshot or a failed write is counted and never thrown, so the original
	 * failure is the one that propagates. */
	async report(error: unknown, timeline: string): Promise<void> {
		let line: string;
		try {
			line = JSON.stringify(await this.snapshot(error, timeline));
		} catch (failure) {
			line = JSON.stringify({ unavailable: clipError(failure) });
		}
		try {
			console.error(`  [reopen capture] ${line}`);
		} catch {
			this.#faults++; // tolerant: the one write failed, and a second write could fail the same way.
		}
	}
}
