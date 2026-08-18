/**
 * The Inspector's two sections, and the routing between them.
 *
 * This module owns no fields of its own. It decides which panel the
 * current selection reads through — one of the per-kind panels beside
 * it, or the group panel when the reader is holding more than one
 * thing — and it owns the one act every panel ends with, which is the
 * delete.
 */

import type { StageSelection } from "../render/types.ts";
import type { Engine } from "../engine/engine.ts";
import { type EntityKind, type EntityRefKey, parseEntityKey } from "../interactions/types.ts";
import { documentHolds } from "../interactions/selection-store.ts";
import { PANEL, SPACE } from "./tokens.ts";
import { useClockSnapshot } from "./useClockSnapshot.ts";
import { useDocVersion } from "./useDocVersion.ts";
import { TrashGlyph } from "./glyphs.tsx";
import type { EditorBindings } from "./inspector/bindings.ts";
import { placeholder } from "./inspector/styles.tsx";
import { PeerConnections, PeerFields } from "./inspector/PeerPanel.tsx";
import { SessionConnections, SessionFields } from "./inspector/SessionPanel.tsx";
import { MessageConnections, MessageFields } from "./inspector/MessagePanel.tsx";
import { EndpointConnections, EndpointFields } from "./inspector/EndpointPanel.tsx";
import { AnchorNote, deleteSelection, SelectionFields } from "./inspector/SelectionPanel.tsx";
import { deletionPhrase } from "./inspector/selection-summary.ts";
import { sessionsTouchingPeer } from "./inspector/entity-info.ts";

export type { EditorBindings };

export type SidebarBodyProps = {
  engine: Engine;
  /** The "Inspector follow" entity — what the panel populates its
   *  per-kind fields and Connections section against. Always also
   *  a member of `entitySelection` when set; null when no entity
   *  is anchored. The single-select / multi-select asymmetry is
   *  resolved by `entitySelection` (the full set) being a separate
   *  prop on the components that need it (`EntityDetails`,
   *  `EntityConnections`); this slot is just the anchor. */
  anchor: StageSelection;
  onSelect: (selection: StageSelection) => void;
};

/** Entity-fields section. `editor` toggles read-only vs. edit (Build);
 *  a selection of more than one entity reads through the group panel
 *  instead of a per-kind one. */
/**
 * A section's own panel: the recessed block a whole sidebar section sits in.
 *
 * `PANEL` is the app's one such block (`ui/tokens.ts`); what is added is the
 * stacking of whatever the section put inside it. Two sections use it — the
 * connections list and the placeholder that stands in for a body before anything
 * is picked — so both read as the same kind of thing as the field groups above
 * them.
 *
 * A populated Details body is NOT wrapped: it is already a stack of `FieldGroup`
 * panels, and a panel around panels reads as a mistake rather than a grouping.
 */
const sectionPanel = {
  ...PANEL,
  display: "flex",
  flexDirection: "column",
  gap: SPACE.sm,
} satisfies React.CSSProperties;

/**
 * What the Inspector is actually showing, as against what is logically selected.
 *
 * The two come apart, on purpose. A selection survives a mode switch so that
 * leaving Play for Live and coming back puts the reader where they were — which
 * means that while Live is up, the selection names entities the live stream has
 * never mentioned. Every part of the Inspector has to agree about that, and each
 * asking for itself is how they stopped agreeing: the bodies showed a placeholder
 * while the Details heading, deciding from the logical anchor, left its "Details"
 * title off, so an empty pane came with a title in one mode and without it in
 * another.
 *
 * So it is derived once, here, and the whole Inspector renders from the result.
 * Nothing downstream reads the logical selection, which is what stops the next
 * part from disagreeing too.
 *
 * `documentHolds` rather than a resolver per kind, because it is the same question
 * the store asks before dropping a stale selection, and one question deserves one
 * answer. It takes the identity map rather than a whole `SelectionDocSnapshot`, so
 * asking costs nothing: building one of those walks the observation stream, and
 * this runs on every render of the Inspector.
 *
 * The selection set comes back by identity when the buffer holds all of it, the
 * same way `reconcile-with-doc` returns the same state when it finds everything —
 * so the common case allocates nothing.
 */
