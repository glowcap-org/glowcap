import type { TraceEvent } from "@pancake/runtime";
import { MAX_FIELD_BYTES, MAX_LINE_BYTES } from "./policy.ts";

export function utf8Bytes(value: string): number {
	let bytes = 0;
	for (let i = 0; i < value.length; i += 1) {
		const unit = value.charCodeAt(i);
		if (unit <= 0x7f) {
			bytes += 1;
		} else if (unit <= 0x7ff) {
			bytes += 2;
		} else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < value.length) {
			const next = value.charCodeAt(i + 1);
			if (next >= 0xdc00 && next <= 0xdfff) {
				bytes += 4;
				i += 1;
			} else {
				bytes += 3;
			}
		} else {
			// TextEncoder replaces an unpaired surrogate with U+FFFD.
			bytes += 3;
		}
	}
	return bytes;
}

const allowedByKind = {
	"ocapn.session-opened": new Set([
		"v",
		"sim_t_ns",
		"kind",
		"session",
		"a",
		"a_label",
		"a_profile",
		"b",
		"transport",
		"session_id",
		"provenance",
		"codec",
		"captp_version",
		"dropped",
	]),
	"ocapn.message-decoded": new Set([
		"v",
		"sim_t_ns",
		"kind",
		"session",
		"outbound",
		"op",
		"digest",
		"len",
		"bytes_b64",
		"summary",
		"dropped",
	]),
	"ocapn.session-closed": new Set(["v", "sim_t_ns", "kind", "session", "dropped"]),
	"ocapn.session-meta": new Set(["v", "sim_t_ns", "kind", "session", "meta"]),
} as const;

type RecordKind = keyof typeof allowedByKind;

function boundedString(value: unknown, required = false): value is string {
	if (typeof value !== "string") return false;
	if (required && value.length === 0) return false;
	return utf8Bytes(value) <= MAX_FIELD_BYTES;
}

function nonNegativeInteger(value: unknown): value is number {
	return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function nonNegativeNumber(value: unknown): value is number {
	return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function base64Value(unit: number): number {
	if (unit >= 0x41 && unit <= 0x5a) return unit - 0x41;
	if (unit >= 0x61 && unit <= 0x7a) return unit - 0x61 + 26;
	if (unit >= 0x30 && unit <= 0x39) return unit - 0x30 + 52;
	if (unit === 0x2b) return 62;
	if (unit === 0x2f) return 63;
	return -1;
}

function base64DecodedLength(value: string): number | null {
	if (value.length === 0) return 0;
	if (value.length % 4 !== 0) return null;
	let padding = 0;
	if (value.endsWith("=")) padding += 1;
	if (value.endsWith("==")) padding += 1;
	const dataLength = value.length - padding;
	for (let i = 0; i < dataLength; i += 1) {
		if (base64Value(value.charCodeAt(i)) < 0) return null;
	}
	for (let i = dataLength; i < value.length; i += 1) {
		if (value.charCodeAt(i) !== 0x3d) return null;
	}
	// Canonical RFC 4648 padding leaves no set bits beyond the decoded bytes.
	if (padding === 2 && (base64Value(value.charCodeAt(dataLength - 1)) & 0x0f) !== 0) return null;
	if (padding === 1 && (base64Value(value.charCodeAt(dataLength - 1)) & 0x03) !== 0) return null;
	return value.length / 4 * 3 - padding;
}

function validCommon(rec: Record<string, unknown>, kind: RecordKind): boolean {
	if (rec.v !== 1 || rec.kind !== kind) return false;
	if (!nonNegativeNumber(rec.sim_t_ns)) return false;
	if (!boundedString(rec.session, true)) return false;
	if (rec.dropped !== undefined && !nonNegativeInteger(rec.dropped)) return false;
	const allowed: ReadonlySet<string> = allowedByKind[kind];
	for (const field of Object.keys(rec)) if (!allowed.has(field)) return false;
	return true;
}

function validOpened(rec: Record<string, unknown>): boolean {
	if (!boundedString(rec.a, true) || !boundedString(rec.b, true) || !boundedString(rec.transport, true)) return false;
	for (const field of ["a_label", "a_profile"]) {
		if (rec[field] !== undefined && !boundedString(rec[field])) return false;
	}
	if (rec.session_id !== undefined && (!boundedString(rec.session_id) || !/^[0-9a-f]{64}$/.test(rec.session_id))) {
		return false;
	}
	if (rec.codec !== undefined && rec.codec !== "syrup" && rec.codec !== "capnp") return false;
	if (rec.captp_version !== undefined && rec.captp_version !== "1.0" && rec.captp_version !== "pancake-next") {
		return false;
	}
	if (
		rec.provenance !== undefined && rec.provenance !== "authenticated-transport" &&
		rec.provenance !== "unauthenticated"
	) return false;
	return true;
}

function validMessage(rec: Record<string, unknown>): boolean {
	if (typeof rec.outbound !== "boolean") return false;
	if (rec.op !== undefined && !boundedString(rec.op)) return false;
	if (!boundedString(rec.digest) || !/^[0-9a-f]{32}$/.test(rec.digest)) return false;
	if (rec.len !== undefined && !nonNegativeInteger(rec.len)) return false;
	// Payload text is bounded by the aggregate line budget. The ordinary field
	// cap cannot apply here: 4096 captured bytes require 5464 base64 characters.
	if (rec.bytes_b64 !== undefined) {
		if (typeof rec.bytes_b64 !== "string" || rec.len === undefined) return false;
		if (base64DecodedLength(rec.bytes_b64) !== rec.len) return false;
	}
	if (rec.bytes_b64 !== undefined && rec.summary !== undefined) return false;
	if (rec.summary === undefined) return true;
	if (typeof rec.summary !== "object" || rec.summary === null || Array.isArray(rec.summary)) return false;
	const summary = rec.summary as Record<string, unknown>;
	if (Object.keys(summary).some((field) => field !== "len" && field !== "head_b64")) return false;
	if (!nonNegativeInteger(summary.len) || summary.len !== rec.len || typeof summary.head_b64 !== "string") {
		return false;
	}
	const headLength = base64DecodedLength(summary.head_b64);
	return headLength !== null && headLength <= summary.len;
}

function validMeta(rec: Record<string, unknown>): boolean {
	if (typeof rec.meta !== "object" || rec.meta === null || Array.isArray(rec.meta)) return false;
	const meta = rec.meta as Record<string, unknown>;
	if (Object.keys(meta).some((field) => field !== "label")) return false;
	return meta.label === undefined || meta.label === null || boundedString(meta.label);
}

/** Admit only bounded records that satisfy the kind-specific trace schema. */
export function parseRecord(line: string): TraceEvent | null {
	if (utf8Bytes(line) > MAX_LINE_BYTES) return null;
	let raw: unknown;
	try {
		raw = JSON.parse(line);
	} catch {
		return null;
	}
	if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null;
	const rec = raw as Record<string, unknown>;
	if (typeof rec.kind !== "string" || !Object.hasOwn(allowedByKind, rec.kind)) return null;
	const kind = rec.kind as RecordKind;
	delete rec.seq;
	delete rec.epoch;
	delete rec.replay;
	if (!validCommon(rec, kind)) return null;
	if (kind === "ocapn.session-opened" && !validOpened(rec)) return null;
	if (kind === "ocapn.message-decoded" && !validMessage(rec)) return null;
	if (kind === "ocapn.session-meta" && !validMeta(rec)) return null;
	return rec as unknown as TraceEvent;
}
