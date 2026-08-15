// What a posted file is, and what to do with its bytes once they are here.
//
// Two facts the message row and the viewer both need, kept in one place so
// they cannot answer them differently: which of the four kinds a media type
// is, and how a file's size reads to a person.
//
// Both are decisions about values, with no document in sight, which is what
// lets the hermetic suite hold them. Saving a file is a document effect and
// lives next door in `download.ts`.

/** The four ways this interface can present a posted file. A viewer opens the
 * first two full-screen, plays the third in place, and offers the fourth as a
 * download, so this is the one decision every media component branches on. */
export type MediaKind = "image" | "video" | "audio" | "file";

export function kindOf(mime: string): MediaKind {
	if (mime.startsWith("image/")) return "image";
	if (mime.startsWith("video/")) return "video";
	if (mime.startsWith("audio/")) return "audio";
	return "file";
}

/** How big a file reads to a person: bytes up to a kilobyte, then one decimal
 * place, because "1.4 MB" is what a reader is deciding on and "1468006 bytes"
 * is not. */
export function fileSize(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} kB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