export function inspectorView(
  engine: Engine,
  anchor: StageSelection,
  selection: ReadonlySet<EntityRefKey> | undefined,
): {
  anchor: StageSelection;
  selection: ReadonlySet<EntityRefKey> | undefined;
} {
  const entities = engine.doc.entities;
  const shownAnchor = anchor && documentHolds(entities, anchor) ? anchor : null;
  if (!selection || selection.size === 0) {
    return { anchor: shownAnchor, selection };
  }
  let allHeld = true;
  for (const k of selection) {
    if (!documentHolds(entities, parseEntityKey(k))) {
      allHeld = false;
      break;
    }
  }
  if (allHeld) return { anchor: shownAnchor, selection };
  const kept = new Set<EntityRefKey>();
  for (const k of selection) {
    if (documentHolds(entities, parseEntityKey(k))) kept.add(k);
  }
  return { anchor: shownAnchor, selection: kept };
}

export function EntityDetails(
  { engine, anchor, editor, entitySelection, onNarrowSelection }:
    & SidebarBodyProps
    & {
      editor?: EditorBindings | undefined;
      entitySelection?: ReadonlySet<EntityRefKey> | undefined;
      /** Replace the selection with exactly these entities — the
       *  group panel's narrowing control, dispatched by the host as
       *  the store's own `set-selection`. */
      onNarrowSelection?:
        | ((entities: ReadonlySet<EntityRefKey>) => void)
        | undefined;
    },
) {
  // Document + playhead only. Mid-drag bumps `version` without moving either,
  // so this shell stays quiet while a pin is being dragged; per-kind field
  // panels that follow live world position subscribe to `version` themselves.
  useDocVersion(engine);
  useClockSnapshot(engine);
  if (entitySelection && entitySelection.size > 1) {
    const selection = entitySelection;
    // What a group delete would take, which is not always the whole
    // selection: a session end has no delete of its own, and a
    // selection of nothing else is offered no trash at all.
    const takes = editor ? deletionPhrase(selection) : null;
    return (
      <>
        <SelectionFields
          engine={engine}
          selection={selection}
          editor={editor}
          onNarrow={onNarrowSelection}
        />
        {editor && takes && (
          <DeleteRow
            label={`Delete ${takes}`}
            onDelete={() => deleteSelection(editor, selection)}
          />
        )}
      </>
    );
  }
  // `anchor` is already what the Inspector is showing rather than what is
  // logically selected — `inspectorView` resolved it once for every part of the
  // pane (`AppView.tsx`), so there is nothing left to ask here.
  const at = anchor;
  if (!at) {
    return (
      <div style={sectionPanel}>
        <div style={placeholder}>
          Tap a peer node, session edge, or message in flight on the canvas to inspect it.
        </div>
      </div>
    );
  }
  const Fields = FIELDS_BY_KIND[at.kind];
  const body = <Fields engine={engine} id={at.id} editor={editor} />;
  // An unattributed end has no delete of its own: it is one of the two ends
  // its session HAS, and deleting the session is what takes it.
  if (!editor || at.kind === "endpoint") return body;
  const kind = at.kind;
  return (
    <>
      {body}
      <DeleteRow
        label={deleteLabels[kind]}
        onDelete={() => editor.onDelete(at)}
      />
    </>
  );
}

/** One entry per selectable kind. Keyed by `EntityKind` rather than by a
 *  hand-listed union, so a kind added to the selection vocabulary without a
 *  panel fails the build instead of resolving to `undefined` and making
 *  React refuse to render the Inspector. */
const FIELDS_BY_KIND: Record<
  EntityKind,
  (props: {
    engine: Engine;
    id: string;
    editor?: EditorBindings | undefined;
  }) => React.ReactNode
> = {
  peer: PeerFields,
  endpoint: EndpointFields,
  session: SessionFields,
  message: MessageFields,
};

