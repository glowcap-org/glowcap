/**
 * Peer inspector panel — Details + Timing fields (`PeerFields`) and
 * the Connections sub-panel that lists sessions touching this peer
 * (`PeerConnections`). Build mode passes an `editor` binding so
 * every field renders as an input; Play / Live render the same shape
 * read-only and the LifecycleChip narrates where the playhead sits
 * relative to the peer's join/leave window.
 */

import {
  nodeActivityIn,
  type PeerActivity,
  type StageSelection,
} from "../../render/types.ts";
import type { Engine } from "../../engine/engine.ts";
import { findPeer } from "../../engine/world.ts";
import {
  authoredPeerPosition,
  findPeerJoinedEvent,
  peerEnding,
  peerTrajectoryRows,
} from "../../engine/event-helpers.ts";
import {
  peerGenesisValue,
  peerLabelAt,
  peerProfileAt,
  peerPropertyAt,
} from "../../engine/temporal/doc-resolver.ts";
import { PEER_PROPERTIES, PEER_TRAJECTORY } from "../../engine/trajectory.ts";
import {
  ActivityChip,
  LifecycleChip,
  type LifecycleStatus,
  PeerKindLabel,
} from "../EntityChips.tsx";
import {
  EditableIdField,
  type EditorBindings,
  Field,
  FieldGroup,
  inlineHeadingInput,
  inlineMonoInput,
  InlineTextField,
  kv,
  linkRowList,
  OptionalTimeRow,
  PanelHeading,
  placeholder,
  PositionRow,
  ProfileSelect,
  SessionLinkRow,
  TrajectoryInsert,
  TrajectoryValue,
  Unknown,
  valueMono,
  valueText,
} from "./shared.tsx";
import { elideIdentifier, Identifier } from "../identifier.tsx";
import { useEngineVersion } from "../useEngineVersion.ts";
import {
  isInSelection,
  peerInfo,
  sessionInfo,
  sessionsTouchingPeer,
} from "./entity-info.ts";
import type { EntityRefKey } from "../../interactions/types.ts";

/** Position row that follows mid-drag world coords. The PeerFields shell
 *  stays on doc+clock so label/id/profile groups do not re-reconcile every
 *  pointer step; this row alone wakes on `version`. */
function PeerPositionLiveRow(
  {
    engine,
    id,
    editing,
    editor,
  }: {
    engine: Engine;
    id: string;
    editing: boolean;
    editor: EditorBindings | undefined;
  },
) {
  useEngineVersion(engine);
  // Read the pin from the live doc here — not from a shell prop.
  // Mid-drag placement mutates `doc.entities` inside a transaction that
  // leaves `docVersion` quiet, so a parent-computed `pinned` stays at the
  // pre-drag point for the whole gesture.
  const pinned = authoredPeerPosition(engine.doc, id);
  const live = findPeer(engine.world, id);
  const at = pinned ?? live?.position ?? null;
  return (
    <PositionRow
      pinned={pinned}
      at={at}
      editing={editing}
      onMove={editor && ((pos) => editor.onRepositionPeer(id, pos))}
      onClear={editor && (() => editor.onUnpinPeer(id))}
      onPinHere={editor && at
        ? () => editor.onRepositionPeer(id, { x: at.x, y: at.y })
        : undefined}
      editSession={editor}
    />
  );
}

