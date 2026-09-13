// The archive record document, read against what the Rust runtime actually
// writes. The fixture is the runtime's: its proof reads every document there
// through the serde reader the disk archive and the browser projection use and
// writes it back as exactly the same JSON, so a page that reads the fixture
// reads the runtime. A document the page writes must come back unchanged.
//
// A field renamed on either side turns one of the two readers red. That is
// the whole point of sharing one file: the first version of this test read a
// fixture whose inputs carried neither name for the link previews, and stayed
// green while the reader refused every real line.

import { archiveRecordDocument, parseArchiveRecordDocument } from "../../lib/archive/record_document.ts";
import { archiveRecordRow, parseArchiveRecord } from "../../lib/archive/protocol.ts";
import { assertEquals } from "../assert.ts";

const fixture = JSON.parse(
	await Deno.readTextFile(new URL("../../rust/proofs/fixtures/archive-record-documents.json", import.meta.url)),
) as { documents: Record<string, unknown>[] };
const documents = fixture.documents;
const lines = documents.filter((document) => document.kind === "line");

/** The same document whatever order its keys were written in. */
function canonical(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(canonical);
	if (value === null || typeof value !== "object") return value;
	return Object.fromEntries(
		Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map((
			[key, entry],
		) => [key, canonical(entry)]),
	);
}

function refusal(raw: unknown): string {
	try {
		parseArchiveRecordDocument(raw);
		return "";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}

Deno.test("every runtime record document reads as the page's record and writes back unchanged", () => {
	if (documents.length === 0) throw new Error("the fixture carries no documents");
	let previews = 0;
	let blobs = 0;
	for (const document of documents) {
		const record = parseArchiveRecordDocument(document);
		assertEquals(canonical(archiveRecordDocument(record)), canonical(document));
		// One validator: the document and the wire row are the same record.
		assertEquals(parseArchiveRecord(archiveRecordRow(record)), record);
		if (record.kind === "line") {
			previews += record.previewUrls.length;
			blobs += record.attachments.filter((attachment) => attachment.blob !== null).length;
		}
	}
	// The fields a rename would hide have to be exercised, not merely absent.
	assertEquals(previews > 0, true, "a kept link preview");
	assertEquals(blobs > 0, true, "an attachment with its blob digest");
});

Deno.test("a document with a field the runtime would refuse is refused here too", () => {
	const { previewUrls: _previewUrls, ...rest } = lines[0];
	assertEquals(refusal({ ...rest, previews: [] }), "an archive line document carries an unknown field: previews");
	assertEquals(refusal({ ...lines[0], at: "soon" }), "archive time must be a non-negative safe integer");
});

Deno.test("a document missing its lists reads as the runtime reads it, with both empty", () => {
	const { previewUrls: _previewUrls, attachments: _attachments, ...bare } = lines[1];
	const record = parseArchiveRecordDocument(bare);
	if (record.kind !== "line") throw new Error("expected a line");
	assertEquals(record.previewUrls, []);
	assertEquals(record.attachments, []);
});
