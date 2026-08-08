/**
 * The Inspector reading a selection of more than one thing.
 *
 * Its sibling panels answer "what is this?" about one entity. This
 * one answers the questions a set raises instead: what is in it, when
 * it runs, how much of it is on stage, whether the sessions in it
 * join peers that are also in it — and then what can be changed
 * across the whole of it at once.
 *
 * Selection is not this panel's to write. The narrowing control hands
 * a set of keys back to the host, which dispatches the store's own
 * `set-selection`; nothing here keeps a selection of its own, because
 * a second place that decides what is selected is the one defect the
 * interaction layer is arranged to prevent.
 *
 * The facts come from `selection-summary.ts`, which is where their
 * accuracy is tested. This file is how they are laid out.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import type { Engine } from "../../engine/engine.ts";
import type { MoveIntent } from "../../engine/authoring/events.ts";
import type { StageSelection } from "../../render/types.ts";
import { parseEntityKey } from "../../interactions/types.ts";
import type { EntityRefKey } from "../../interactions/types.ts";
import { c, PANEL, SIZE, SPACE } from "../tokens.ts";
import { ScrubInput } from "../Timeline/ScrubInput.tsx";
import {
  BulkEnumSelect,
  type EditorBindings,
  type EditSession,
  endRowButtonStyle,
  Field,
  FieldGroup,
  formatTime,
  kv,
  PanelHeading,
  useScrubSession,
  valueMono,
  valueText,
} from "./shared.tsx";
import { elideIdentifier } from "../identifier.tsx";
import {
  CAPTP_VERSION_OPTIONS,
  captpVersionLabel,
  CODEC_OPTIONS,
  parseEndpointStageId,
  PROFILE_OPTIONS,
  SessionState,
} from "../../schema/topology.ts";
import { endpointLabelText } from "../../render/stage-labels.ts";
import { peerInfo, sessionInfo } from "./entity-info.ts";
import { sessionPairName } from "../session-name.ts";
import {
  bulkShiftPlan,
  countPhrase,
  DELETABLE_KINDS,
  deletionPhrase,
  kindNoun,
  type KindTally,
  selectionFacts,
  selectionPhrase,
  shiftCaveats,
} from "./selection-summary.ts";

/** Everything the group panel needs about the host's selection: the
 *  set itself, and the one way it is allowed to change it. */
export type SelectionPanelProps = {
  engine: Engine;
  selection: ReadonlySet<EntityRefKey>;
  editor?: EditorBindings | undefined;
  /** Replace the selection with exactly these entities. The host
   *  dispatches the store's `set-selection`; this panel only names
   *  the target set. Absent in a host that does not offer the
   *  control, and then no narrowing row is drawn. */
  onNarrow?: ((entities: ReadonlySet<EntityRefKey>) => void) | undefined;
};

export function SelectionFields(
  { engine, selection, editor, onNarrow }: SelectionPanelProps,
) {
  const facts = selectionFacts(engine, selection);
  const phrase = selectionPhrase(facts.tallies);
  const editing = editor !== undefined;
  return (
    <>
      <PanelHeading title={phrase}>{phrase}</PanelHeading>
      <FieldGroup title="Details">
        <div style={kv}>
          {facts.span && (
            <Field label="span">
              <code style={valueMono}>
                {formatTime(facts.span.start)} – {formatTime(facts.span.end)}
              </code>
            </Field>
          )}
          <Field label="on stage">
            <span style={valueText}>
              {facts.onStage === 0
                ? "none at the playhead"
                : `${facts.onStage} of ${facts.total} at the playhead`}
            </span>
          </Field>
          {facts.between && (
            <Field label="between">
              {
                /* The verb agrees with the noun after "of", which is
                  what keeps "0 of 1 session has" and "2 of 3 sessions
                  have" both reading as English. */
              }
              <span style={valueText}>
                {facts.between.closed} of{" "}
                {countPhrase("session", facts.between.sessions)}{" "}
                {facts.between.sessions === 1 ? "has" : "have"}{" "}
                both peers selected
              </span>
            </Field>
          )}
          <SharedFields
            engine={engine}
            selection={selection}
            editor={editor}
          />
          {facts.tallies.length > 1 && onNarrow && (
            <NarrowRow
              tallies={facts.tallies}
              onNarrow={onNarrow}
              editing={editing}
            />
          )}
        </div>
      </FieldGroup>
      {editor?.onMoveEvent && (
        <ShiftGroup
          engine={engine}
          selection={selection}
          editor={editor}
          total={facts.total}
        />
      )}
    </>
  );
}

