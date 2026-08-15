// Handing a file to the browser to save.
//
// One function, and it is here rather than beside the media decisions in
// `media.ts` because it reaches for the document: keeping the two apart is
// what lets those decisions be held by a test that never opens a page.

/** Save these bytes under this name.
 *
 * An anchor carrying `download` is what a browser understands as saving a
 * file, so the click is handed to one rather than reimplemented. It is built
 * and discarded here because the control the reader actually pressed had to
 * fetch the bytes first, and by then the press is over. */
export function saveAs(url: string, name: string): void {
	const link = document.createElement("a");
	link.href = url;
	link.download = name;
	link.click();
}
