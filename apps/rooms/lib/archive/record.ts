// One archive record: what a recorder writes down, and the one validator every
// form of it answers to. The wire row the archive verbs carry (`protocol.ts`)
// and the document the Rust runtime writes (`record_document.ts`) are two
// spellings of the record defined here, and both read through
// `parseArchiveRecord`, so a field is bounded in exactly one place.
//
// Nothing here touches a session. The page's bundle reads records off its own
// runtime through this module, and a runtime import would drag the native
// binding in with it.

import type { Argument } from "@glowcap/runtime";
import { MAX_ARCHIVE_CONVERSATION_BYTES } from "../application_data.ts";
import { MAX_LINE, nickRefusal, utf8Fits } from "../limits.ts";
import type { ArchiveConversationKind } from "./scope.ts";
import { type ArchivedAttachment, archivedAttachmentRows, parseArchivedAttachments } from "./record_attachments.ts";

/** Opaque recorder coordinates are deliberately small bearer-independent
 * labels. The shipped tab mints 128 bits as printable UUID text. */
export const MAX_ARCHIVE_ID_BYTES = 128;
/** Directory locators and contextual conversation labels are data from
 * another peer. Bound them independently of the much smaller room vocabulary. */
export const MAX_ARCHIVE_CONTEXT_BYTES = 8192;
export { MAX_ARCHIVE_CONVERSATION_BYTES };
const MAX_ARCHIVE_LINK_PREVIEWS = 5;
const MAX_ARCHIVE_LINK_PREVIEW_URL_BYTES = 2_048;

export type ArchiveLineState = "present" | "edited" | "withdrawn";

export interface ArchiveCoordinates {
	/** Opaque stable identity minted by this recorder. It is not a person ID. */
	readonly source: string;
	/** Opaque identity for one live conversation as this recorder saw it. */
	readonly generation: string;
	/** Opaque identity for this record inside the generation. */
	readonly id: string;
}

/** Where the recorder stood: enough to offer a returning reader the same
 * place again, without claiming that its names still have the same holders. */
export interface ArchiveStanding extends ArchiveCoordinates {
	readonly kind: "standing";
	readonly directory: string;
	readonly room: string;
	readonly nick: string;
	readonly at: number;
}

/** One line as this recorder saw it. File metadata preserves the message's
 * shape; byte custody remains separate capability authority. */
export interface ArchiveLine extends ArchiveCoordinates {
	readonly kind: "line";
	readonly conversationKind: ArchiveConversationKind;
	readonly directory: string;
	readonly conversation: string;
	readonly from: string;
	readonly text: string;
	readonly mine: boolean;
	/** Time this line first entered the recorder. Later mutations keep it. */
	readonly at: number;
	/** Positive monotone position assigned by the live conversation generation.
	 * Coordinates remain identity-only. */
	readonly order: number;
	readonly state: ArchiveLineState;
	/** The exact link-preview subset the author kept for this line. */
	readonly previewUrls: readonly string[];
	readonly attachments: readonly ArchivedAttachment[];
}

export type ArchiveRecord = ArchiveStanding | ArchiveLine;

export function boundedString(raw: unknown, what: string, maxBytes: number, empty = false): string {
	if (typeof raw !== "string") throw new Error(`${what} must be text`);
	if (!empty && raw.length === 0) throw new Error(`${what} may not be empty`);
	if (!utf8Fits(raw, maxBytes)) throw new Error(`${what} is too long`);
	return raw;
}

export function opaqueId(raw: unknown, what: string): string {
	const value = boundedString(raw, what, MAX_ARCHIVE_ID_BYTES);
	// These are coordinates, never display text. Excluding controls (the C0 and
	// C1 ranges, delete included) makes their accidental appearance in logs
	// unambiguous and keeps composite keys safe.
	if (/\p{Cc}/u.test(value)) throw new Error(`${what} contains a control character`);
	return value;
}

export function parseArchiveCoordinates(source: unknown, generation: unknown, id: unknown): ArchiveCoordinates {
	return {
		source: opaqueId(source, "archive source"),
		generation: opaqueId(generation, "archive generation"),
		id: opaqueId(id, "archive record id"),
	};
}

function archiveName(raw: unknown, what: string): string {
	if (typeof raw !== "string") throw new Error(`${what} must be text`);
	const refusal = nickRefusal(raw);
	if (refusal !== null) throw new Error(`${what}: ${refusal}`);
	return raw;
}