// ───────────────────────── narrowing the selection ─────────────────────

const narrowRowStyle = {
  display: "flex",
  flexWrap: "wrap",
  alignItems: "center",
  gap: SPACE.xs,
  minWidth: 0,
} satisfies React.CSSProperties;

/** One button per kind in the selection, each dropping every other
 *  kind.
 *
 *  Narrowing is offered and subtracting is not, because with two
 *  kinds in hand the two verbs are the same act said backwards, and
 *  with three the reader's next question is nearly always about one
 *  of them. It is also the gesture that unlocks the shared fields
 *  above, which is what the note says.
 *
 *  A selection of one kind is not offered the row at all: narrowing
 *  to the only kind present would rewrite the selection with itself. */
function NarrowRow(
  { tallies, onNarrow, editing }: {
    tallies: readonly KindTally[];
    onNarrow: (entities: ReadonlySet<EntityRefKey>) => void;
    editing: boolean;
  },
) {
  const editable = tallies.some((t) =>
    t.kind === "peer" || t.kind === "session"
  );
  return (
    <Field
      label="narrow to"
      note={editing && editable
        ? (
          <span style={valueText}>
            Narrow to peers or sessions to edit what they share.
          </span>
        )
        : undefined}
    >
      <span style={narrowRowStyle}>
        {tallies.map((t) => {
          const what = countPhrase(t.kind, t.keys.length);
          return (
            <button
              key={t.kind}
              type="button"
              className="ocv-btn"
              style={endRowButtonStyle}
              title={`Select only the ${what}, dropping the rest`}
              aria-label={`Select only the ${what}`}
              onClick={() => onNarrow(new Set(t.keys))}
            >
              {kindNoun(t.kind, t.keys.length)}
            </button>
          );
        })}
      </span>
    </Field>
  );
}

// ───────────────────────── fields the selection shares ─────────────────

/** Fields every selected entity has, edited across all of them at
 *  once. Offered when the selection holds one kind: there is no field
 *  two different kinds both carry, so a mixed selection gets the
 *  narrowing row instead.
 *
 *  The control reads as the shared value when they agree and as
 *  "— mixed —" when they do not, and picking any concrete option
 *  broadcasts to every one of them inside a single edit transaction.
 *
 *  What it reads is what the next write would set. The single-entity
 *  panels read `live ?? def` so an in-flight edit shows immediately;
 *  these read the authored definition alone, because that is where
 *  the broadcast lands, and a control reading one value while writing
 *  another reports that nothing happened when the document says
 *  otherwise. It also reads and writes exactly the same entities: a
 *  selected id the document holds no definition for is left out of
 *  both, so the value shown is the value of everything the button
 *  would touch.
 *
 *  Messages and session ends have no such field today. A message's
 *  direction swap is a one-shot act rather than a value, and the
 *  session it is carried over has a different candidate list per
 *  message; an end's every field belongs to the session that owns
 *  it. */
