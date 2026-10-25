// What a posted file is, and what to do with its bytes once they are here.
//
// Three facts the message row, the viewer, and the receive path need, kept in
// one place so they cannot answer them differently: which of the four kinds a
// media type is, how a file's size reads to a person, and whether a file's
// bytes are pulled the moment this window hears about it.
//
// These are decisions about values, with no document in sight, so the in-tree
// suite can cover them. Saving a file is a document effect and
// lives next door in `download.ts`.

import { AUTO_IMAGE_BYTES } from "./limits.ts";

/** The four ways this interface can present a posted file. A viewer opens the
 * first two full-screen, plays the third in place, and offers the fourth as a
 * download, so this is the one decision every media component branches on. */
export type MediaKind = "image" | "video" | "audio" | "file";

/** Whether this window pulls a file's bytes the moment it hears about it,
 * rather than waiting to be asked.

 * A picture appears in the line the way it does in every chat client, so a
 * small one is fetched on arrival. Anything larger, or anything that is not a
 * picture, waits behind its own control. `silenced` is the one thing that
 * overrides that: a member the reader has told this window to stop showing is
 * not somebody it should be fetching from on its own, and for a direct message
 * the fetch would reach that person's own host. The reference is kept either
 * way, so unignoring and pressing the file still works.
 *
 * One answer, because four places ask it (a room line arriving, a direct
 * message arriving, and each of their refiles) and a rule stated four times is
 * a rule that ends up meaning four things. */
export function fetchesOnArrival(
	file: { readonly mime: string; readonly size: number },
	silenced: boolean,
): boolean {
	return !silenced && kindOf(file.mime) === "image" && file.size <= AUTO_IMAGE_BYTES;
}

export function kindOf(mime: string): MediaKind {
	if (carriesScript(mime)) return "file";
	if (mime.startsWith("image/")) return "image";
	if (mime.startsWith("video/")) return "video";
	if (mime.startsWith("audio/")) return "audio";
	return "file";
}

/** Whether a media type is a document a browser would run script from.
 *
 * A posted file is shown from a `blob:` URL in this page's origin, and a
 * reader can open any shown image in its own tab. An SVG opened that way is
 * a document, and a document carries script. Among the types the viewer
 * shows or plays, the XML ones are the documents, so those are met as files.
 * The page's own policy also blocks inline script in such a document, and
 * this keeps that policy from being the only thing that does. The sender chose
 * the type, so it is read as the browser would: case-insensitive, with
 * parameters such as a charset ignored. */
function carriesScript(mime: string): boolean {
	return mime.split(";", 1)[0].trim().toLowerCase().endsWith("+xml");
}

/** The type a posted file's bytes are given when the browser holds them.
 *
 * What the viewer plays or shows keeps the sender's type, because an `<img>`
 * or `<video>` needs it. Anything the reader can only save is held as plain
 * bytes, so the browser never has a document with this origin to open. */
export function blobType(mime: string): string {
	return kindOf(mime) === "file" ? "application/octet-stream" : mime;
}

/** How big a file reads to a person: bytes up to a kilobyte, then one decimal
 * place, because "1.4 MB" is what a reader is deciding on and "1468006 bytes"
 * is not. */
export function fileSize(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} kB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