function timestamp(raw: unknown): number {
	if (typeof raw !== "bigint" || raw < 0n || raw > BigInt(Number.MAX_SAFE_INTEGER)) {
		throw new Error("archive time must be a non-negative safe integer");
	}
	return Number(raw);
}

function conversationOrder(raw: unknown): number {
	if (typeof raw !== "bigint" || raw < 1n || raw > BigInt(Number.MAX_SAFE_INTEGER)) {
		throw new Error("archive line order must be a positive safe integer");
	}
	return Number(raw);
}

function readCommon(raw: Argument[]): ArchiveCoordinates {
	return parseArchiveCoordinates(raw[1], raw[2], raw[3]);
}

function parseArchivePreviewUrls(raw: unknown): string[] {
	if (!Array.isArray(raw) || raw.length > MAX_ARCHIVE_LINK_PREVIEWS) {
		throw new Error(`an archive line may carry at most ${MAX_ARCHIVE_LINK_PREVIEWS} link previews`);
	}
	const urls = raw.map((url) => boundedString(url, "archive link preview", MAX_ARCHIVE_LINK_PREVIEW_URL_BYTES));
	if (new Set(urls).size !== urls.length) throw new Error("an archive line repeats a link preview");
	return urls;
}

/** Decode and validate the exact passable record tuple accepted by `put`. */
export function parseArchiveRecord(raw: unknown): ArchiveRecord {
	if (!Array.isArray(raw)) throw new Error("archive put needs one record row");
	if (raw[0] === "standing") {
		if (raw.length !== 8) throw new Error("an archive standing row has the wrong shape");
		return {
			kind: "standing",
			...readCommon(raw as Argument[]),
			directory: boundedString(raw[4], "archive directory", MAX_ARCHIVE_CONTEXT_BYTES),
			room: boundedString(raw[5], "archive room", MAX_ARCHIVE_CONVERSATION_BYTES),
			nick: archiveName(raw[6], "archive nickname"),
			at: timestamp(raw[7]),
		};
	}
	if (raw[0] === "line") {
		if (raw.length !== 14 && raw.length !== 15) throw new Error("an archive line row has the wrong shape");
		const conversationKind = raw[4];
		if (conversationKind !== "room" && conversationKind !== "direct") {
			throw new Error("an archive line needs a conversation kind");
		}
		const state = raw[12];
		if (state !== "present" && state !== "edited" && state !== "withdrawn") {
			throw new Error("an archive line needs a state");
		}
		const text = boundedString(raw[8], "archive line", MAX_LINE, true);
		if (state === "withdrawn" && text !== "") throw new Error("a withdrawn archive line must erase its text");
		if (typeof raw[9] !== "boolean") throw new Error("an archive line needs its local direction");
		const attachments = parseArchivedAttachments(raw[13]);
		const previewUrls = raw.length === 15 ? parseArchivePreviewUrls(raw[14]) : [];
		if (state === "withdrawn" && attachments.length > 0) {
			throw new Error("a withdrawn archive line must erase its attachment metadata");
		}
		if (state === "withdrawn" && previewUrls.length > 0) {
			throw new Error("a withdrawn archive line must erase its link previews");
		}
		return {
			kind: "line",
			...readCommon(raw as Argument[]),
			conversationKind,
			directory: boundedString(raw[5], "archive directory", MAX_ARCHIVE_CONTEXT_BYTES),
			conversation: boundedString(raw[6], "archive conversation", MAX_ARCHIVE_CONVERSATION_BYTES),
			from: archiveName(raw[7], "archive sender"),
			text,
			mine: raw[9],
			at: timestamp(raw[10]),
			order: conversationOrder(raw[11]),
			state,
			previewUrls,
			attachments,
		};
	}
	throw new Error("archive record kind is unknown");
}

/** Encode one record without its storage-owned revision. */
export function archiveRecordRow(record: ArchiveRecord): Argument[] {
	if (record.kind === "standing") {
		return [
			"standing",
			record.source,
			record.generation,
			record.id,
			record.directory,
			record.room,
			record.nick,
			BigInt(record.at),
		];
	}
	return [
		"line",
		record.source,
		record.generation,
		record.id,
		record.conversationKind,
		record.directory,
		record.conversation,
		record.from,
		record.text,
		record.mine,
		BigInt(record.at),
		BigInt(record.order),
		record.state,
		archivedAttachmentRows(record.attachments),
		[...record.previewUrls],
	];
}