function SharedFields(
  { engine, selection, editor }: {
    engine: Engine;
    selection: ReadonlySet<EntityRefKey>;
    editor?: EditorBindings | undefined;
  },
) {
  const refs = useMemo(
    () => Array.from(selection).map(parseEntityKey),
    [selection],
  );
  if (!editor) return null;
  const allKind = refs.length > 0 && refs.every((r) => r.kind === refs[0]!.kind)
    ? refs[0]!.kind
    : null;
  if (allKind === null) return null;

  if (allKind === "peer") {
    const peers = refs.flatMap((r) => {
      const def = engine.doc.entities?.peers?.[r.id];
      return def ? [{ id: r.id, profile: def.profile }] : [];
    });
    if (peers.length === 0) return null;
    const held = countPhrase("peer", peers.length);
    return (
      <Field label="profile">
        <BulkEnumSelect
          commonValue={sharedOrNull(peers.map((p) => p.profile))}
          options={PROFILE_OPTIONS}
          ariaLabel="Profile of every selected peer"
          onChange={(next) =>
            bulkApply(
              editor,
              peers,
              `Set profile to ${next} for ${held}`,
              (p) => editor.onUpdatePeer(p.id, { profile: next }),
            )}
        />
      </Field>
    );
  }

  if (allKind === "session") {
    const sessions = refs.flatMap((r) => {
      const def = engine.doc.entities?.sessions?.[r.id];
      return def ? [{ id: r.id, def }] : [];
    });
    if (sessions.length === 0) return null;
    const held = countPhrase("session", sessions.length);
    return (
      <>
        <Field label="codec">
          <BulkEnumSelect
            commonValue={sharedOrNull(sessions.map((s) => s.def.codec))}
            options={CODEC_OPTIONS}
            ariaLabel="Codec of every selected session"
            onChange={(next) =>
              bulkApply(
                editor,
                sessions,
                `Set codec to ${next} for ${held}`,
                (s) => editor.onUpdateSession(s.id, { codec: next }),
              )}
          />
        </Field>
        <Field label="captp">
          <BulkEnumSelect
            commonValue={sharedOrNull(sessions.map((s) => s.def.captpVersion))}
            options={CAPTP_VERSION_OPTIONS}
            ariaLabel="CapTP version of every selected session"
            labelFor={captpVersionLabel}
            onChange={(next) =>
              bulkApply(
                editor,
                sessions,
                `Set captp to ${next} for ${held}`,
                (s) => editor.onUpdateSession(s.id, { captpVersion: next }),
              )}
          />
        </Field>
        <Field label="initial state">
          <BulkEnumSelect
            commonValue={sharedOrNull(
              sessions.map((s) => s.def.initialState ?? "open"),
            )}
            options={SessionState.options}
            ariaLabel="Initial state of every selected session"
            onChange={(next) =>
              bulkApply(
                editor,
                sessions,
                `Set initial state to ${next} for ${held}`,
                (s) => editor.onSetSessionInitialState(s.id, next),
              )}
          />
        </Field>
      </>
    );
  }

  return null;
}

/** The value every entry carries, or null when they disagree (or
 *  there are none). Null is what drives the "— mixed —" sentinel. */
function sharedOrNull<T>(values: readonly T[]): T | null {
  if (values.length === 0) return null;
  const first = values[0]!;
  for (let i = 1; i < values.length; i++) {
    if (values[i] !== first) return null;
  }
  return first;
}

// ───────────────────────── moving the selection in time ────────────────

/** The one timing edit a selection of any shape can take: slide
 *  everything in it by the same amount. What the slide cannot reach
 *  says so underneath, counted rather than implied. */
function ShiftGroup(
  { engine, selection, editor, total }: {
    engine: Engine;
    selection: ReadonlySet<EntityRefKey>;
    editor: EditorBindings;
    total: number;
  },
) {
  // Captured per selection, not per render: a shift is measured from
  // where the entities stood when the drag began, so re-reading the
  // stream mid-drag would make each frame shift from the last one.
  const plan = useMemo(
    () => bulkShiftPlan(engine, selection),
    [engine, selection],
  );
  const caveats = shiftCaveats(plan, total);
  return (
    <FieldGroup title="Timing">
      <div style={kv}>
        <Field label="move by">
          {
            // A scrub that would dispatch nothing is worse than no
            // scrub: the reader drags it and the document does not
            // move. When the plan is empty the row says so with the
            // same dash every unstated time in the Inspector wears,
            // and the note underneath says why.
            plan.events.length > 0
              ? (
                <BulkShiftInput
                  events={plan.events}
                  selectionKey={selection}
                  move={editor.onMoveEvent}
                  beginEdit={editor.beginEdit}
                  endEdit={editor.endEdit}
                />
              )
              : <span style={{ ...valueMono, color: c.textSubtle }}>—</span>
          }
        </Field>
      </div>
      {caveats.length > 0 && (
        <div style={shiftNoteStyle}>
          {caveats.map((line) => <div key={line}>{line}</div>)}
        </div>
      )}
    </FieldGroup>
  );
}

