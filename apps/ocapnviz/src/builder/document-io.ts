/**
 * Empty-document construction and the save/download write path.
 *
 * Saving is where `dct:modified` is stamped. A clock in the edit path
 * would make every keystroke differ from the last, so `endTransaction`
 * could not skip a transaction that changed nothing.
 */

import { TimelineDocument } from "../engine/timeline.ts";

/** How long a document starts out. Ten seconds is enough timeline to place a few
 *  things on without scrolling, and the panel's own length row is how it grows.
 *  `authoring/events.ts` grows it anyway for an edit that lands past the end, so
 *  this is a starting point rather than a limit. */
export const NEW_DOCUMENT_DURATION_MS = 10_000;

/**
 * An empty document to start from.
 *
 * Says nothing about itself, because a title the reader did not write is a title
 * they have to notice and delete; the panel shows the id as a placeholder until
 * they name it. There is no recording layer and no entity, so every surface reads
 * it as the empty document it is rather than as a document that failed to load.
 *
 * `id` is the one field that cannot be empty — it names the download and stands
 * in for the title until there is one.
 */
export function newDocument(id = "untitled"): TimelineDocument {
  return TimelineDocument.parse({
    id,
    duration: NEW_DOCUMENT_DURATION_MS,
    events: [],
  });
}

/**
 * What gets written when a document is saved: everything it says, with
 * `dct:modified` stamped now.
 *
 * Saving is where that field is written, and the reason it is not written as
 * edits land is that a clock in the edit path would make every keystroke differ
 * from the last: `endTransaction` compares snapshots to skip a transaction that
 * changed nothing, and a fresh timestamp would defeat it, so focusing a field and
 * leaving it would push an undo entry. Stamped here it also matches what the
 * term means, which is when this file was last written.
 *
 * Pure, and separate from the download below, so a test can read what would be
 * written without a DOM. The `now` is passed in for the same reason.
 */
export function saveStampedDoc(
  doc: TimelineDocument,
  now: string,
): TimelineDocument {
  return { ...doc, metadata: { ...doc.metadata, "dct:modified": now } };
}

/** Serialize the current doc and trigger a browser download.
 * Filename is the doc id with a `.json` suffix (slashes scrubbed
 * so the OS doesn't reject the suggested name). */
export function downloadDocAsJson(doc: TimelineDocument): void {
  const json = JSON.stringify(
    saveStampedDoc(doc, new Date().toISOString()),
    null,
    2,
  );
  const blob = new Blob([json], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  try {
    const a = document.createElement("a");
    a.href = url;
    a.download = `${doc.id.replace(/[\\/]/g, "-")}.json`;
    a.click();
  } finally {
    URL.revokeObjectURL(url);
  }
}
