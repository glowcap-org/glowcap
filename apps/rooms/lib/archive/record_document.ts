// The archive record as the Rust runtime writes it: one JSON document per
// record, keyed the way its disk archive and its browser projection key it.
// `protocol.ts` owns the wire row the archive verbs carry and the one
// validator behind it; this module owns the document, in both directions, so a
// record crossing from the wasm session is parsed at that boundary rather than
// trusted across it, and a record handed back for its bytes is written in the
// form the runtime reads.

import type { Argument } from "@glowcap/runtime";
import type { ArchivedAttachment } from "./record_attachments.ts";
import { type ArchiveLine, type ArchiveRecord, parseArchiveRecord } from "./record.ts";

export interface ArchivedAttachmentDocument {
	readonly name: string;
	readonly mime: string;
	readonly size: number;
	readonly width: number;
	readonly height: number;
	readonly blob: string | null;
}

interface ArchiveDocumentCommon {
	readonly source: string;
	readonly generation: string;
	readonly id: string;
	readonly directory: string;
	readonly at: number;
}

export interface ArchiveStandingDocument extends ArchiveDocumentCommon {
	readonly kind: "standing";
	readonly room: string;
	readonly nick: string;
}

export interface ArchiveLineDocument extends ArchiveDocumentCommon {
	readonly kind: "line";
	readonly conversationKind: ArchiveLine["conversationKind"];
	readonly conversation: string;
	readonly from: string;
	readonly text: string;
	readonly mine: boolean;
	readonly order: number;
	readonly state: ArchiveLine["state"];
	readonly previewUrls: readonly string[];
	readonly attachments: readonly ArchivedAttachmentDocument[];
}

export type ArchiveRecordDocument = ArchiveStandingDocument | ArchiveLineDocument;

const STANDING_KEYS = ["kind", "source", "generation", "id", "directory", "room", "nick", "at"] as const;
const LINE_KEYS = [
	"kind",
	"source",
	"generation",
	"id",
	"directory",
	"conversationKind",
	"conversation",
	"from",
	"text",
	"mine",
	"at",
	"order",
	"state",
	"previewUrls",
	"attachments",
] as const;
const ATTACHMENT_KEYS = ["name", "mime", "size", "width", "height", "blob"] as const;

function fields(raw: unknown, what: string, known: readonly string[]): Record<string, unknown> {
	if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
		throw new Error(`${what} must be a document`);
	}
	const document = raw as Record<string, unknown>;
	for (const key of Object.keys(document)) {
		if (!known.includes(key)) throw new Error(`${what} carries an unknown field: ${key}`);
	}
	return document;
}

/** A safe integer becomes the wire's integer; anything else stays as it is,
 * so the row validator refuses it with the sentence that names the field. */
function integer(raw: unknown): Argument {
	return typeof raw === "number" && Number.isSafeInteger(raw) ? BigInt(raw) : (raw as Argument);
}

function attachmentRow(raw: unknown): Argument {
	if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return raw as Argument;
	const attachment = fields(raw, "an archive attachment document", ATTACHMENT_KEYS);
	return [
		attachment.name as Argument,
		attachment.mime as Argument,
		integer(attachment.size),
		integer(attachment.width),
		integer(attachment.height),
		attachment.blob as Argument,
	];
}

/** Read one record document as the runtime wrote it. Every field answers to
 * the same validator the wire row answers to; an unknown field is refused the
 * way the runtime refuses one, so the two readers cannot drift apart quietly. */
export function parseArchiveRecordDocument(raw: unknown): ArchiveRecord {
	const kind = raw !== null && typeof raw === "object" && !Array.isArray(raw)
		? (raw as { kind?: unknown }).kind
		: undefined;
	if (kind === "standing") {
		const document = fields(raw, "an archive standing document", STANDING_KEYS);
		return parseArchiveRecord([
			"standing",
			document.source as Argument,
			document.generation as Argument,
			document.id as Argument,
			document.directory as Argument,
			document.room as Argument,
			document.nick as Argument,
			integer(document.at),
		]);
	}
	if (kind === "line") {
		const document = fields(raw, "an archive line document", LINE_KEYS);
		// The runtime writes both lists on every line and reads either as empty
		// when it is missing, so a document it would accept is accepted here.
		const previews = document.previewUrls ?? [];
		const attachments = Array.isArray(document.attachments)
			? document.attachments.map(attachmentRow)
			: document.attachments ?? [];
		return parseArchiveRecord([
			"line",
			document.source as Argument,
			document.generation as Argument,
			document.id as Argument,
			document.conversationKind as Argument,
			document.directory as Argument,
			document.conversation as Argument,
			document.from as Argument,
			document.text as Argument,
			document.mine as Argument,
			integer(document.at),
			integer(document.order),
			document.state as Argument,
			attachments as Argument,
			previews as Argument,
		]);
	}
	throw new Error("archive record kind is unknown");
}

function attachmentDocument(attachment: ArchivedAttachment): ArchivedAttachmentDocument {
	return {
		name: attachment.name,
		mime: attachment.mime,
		size: attachment.size,
		width: attachment.width,
		height: attachment.height,
		blob: attachment.blob,
	};
}

/** Write one record in the runtime's document form. */
export function archiveRecordDocument(record: ArchiveRecord): ArchiveRecordDocument {
	if (record.kind === "standing") {
		return {
			kind: "standing",
			source: record.source,
			generation: record.generation,
			id: record.id,
			directory: record.directory,
			room: record.room,
			nick: record.nick,
			at: record.at,
		};
	}
	return {
		kind: "line",
		source: record.source,
		generation: record.generation,
		id: record.id,
		directory: record.directory,
		conversationKind: record.conversationKind,
		conversation: record.conversation,
		from: record.from,
		text: record.text,
		mine: record.mine,
		at: record.at,
		order: record.order,
		state: record.state,
		previewUrls: [...record.previewUrls],
		attachments: record.attachments.map(attachmentDocument),
	};
}