/** What the undo menu calls a bulk shift, in one place, so the step a
 *  drag records and the step a typed value records cannot read
 *  differently. */
const MOVE_EVENTS_LABEL = "Move events";

/** Drag-to-shift control; emits one `translate` per planned event at
 *  `originalT + delta`. A burst coalesces into one undo step through
 *  the wrapping transaction. */
function BulkShiftInput(
  { events, selectionKey, move, beginEdit, endEdit }: {
    events: readonly { id: string; t: number }[];
    /** Stable identity for "which selection is this drag tied to".
     *  The reset triggers off this rather than off `events`, so a
     *  future re-derivation of the plan cannot drop the user's
     *  in-flight delta. */
    selectionKey: ReadonlySet<EntityRefKey>;
    move: (move: MoveIntent) => void;
    beginEdit: (label: string) => void;
    endEdit: () => void;
  },
) {
  // Reset to 0 on a new selection so the reader always starts at "no
  // shift" relative to the times the entities currently hold.
  const [delta, setDelta] = useState(0);
  useEffect(() => {
    setDelta(0);
  }, [selectionKey]);
  // Two brackets, nested, because there are two ways to be one
  // gesture. Every value this row takes moves every planned event, so
  // each change is bracketed on its own or the reader gets one undo
  // step per event. A drag or a wheel burst is many such changes and
  // is bracketed again around the whole gesture, so it lands as one
  // step rather than one per pixel. The scrub bracket is the shared
  // one, which is what closes it when the panel goes away under the
  // pointer.
  const scrub = useScrubSession({ beginEdit, endEdit }, MOVE_EVENTS_LABEL);
  const handleChange = useCallback((next: number) => {
    setDelta(next);
    bulkApply(
      { beginEdit, endEdit },
      events,
      MOVE_EVENTS_LABEL,
      (ev) =>
        move({
          kind: "translate",
          eventId: ev.id,
          newT: Math.max(0, ev.t + next),
        }),
    );
  }, [events, move, beginEdit, endEdit]);
  return (
    <ScrubInput
      value={delta}
      onChange={handleChange}
      {...scrub}
      min={-60_000}
      max={60_000}
      defaultValue={0}
      format={(ms) =>
        ms === 0 ? "0s" : `${ms >= 0 ? "+" : ""}${formatTime(ms)}`}
      formatInput={(ms) => (ms / 1000).toFixed(3)}
      parse={(text) => {
        const stripped = text.trim().replace(/s$/i, "").replace(/^\+/, "");
        const n = Number.parseFloat(stripped);
        if (!Number.isFinite(n)) return null;
        return n * 1000;
      }}
      label="Move all selected events by"
      linear
      pxPerDoubling={0.1}
    />
  );
}

// ───────────────────────── deleting the selection ──────────────────────

/** Delete every selected entity that can be deleted on its own,
 *  inside one transaction so undo restores the group as a unit.
 *
 *  The engine's per-entity delete already cascades — taking a peer
 *  takes its sessions and their messages — so the order does not
 *  matter, and a session already gone when its turn comes is a
 *  no-op rather than an error. Session ends are skipped here for the
 *  same reason the single-entity panel offers no delete for one, and
 *  the label counts what is actually taken. */
