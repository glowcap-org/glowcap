/**
 * Doc snapshot helpers — clone the parts of `TimelineDocument`
 * that participate in undo/redo (the recording's mutable observation
 * streams + visibility state + row order + entities map + the
 * authoring-grown duration), and restore them in place from a
 * snapshot.
 *
 * Pure: no engine internals. The Engine wraps `restoreSnapshotInto`
 * with its `layout.recompute()` + `seekTo()` calls because those
 * are engine-orchestration concerns (rebuild the world from the
 * restored entities). Sits next to `history.ts` — `DocSnapshot` lives
 * there since `History<DocSnapshot>` is the consumer.
 */

import type { TimelineDocument } from "./timeline.ts";
import type { DocSnapshot } from "./history.ts";

/**
 * The part of `metadata` undo owns, which is all of it except `dct:modified`.
 *
 * That one is a record of when an edit happened rather than one of the things a
 * document says, so it does not round-trip. Leaving it in cost two things: an
 * undo would put back a stamp from before the edit it is undoing, and every blur
 * that stamped would make the two snapshots differ, so `endTransaction` would
 * record a history entry for a transaction that changed nothing a reader typed.
 */
function metadataUnderUndo(
  metadata: TimelineDocument["metadata"],
): TimelineDocument["metadata"] {
  if (metadata === undefined) return undefined;
  const { "dct:modified": _stamp, ...rest } = metadata;
  return Object.keys(rest).length > 0 ? structuredClone(rest) : undefined;
}

/** Put the snapshot's metadata back, keeping whatever stamp the document carries
 *  now. An absent block plus a live stamp is still a block. */
function restoreMetadata(
  snap: TimelineDocument["metadata"],
  current: TimelineDocument["metadata"],
): TimelineDocument["metadata"] {
  const stamp = current?.["dct:modified"];
  const restored = snap === undefined ? undefined : structuredClone(snap);
  if (stamp === undefined) return restored;
  return { ...restored, "dct:modified": stamp };
}

export function takeSnapshot(doc: TimelineDocument): DocSnapshot {
  return {
    duration: doc.duration,
    rowOrder: structuredClone(doc.rowOrder),
    rowHidden: structuredClone(doc.rowHidden),
    rowLabelHidden: structuredClone(doc.rowLabelHidden),
    rowBodyHidden: structuredClone(doc.rowBodyHidden),
    allVisMode: doc.allVisMode,
    categoryVisMode: structuredClone(doc.categoryVisMode),
    recording: doc.recording ? structuredClone(doc.recording) : undefined,
    entities: structuredClone(doc.entities),
    metadata: metadataUnderUndo(doc.metadata),
    initialView: structuredClone(doc.initialView),
  };
}

/** Restore `snap` into `doc` in place. The Engine adds
 *  `layout.recompute()` + `seekTo()` after this to rebuild the world
 *  from the restored entities. */
export function restoreSnapshotInto(
  doc: TimelineDocument,
  snap: DocSnapshot,
): void {
  (doc as { duration: number }).duration = snap.duration;
  doc.rowOrder = structuredClone(snap.rowOrder);
  doc.rowHidden = structuredClone(snap.rowHidden);
  doc.rowLabelHidden = structuredClone(snap.rowLabelHidden);
  doc.rowBodyHidden = structuredClone(snap.rowBodyHidden);
  doc.allVisMode = snap.allVisMode;
  doc.categoryVisMode = structuredClone(snap.categoryVisMode);
  doc.recording = snap.recording ? structuredClone(snap.recording) : undefined;
  doc.entities = structuredClone(snap.entities);
  // The stamp the document currently carries survives the restore. Undo reverts
  // the edit, not the record that an edit happened: a title put back should not
  // also claim the document was last modified before it was changed.
  doc.metadata = restoreMetadata(snap.metadata, doc.metadata);
  // Where the document opens goes back with the rest. It does not move the
  // camera, and does not need to: nothing writes this as the camera moves, so
  // undoing what the document opens at and where the reader is looking are two
  // separate facts that were never coupled.
  doc.initialView = structuredClone(snap.initialView);
}

/**
 * Make `doc` say what `source` says again, in place.
 *
 * Key-agnostic where `restoreSnapshotInto` above names its fields one
 * by one, and the difference is the whole point of having two
 * functions. A snapshot restores what UNDO covers, so a document field
 * outside that list is a field undo never claimed. A reset restores the
 * WHOLE document, so a field outside a list here would be an edit that
 * survived a command whose name promises it discarded everything —
 * a partial reset nothing on screen would report. This one therefore
 * takes every key the document has off it and takes every key the
 * source has back, and a field added to `TimelineDocument` tomorrow is
 * covered without anyone remembering.
 *
 * In place rather than by replacement, because the layout system and
 * the authoring context both hold this object.
 */
export function resetDocumentTo(
  doc: TimelineDocument,
  source: TimelineDocument,
): void {
  const target = doc as unknown as Record<string, unknown>;
  for (const key of Object.keys(target)) delete target[key];
  Object.assign(target, structuredClone(source));
}
