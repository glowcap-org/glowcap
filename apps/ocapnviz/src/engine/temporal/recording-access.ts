/**
 * Reading the observation stream out of a doc.
 *
 * Post-parse, observations live only in `doc.recording.sources[]`.
 * The schema's `.transform` accepts a fixture-friendly top-level
 * `events: [...]` input and projects it into `recording.sources[0]`,
 * stripping the field from the runtime type. Every reader and
 * writer goes through these helpers.
 */

import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import type { Observation, RecordingSource } from "./recording.ts";

/**
 * Mutable primary observation array. The home for new observations
 * from authoring or live-feed. Lazy-creates `recording.sources[0]`
 * if absent so the first write always succeeds without callers
 * needing to special-case empty docs.
 */
export function primaryObservations(doc: TimelineDocument): TimelineEvent[] {
	if (!doc.recording) {
		(doc as { recording: TimelineDocument["recording"] }).recording = {
			sources: [{
				id: "primary",
				meta: { kind: "authored" },
				observations: [],
			}],
		};
	} else if (doc.recording.sources.length === 0) {
		doc.recording.sources.push({
			id: "primary",
			meta: { kind: "authored" },
			observations: [],
		});
	}
	// No cast: `TimelineEvent` is the authoring name for `Observation`
	// and `timeline.ts` declares it as exactly that.
	return doc.recording!.sources[0]!.observations;
}

/** A doc with no recording has no observations, and says so with the same
 *  array every time. Handing back a fresh `[]` per call would make an empty
 *  document look like a changing one to every reader that caches on
 *  identity. */
const NO_OBSERVATIONS: readonly Observation[] = [];

/** The flattened list a multi-source doc needs, and what it was built from,
 *  so the next call can tell whether it is still the answer. */
type Flattened = {
	readonly view: readonly Observation[];
	/** Each source's array as it stood at the build, and how long it was then.
	 *  Identity catches a source replaced wholesale. The length catches a live
	 *  feed, which appends to the array it already has. */
	readonly from: readonly { arr: readonly Observation[]; len: number }[];
};

const flattenedByRecording = new WeakMap<
	NonNullable<TimelineDocument["recording"]>,
	Flattened
>();

function stillDescribes(
	memo: Flattened,
	sources: readonly RecordingSource[],
): boolean {
	if (memo.from.length !== sources.length) return false;
	return memo.from.every((was, i) => {
		const now = sources[i]!.observations;
		return was.arr === now && was.len === now.length;
	});
}

/** Flattened list of all observations in the doc, in source-declaration
 *  order across sources, chronological within each. Use when a reader needs
 *  every observation regardless of source. For per-source access use
 *  `sourcesOf(doc)`.
 *
 *  **The same list for the same document.** Two calls on a document nothing
 *  has written to return the identical array, so a reader may cache on what
 *  it got back. That is not a convenience: this is on the render path, and a
 *  reader that has to rebuild whenever its input LOOKS new rebuilds every
 *  frame forever. The single-source doc, every fixture, every live capture,
 *  gets it for free, because the flattening of one list is that list. Several
 *  sources are flattened once and the result held against the arrays it was
 *  built from, so a source appended to or swapped out is flattened again and
 *  nothing else is.
 *
 *  What it does NOT cover is an observation mutated in place, which changes
 *  neither a source's identity nor its length. Authoring does exactly that,
 *  and it is why every authoring path swaps `doc.entities`
 *  (`bumpEntities`), that swap, not this list, is what tells a viewer cache
 *  an edit landed. */
export function observationsOf(doc: TimelineDocument): readonly Observation[] {
	const recording = doc.recording;
	if (recording === undefined || recording.sources.length === 0) {
		return NO_OBSERVATIONS;
	}
	const sources = recording.sources;
	if (sources.length === 1) return sources[0]!.observations;
	const memo = flattenedByRecording.get(recording);
	if (memo !== undefined && stillDescribes(memo, sources)) return memo.view;
	const view: Observation[] = [];
	for (const src of sources) view.push(...src.observations);
	flattenedByRecording.set(recording, {
		view,
		from: sources.map((s) => ({
			arr: s.observations,
			len: s.observations.length,
		})),
	});
	return view;
}

/** Per-source view. Returns the empty array when no recording is
 *  present (rare post-parse, only fresh-from-construction docs
 *  before any authoring write). */
export function sourcesOf(doc: TimelineDocument): readonly RecordingSource[] {
	return doc.recording?.sources ?? [];
}
