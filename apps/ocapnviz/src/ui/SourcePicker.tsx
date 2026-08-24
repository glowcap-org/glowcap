/**
 * Where the buffer comes from, and how to swap it.
 *
 * Every mode answers that with a Source row at the top of the panel, and what
 * differs is what a source IS. In Play and Build it is one select whose value is
 * always the buffer's actual source: an opened file or a live recording appears as
 * a synthetic "Current" row above the built-in fixtures, so loading a file can
 * never leave the picker claiming a fixture. In Live it is the address the feed
 * dials, with a badge saying whether it got there and whether anything has
 * arrived.
 *
 * What the buffer IS follows underneath, and only in Play and Build, because Live
 * has no document to describe — `DocumentFields` owns those rows.
 */

import { useState } from "react";
import { c, FONT, PANEL } from "./tokens.ts";
import { stateChipBase } from "./EntityChips.tsx";
import { Field } from "./inspector/fields.tsx";
import { kv } from "./inspector/styles.tsx";
import { DocumentFields } from "./DocumentFields.tsx";
import type { EditBracket } from "./inspector/edit-bracket.ts";
import { type LiveFeedStatus, liveFeedStatus } from "../engine/live/status.ts";
import { scenarios } from "../fixtures/index.ts";
import type { AppMode, BufferSourceInfo } from "../state/app-state.ts";
import type { Engine } from "../engine/engine.ts";
import { docTitle } from "../engine/timeline.ts";
import { useDocVersion } from "./useDocVersion.ts";

/** Sentinel option value for the synthetic "current source" row.
 * The change handler treats it as a label, never a choice. */
export const CURRENT_SOURCE_OPTION = "__current-source";

const sourceSelect = {
	width: "100%",
} satisfies React.CSSProperties;

// The URL field is a field, so it wears `.ocv-input`. It used to wear
// `.ocv-select` with the chevron cancelled inline, which also handed a
// thing you type into the dropdown's pointer cursor and unselectable
// text. All that is left here is the mono face and the full width.
const sourceTextInput = {
	width: "100%",
	fontFamily: FONT.mono,
} satisfies React.CSSProperties;

export function SourcePicker(
	{
		mode,
		scenarioId,
		source,
		engine,
		liveSturdyref,
		liveConnected,
		liveObserved,
		liveRecording = false,
		onScenarioChange,
		onLiveSturdyrefChange,
		editor,
	}: {
		mode: AppMode;
		scenarioId: string;
		/** The buffer's actual provenance (derived in App). Null only
		 * before the first source resolves. */
		source: BufferSourceInfo | null;
		/** The active engine — subscribed here (not at the App level,
		 * which deliberately stays off the notify stream) so the
		 * "edited" badge appears the moment the first Build edit
		 * lands, not on the next unrelated re-render. */
		engine: Engine;
		liveSturdyref: string;
		liveConnected: boolean;
		/** At least one record has arrived on this dial. */
		liveObserved: boolean;
		/** Whether a live capture is running. A capture lives in the
		 *  engine the trace capability creates, so re-dialing throws it away —
		 *  the field therefore stops taking edits while one is running,
		 *  and says why. Merely being connected protects nothing, so the
		 *  field takes edits freely until Record.
		 *
		 *  Defaults to false, which reads as "no capture to protect". */
		liveRecording?: boolean;
		onScenarioChange: (event: React.ChangeEvent<HTMLSelectElement>) => void;
		onLiveSturdyrefChange: (sturdyref: string) => void;
		/** Passed through to the document's own fields: present only where editing is
		 *  allowed, which is Build. */
		editor: EditBracket | undefined;
	},
) {
	// What this panel paints is document-shaped: which source is loaded, what its
	// provenance line says, and whether there is an edit to undo. None of it
	// moves while a clock does.
	useDocVersion(engine);
	if (mode === "live") {
		// The same two questions this panel answers everywhere else, which in Live
		// have different answers rather than no answers: where the buffer comes from,
		// and what it is. Both are rows, because a bare field and a line of text
		// dropped straight into the key/value grid took a track each, so the
		// sturdyref is laid out with the status beside it.
		return (
			<div style={panel}>
				<Field label="Trace capability">
					<LiveSturdyrefField
						sturdyref={liveSturdyref}
						recording={liveRecording}
						onCommit={onLiveSturdyrefChange}
					/>
				</Field>
				<Field label="Status">
					<ConnectionBadge
						sturdyref={liveSturdyref}
						connected={liveConnected}
						observed={liveObserved}
					/>
				</Field>
			</div>
		);
	}
	// A file or recording IS the buffer right now; it gets the
	// selected synthetic row so the select never claims a fixture
	// it isn't playing.
	const current = source && source.kind !== "builtin"
		? {
			label: source.kind === "file" ? source.name : source.kind === "new" ? "New document" : "Live recording",
		}
		: null;
	return (
		<div style={panel}>
			<Field label="Source">
				<select
					value={current ? CURRENT_SOURCE_OPTION : scenarioId}
					onChange={onScenarioChange}
					className="ocv-select"
					style={sourceSelect}
					aria-label="Source"
				>
					{current && (
						<optgroup label="Current">
							<option value={CURRENT_SOURCE_OPTION}>
								{current.label}
							</option>
						</optgroup>
					)}
					<optgroup label="Built-in">
						{scenarios.map((s) => (
							<option key={s.id} value={s.id}>
								{docTitle(s)}
							</option>
						))}
					</optgroup>
				</select>
			</Field>
			<DocumentFields
				engine={engine}
				mode={mode}
				editor={editor}
				source={source}
				// A live Build undo stack is already "edited" before the mode exit
				// captures the fork. `canUndo` is the whole question, because every
				// change to the document is a step in the history — including setting
				// where it opens, which is why the camera moving is not one.
				edited={(source?.edited ?? false) ||
					(mode === "build" && engine.canUndo)}
			/>
		</div>
	);
}