export function deleteSelection(
  editor: EditorBindings,
  selection: ReadonlySet<EntityRefKey>,
): void {
  const takes = deletionPhrase(selection);
  if (takes === null) return;
  const refs = Array.from(selection)
    .map(parseEntityKey)
    .filter((r) => DELETABLE_KINDS.has(r.kind));
  bulkApply(editor, refs, `Delete ${takes}`, (ref) => editor.onDelete(ref));
}

/** Wrap a bulk operation in one begin/endEdit transaction so the
 *  whole batch collapses to a single undo step. `try/finally`
 *  protects against an iteration-time throw leaving the transaction
 *  open — `endEdit` must always fire so the engine reverts cleanly.
 *  Takes the bracket pair rather than the whole editor, because that
 *  pair is all a batch needs and it is what the row-level controls
 *  have to hand. */
function bulkApply<T>(
  session: EditSession,
  refs: readonly T[],
  label: string,
  apply: (ref: T) => void,
): void {
  session.beginEdit(label);
  try {
    for (const r of refs) apply(r);
  } finally {
    session.endEdit();
  }
}

// ───────────────────────── the anchor note ─────────────────────────────

/** A quiet aside inside a panel: a dashed box, one notch down in
 *  size, saying something about what is around it rather than being
 *  part of it. Both of them belong to a selection of more than one
 *  thing — what a bulk edit leaves alone, and which of the selected
 *  the Connections list is showing — and the dash is the shared idea:
 *  this is commentary, not content. The border color and which side
 *  it sits on are each site's own. */
const noteBoxStyle: React.CSSProperties = {
  ...PANEL,
  // Tighter than a panel's own inset, because a note is one line rather than a
  // group of rows, and dashed because it says something provisional.
  padding: `${SPACE.xs}px ${SPACE.sm}px`,
  borderWidth: 1,
  borderStyle: "dashed",
  fontSize: SIZE.xs,
  color: c.textSubtle,
};

const shiftNoteStyle: React.CSSProperties = {
  ...noteBoxStyle,
  marginTop: SPACE.xs,
  borderColor: c.warningSoft,
  display: "flex",
  flexDirection: "column",
  gap: 2,
};

const anchorNoteStyle: React.CSSProperties = {
  ...noteBoxStyle,
  marginBottom: SPACE.xs,
  borderColor: c.border,
};

/** Which of the selected entities the Connections list below is
 *  showing.
 *
 *  The list is anchored to one entity, so with several selected the
 *  reader has to be told which one — otherwise a list of one peer's
 *  sessions reads as a roll-up of the whole selection. */
export function AnchorNote(
  { engine, anchor }: { engine: Engine; anchor: NonNullable<StageSelection> },
) {
  return (
    <div style={anchorNoteStyle}>
      Showing connections for <strong>{entityLabel(engine, anchor)}</strong>
    </div>
  );
}

/** What to call an entity in one line of running text. Every arm can
 *  end up holding a key the network chose rather than a name a person
 *  did, so each one elides — this is a sentence, and a sixty-four
 *  character word inside a sentence has nowhere to break. */
function entityLabel(
  engine: Engine,
  ref: NonNullable<StageSelection>,
): string {
  if (ref.kind === "peer") {
    return elideIdentifier(peerInfo(engine, ref.id)?.label ?? ref.id);
  }
  if (ref.kind === "endpoint") {
    const at = parseEndpointStageId(ref.id);
    const claim = at
      ? engine.doc.entities?.sessions?.[at.sessionId]?.[at.side].designator
      : undefined;
    return endpointLabelText(claim);
  }
  if (ref.kind === "session") {
    // The pair it joins, from the one place that derives it, so this
    // sentence calls a session what its own panel heading calls it.
    return sessionInfo(engine, ref.id) === null
      ? elideIdentifier(ref.id)
      : sessionPairName(engine.doc, ref.id, engine.clock.t);
  }
  const def = engine.doc.entities?.messages?.[ref.id];
  return elideIdentifier(def?.label ?? ref.id);
}