const CONNECTIONS_BY_KIND: Record<
  EntityKind,
  (props: {
    engine: Engine;
    id: string;
    onSelect: (selection: StageSelection) => void;
    entitySelection?: ReadonlySet<EntityRefKey> | undefined;
  }) => React.ReactNode
> = {
  peer: PeerConnections,
  endpoint: EndpointConnections,
  session: SessionConnections,
  message: MessageConnections,
};

const deleteRow = {
  display: "flex",
  justifyContent: "flex-end",
  marginTop: SPACE.xs,
} satisfies React.CSSProperties;

const deleteLabels: Record<"peer" | "session" | "message", string> = {
  peer: "Delete peer",
  session: "Delete session",
  message: "Delete message",
};

/** The trash a panel ends with. One entity or a whole selection, the
 *  affordance is the same and the label says which — so the row is
 *  one element and the only thing that varies is what it claims to
 *  take. */
function DeleteRow(
  { label, onDelete }: { label: string; onDelete: () => void },
) {
  return (
    <div style={deleteRow}>
      <button
        type="button"
        className="ocv-btn is-icon"
        onClick={onDelete}
        title={`${label} (Delete)`}
        aria-label={label}
      >
        <TrashGlyph />
      </button>
    </div>
  );
}

/** Connections section. Resolves against `engine.world`, so works
 *  identically across Play / Live / Build.
 *
 *  Multi-select honesty: the body is anchored to a single entity
 *  (the store's `anchor`), so when the user has more than one
 *  thing selected, prepend a small banner naming the anchor —
 *  the user knows the section is showing connections of that one
 *  entity, not a roll-up of all selected. Within the rows,
 *  `entitySelection` lights up the targets that are also in the
 *  selection so cross-references are legible. */
export function EntityConnections(
  { engine, anchor, onSelect, entitySelection }:
    & SidebarBodyProps
    & { entitySelection?: ReadonlySet<EntityRefKey> | undefined },
) {
  // Same split as Details: connections are document- and playhead-shaped.
  // Mid-drag does not change who touches whom.
  useDocVersion(engine);
  useClockSnapshot(engine);
  const at = anchor;
  if (!at) {
    return (
      <div style={sectionPanel}>
        <div style={placeholder}>
          Connections appear here once you pick something on the canvas.
        </div>
      </div>
    );
  }
  const isMulti = (entitySelection?.size ?? 0) > 1;
  const Connections = CONNECTIONS_BY_KIND[at.kind];
  return (
    <div style={sectionPanel}>
      {isMulti && <AnchorNote engine={engine} anchor={at} />}
      <Connections
        engine={engine}
        id={at.id}
        onSelect={onSelect}
        entitySelection={entitySelection}
      />
    </div>
  );
}

/** Connections-section title shaped to the anchor ("Session edges
 * (3)" for a peer, "Endpoint edges" for a session, …). The count
 * for a peer is drawn from the full doc — every session that
 * ever touches the peer, not just sessions live at the playhead
 * — so the title stays stable across scrub.
 *
 * It names the anchor whatever else is selected, because the anchor
 * is what the list under it holds. A count of the selection here
 * would be a number about one thing sitting above a list of
 * another; `AnchorNote` says whose rows these are instead, and the
 * Details heading above is where the selection is counted. */
export function connectionsSectionTitle(
  engine: Engine,
  anchor: StageSelection,
): string {
  // Given the resolved anchor, like the bodies: a title naming a peer over a list
  // that says nothing is picked reads as a list that failed to load.
  const at = anchor;
  if (!at) return "Connections";
  if (at.kind === "peer") {
    const count = sessionsTouchingPeer(engine, at.id).length;
    return count > 0 ? `Session edges (${count})` : "Session edges";
  }
  // "Edges", not "peers": a session's ends are two rows here, and an
  // end nothing attributed has no peer to name. Titling the list after
  // the thing only one row might be would make the other read as
  // missing rather than as what it is.
  if (at.kind === "session") return "Endpoint edges";
  if (at.kind === "endpoint") return "Session";
  // Messages: subsections inside `MessageConnections` carry their
  // own labels ("From peer", "To peer", "Carried over"), so the
  // section header is a plain catch-all.
  return "Connections";
}