export function PeerFields(
  { engine, id, editor }: {
    engine: Engine;
    id: string;
    editor?: EditorBindings | undefined;
  },
) {
  // Shell wakes on doc + playhead via EntityDetails. Mid-drag pins are
  // owned by `PeerPositionLiveRow` below.
  const live = findPeer(engine.world, id);
  const joinedEv = findPeerJoinedEvent(engine.doc, id);
  const def = engine.doc.entities?.peers?.[id];
  if (!live && !def) return <Unknown kind="peer" id={id} />;

  const editing = editor !== undefined;
  // Read what the controls below WRITE, which is not the same value in the
  // two modes, the same split `EndFields` makes on a session's ends.
  //
  // Reading is easy: a peer has a name and a profile at the playhead, and
  // that is what a reader wants — the live entity first, since it carries
  // in-flight edits, and the value in effect at the playhead when the peer
  // is off stage. Editing is the other question. The pickers here write what
  // the peer ARRIVES with; a peer whose profile a moment later restates is a
  // trajectory row in Timing below, and that is the one place that moment can
  // be edited. So in Build these read the arrival value too. Reading the
  // playhead's value and writing the arrival value looks broken from the
  // outside and is worse than broken: the write lands, and a keyframe stating
  // the old value goes on winning, so the control reports that nothing
  // happened while the document says otherwise.
  const label = editing
    ? peerGenesisValue(engine.doc, id, "label")
    : live?.peer.label ?? peerLabelAt(engine.doc, id, engine.clock.t);
  const profile = editing
    ? peerGenesisValue(engine.doc, id, "profile")
    : live?.peer.profile ?? peerProfileAt(engine.doc, id, engine.clock.t);
  const designator = live?.peer.designator ?? def?.designator;
  // How this peer's row ended, when it did. A departure and an
  // identification are both endings and they say opposite things, so
  // the panel names which one rather than showing a bare end time.
  const ending = peerEnding(engine.doc, id);

  // Off stage there is nothing in flight to be part of. On stage, the same
  // fold the node's own mark is drawn from, so the chip here and the mark
  // there cannot disagree.
  const activity: PeerActivity = live
    ? nodeActivityIn(engine.queries.messagesInFlight, live.peer.id)
    : "idle";

  const lifecycle: LifecycleStatus = live
    ? "active"
    : joinedEv && engine.clock.t < joinedEv.t
    ? "before"
    : ending && engine.clock.t >= ending.t
    ? "after"
    : "off-stage";

  const update = editor?.onUpdatePeer;
  const duration = engine.doc.duration;
  const moments = peerTrajectoryRows(engine.doc, id);

  // Positioning: the authored pin is owned by `PeerPositionLiveRow`
  // (world subscription + live doc read).

  return (
    <>
      {editing
        ? (
          <InlineTextField
            value={label}
            onChange={(next) => update?.(id, { label: next })}
            ariaLabel="Peer label"
            editLabel="Rename peer"
            editSession={editor}
            placeholder="Label"
            style={inlineHeadingInput}
          />
        )
        : <PanelHeading title={label}>{label}</PanelHeading>}
      <PeerKindLabel profile={profile} />
      <FieldGroup title="Details">
        <div style={kv}>
          <Field label="id">
            {editing && editor
              ? <EditableIdField kind="peer" id={id} editor={editor} />
              : <Identifier value={id} />}
          </Field>
          <Field label="profile">
            {editing
              ? (
                <ProfileSelect
                  value={profile}
                  onChange={(p) => update?.(id, { profile: p })}
                />
              )
              : <code style={valueMono}>{profile}</code>}
          </Field>
          {ending?.how === "unobserved" && (
            <Field label="ends because">
              <span style={valueText}>
                the feed showing this peer went away. Whether it is still
                running is not something this recording knows.
              </span>
            </Field>
          )}
          {(editing || designator) && (
            <Field label="designator">
              {editing
                ? (
                  <InlineTextField
                    value={designator ?? ""}
                    onChange={(next) => update?.(id, { designator: next })}
                    ariaLabel="Peer designator"
                    editLabel="Edit designator"
                    editSession={editor}
                    placeholder="(none)"
                    style={inlineMonoInput}
                  />
                )
                : <Identifier value={designator ?? ""} />}
            </Field>
          )}
          <PeerPositionLiveRow
            engine={engine}
            id={id}
            editing={editing}
            editor={editor}
          />
        </div>
      </FieldGroup>
      <FieldGroup title="Timing">
        <div style={kv}>
          <OptionalTimeRow
            label="start"
            t={def?.timing?.start.explicit
              ? engine.intrinsicStart("peers", id)
              : null}
            editing={editing}
            onMove={editing && editor?.onSetPeerStart
              ? (t) => editor.onSetPeerStart(id, t)
              : undefined}
            onClear={editor?.onClearPeerStart
              ? () => editor.onClearPeerStart(id)
              : undefined}
            onSetAtPlayhead={editor?.onSetPeerStart
              ? () => editor.onSetPeerStart(id, engine.clock.t)
              : undefined}
            min={0}
            max={ending?.t ?? duration}
            strictMax={ending !== null}
            scrubLabel="Peer start time"
            editSession={editor}
          />
          {
            /* The peer's trajectory: every moment it restated
              something about itself, numbered like a session's state
              trajectory. "start" above carries what it ARRIVED with
              (a session's genesis state in peer form); each row here
              is one property stated at one moment — a time, what
              changed, the value, and an X to clear it. The rows come
              from `engine/trajectory.ts`, so a second temporal peer
              property renders here with no change to this file. */
          }
          {moments.map((moment, i) => {
            const prevT = i === 0
              ? engine.intrinsicStart("peers", id)
              : moments[i - 1]!.ev.t;
            const nextT = i === moments.length - 1
              ? ending?.t ?? duration
              : moments[i + 1]!.ev.t;
            const spec = PEER_TRAJECTORY[moment.property];
            return (
              <OptionalTimeRow
                key={`${moment.ev.id}:${moment.property}`}
                // The row says which property it states, so a
                // trajectory reads as a list of changes rather
                // than a list of numbers.
                label={`#${i + 1} ${spec.noun}`}
                below={
                  <TrajectoryValue
                    property={spec}
                    value={moment.value}
                    editing={editing}
                    editSession={editor}
                    onChange={(next) => {
                      // The shared cell's value channel is wide enough for
                      // both lanes, and a session's end is the arm that
                      // carries a pair. Every peer property is one word —
                      // its editors are `text` and `enum` — so the pair
                      // cannot arrive here, and this says which lane this
                      // is rather than assuming it.
                      if (typeof next !== "string") return;
                      editor?.onSetPeerUpdate(
                        id,
                        moment.ev.t,
                        moment.property,
                        next,
                      );
                    }}
                  />
                }
                t={moment.ev.t}
                editing={editing}
                onMove={editing && editor
                  ? (t) =>
                    editor.onMoveEvent({
                      kind: "translate",
                      eventId: moment.ev.id,
                      newT: t,
                    })
                  : undefined}
                onClear={editing && editor
                  ? () =>
                    editor.onRemovePeerUpdate(id, moment.ev.t, moment.property)
                  : undefined}
                onSetAtPlayhead={undefined}
                min={prevT}
                max={nextT}
                strictMax={i < moments.length - 1 || ending !== null}
                scrubLabel={`Time this ${spec.noun} took effect`}
                editSession={editor}
              />
            );
          })}
          {editing && editor && (() => {
            // State another property at the playhead, the way the
            // session trajectory inserts a state change there. The
            // value offered is what the peer carries at that moment,
            // so the row arrives saying something true and the user
            // edits it. It comes from `peerPropertyAt` rather than
            // from the document directly, because a peer the document
            // says nothing about still carries every property, and a
            // closed enum refuses a value that stands for "none".
            const t = Math.max(
              engine.clock.t,
              engine.intrinsicStart("peers", id),
            );
            return (
              <Field label={`#${moments.length + 1}`}>
                <TrajectoryInsert
                  properties={PEER_PROPERTIES}
                  describe={(property) => PEER_TRAJECTORY[property]}
                  onInsert={(property) =>
                    editor.onSetPeerUpdate(
                      id,
                      t,
                      property,
                      peerPropertyAt(engine.doc, id, property, t),
                    )}
                />
              </Field>
            );
          })()}
          {
            /* Duration mirrors the data model: TimeSpan is stored as
              {start, duration}. End is a derived round-trip; show the
              field we actually store and dispatch the duration intent
              directly — no end-translation round trip. */
          }
          <OptionalTimeRow
            label="duration"
            t={def?.timing?.duration.explicit
              ? def.timing.duration.value
              : null}
            editing={editing}
            onMove={editing && editor?.onSetPeerDuration
              ? (dur) => editor.onSetPeerDuration(id, dur)
              : undefined}
            onClear={editor?.onClearPeerEnd
              ? () => editor.onClearPeerEnd(id)
              : undefined}
            onSetAtPlayhead={editor?.onSetPeerDuration
              ? () =>
                editor.onSetPeerDuration(
                  id,
                  Math.max(
                    0,
                    engine.clock.t - engine.intrinsicStart("peers", id),
                  ),
                )
              : undefined}
            min={Math.max(
              0,
              (moments.length > 0 ? moments[moments.length - 1]!.ev.t : 0) -
                engine.intrinsicStart("peers", id),
            )}
            max={Math.max(0, duration - engine.intrinsicStart("peers", id))}
            strictMax={false}
            scrubLabel="Peer duration"
            editSession={editor}
          />
          <Field label="status">
            {live
              ? <ActivityChip activity={activity} />
              : <LifecycleChip status={lifecycle} entity="peer" />}
          </Field>
        </div>
      </FieldGroup>
    </>
  );
}