/**
 * One panel holding where the buffer came from and what it says about itself.
 *
 * Both, in one box, because to a reader they are one thing: this document, and
 * how it got here. It carries no heading of its own — the section around it is
 * already called Document, and in Live, Connection.
 *
 * `PANEL` is the app's one recessed block and `kv` the Inspector's key/value grid
 * (`ui/tokens.ts`, `inspector/styles.tsx`). The grid lives HERE rather than around
 * the document's rows alone, because the source picker is a row of this panel too:
 * one grid is what makes its key measure against the keys under it.
 */
const panel = {
	...PANEL,
	...kv,
} satisfies React.CSSProperties;

/** Where the live feed dials.
 *
 *  What the reader types and what the socket dials are two different
 *  things, and this field is the seam between them. The text lives here
 *  while it is being typed and is handed up only when the reader says
 *  they are done — Enter, or leaving the field. Escape puts the field
 *  back to the sturdyref in force.
 *
 *  It reads as an ordinary text box, so the reason for the seam is worth
 *  stating: subscribing is destructive. Every sturdyref the field hands up
 *  closes the current CapTP session and opens the newly authorized trace; a
 *  half-typed sturdyref authorizes nothing. Handing drafts up a character at
 *  a time repeatedly tore down the current observation session and threw away
 *  any capture running on it.
 *
 *  While a capture is running the field does not take edits at all,
 *  because there is no phrasing of "dial somewhere else" that keeps the
 *  recording, and losing one to a stray click in a text box is not a
 *  trade worth offering. */
function LiveSturdyrefField(
	{ sturdyref, recording, onCommit }: {
		sturdyref: string;
		recording: boolean;
		onCommit: (sturdyref: string) => void;
	},
) {
	const [draft, setDraft] = useState(sturdyref);
	// The sturdyref in force can change under the field (a preset, a reset), and
	// the draft follows it whenever the field is not being typed in.
	const [editing, setEditing] = useState(false);
	const shown = editing ? draft : sturdyref;
	const commit = () => {
		setEditing(false);
		if (draft !== sturdyref) onCommit(draft);
	};
	return (
		<input
			type="text"
			value={shown}
			readOnly={recording}
			title={recording
				? "Stop the recording before changing where the feed dials — " +
					"re-dialing starts a new capture."
				: undefined}
			onFocus={() => {
				setDraft(sturdyref);
				setEditing(true);
			}}
			onChange={(e) => setDraft(e.target.value)}
			onBlur={commit}
			onKeyDown={(e) => {
				if (e.key === "Enter") {
					commit();
					e.currentTarget.blur();
				} else if (e.key === "Escape") {
					setDraft(sturdyref);
					setEditing(false);
					e.currentTarget.blur();
				}
			}}
			className="ocv-input"
			style={sourceTextInput}
			placeholder="ocapn://…/s/…"
			spellCheck={false}
		/>
	);
}

/**
 * Whether the feed is connected, as the app's badge.
 *
 * A badge because it is a state rather than a value, which is the same reading
 * `OriginRow` gives "edited" and the Inspector gives a session's lifecycle. It was
 * a dot and a word in small-caps at their own size — the one thing in this panel
 * that was neither a control nor a labelled fact, so a reader scanning keys down
 * the left had to step over it.
 *
 * The tone carries the state and the word says it, rather than the color being
 * the only difference: green for connected is not a distinction everyone can make.
 * Waiting keeps the warning tone so an open-but-silent feed is not the same
 * green as a feed that has already spoken.
 */
function ConnectionBadge({
	sturdyref,
	connected,
	observed,
}: {
	sturdyref: string;
	connected: boolean;
	observed: boolean;
}) {
	const status = liveFeedStatus({ sturdyref, connected, observed });
	const copy = badgeCopy[status];
	return (
		<span style={badgeStyle[status]} title={copy.title}>
			{copy.label}
		</span>
	);
}

const badgeCopy: Record<LiveFeedStatus, { label: string; title: string }> = {
	idle: {
		label: "idle",
		title: "Paste a sturdyref to dial the live feed",
	},
	connecting: {
		label: "connecting…",
		title: "Dialing the live feed — nothing arrives until it connects",
	},
	waiting: {
		label: "waiting…",
		title: "The live feed is connected — nothing has arrived yet",
	},
	connected: {
		label: "connected",
		title: "The live feed is connected",
	},
};

const connectedBadge = {
	...stateChipBase,
	background: c.positiveSoft,
	color: c.positive,
} satisfies React.CSSProperties;

const connectingBadge = {
	...stateChipBase,
	background: c.warningSoft,
	color: c.warning,
} satisfies React.CSSProperties;

const idleBadge = {
	...stateChipBase,
	background: c.surfaceMuted,
	color: c.textMuted,
} satisfies React.CSSProperties;

const badgeStyle: Record<LiveFeedStatus, React.CSSProperties> = {
	idle: idleBadge,
	connecting: connectingBadge,
	waiting: connectingBadge,
	connected: connectedBadge,
};