export function PeerConnections(
  { engine, id, onSelect, entitySelection }: {
    engine: Engine;
    id: string;
    onSelect: (selection: StageSelection) => void;
    /** Multi-select awareness: rows whose target session OR the
     *  "other peer" appears in this set get the in-selection
     *  highlight. Both are checked because a peer-side row links
     *  to a session but visually advertises the other peer's
     *  name; either being selected is a meaningful signal. */
    entitySelection?: ReadonlySet<EntityRefKey> | undefined;
  },
) {
  const self = peerInfo(engine, id);
  if (!self) return null;
  const sessionIds = sessionsTouchingPeer(engine, id);
  if (sessionIds.length === 0) {
    return (
      <div style={placeholder}>
        <strong>{self.label}</strong> has no sessions in this document.
      </div>
    );
  }

  return (
    <div style={linkRowList}>
      {sessionIds.map((sid) => {
        const s = sessionInfo(engine, sid);
        if (!s) return null;
        const otherId = s.a === id ? s.b : s.a;
        const other = peerInfo(engine, otherId);
        const selected =
          isInSelection(entitySelection, { kind: "session", id: sid }) ||
          isInSelection(entitySelection, { kind: "peer", id: otherId });
        return (
          <SessionLinkRow
            key={sid}
            codec={s.codec}
            captpVersion={s.captpVersion}
            name={other?.label ?? elideIdentifier(otherId)}
            state={s.state}
            lifecycle={s.lifecycle}
            selected={selected}
            onClick={() => onSelect({ kind: "session", id: sid })}
          />
        );
      })}
    </div>
  );
}
