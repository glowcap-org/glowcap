// Positional CapTP encoding for a durable Rooms session snapshot.

import type { Argument } from "@pancake/runtime";
import type { RoomsSessionDirectoryView, RoomsSessionRoomView } from "../lib/session/client.ts";
import type { RoomsSessionGrantView } from "../lib/session/grants.ts";
import type { RoomsSessionAccess } from "../lib/session/grants.ts";
import { MAX_SESSION_ISSUES, ROOMS_SESSION_SNAPSHOT_VERSION } from "../lib/session/messages.ts";
import type { RoomsSessionState } from "../lib/rooms_state.ts";
import type { RoomsSessionWorkspaceAdoption } from "../lib/session/adoption.ts";
import type { DurableArchiveShareView } from "./archive_shares.ts";
import type { DurableHandedRoomView } from "./handed_rooms.ts";

const MAX_SESSION_SNAPSHOT_TEXT_BYTES = 900 * 1024;

function utf8Bytes(value: string): number {
	let bytes = 0;
	for (let at = 0; at < value.length; at += 1) {
		const code = value.charCodeAt(at);
		if (code < 0x80) bytes += 1;
		else if (code < 0x800) bytes += 2;
		else if (
			code >= 0xd800 && code <= 0xdbff &&
			value.charCodeAt(at + 1) >= 0xdc00 && value.charCodeAt(at + 1) <= 0xdfff
		) {
			bytes += 4;
			at += 1;
		} else bytes += 3;
	}
	return bytes;
}

export function assertSessionSnapshotSize(values: readonly Argument[]): void {
	let bytes = 0;
	const count = (value: Argument): void => {
		if (typeof value === "string") bytes += utf8Bytes(value);
		else if (Array.isArray(value)) { for (const entry of value) count(entry); }
	};
	for (const value of values) count(value);
	if (bytes > MAX_SESSION_SNAPSHOT_TEXT_BYTES) {
		throw new Error("the Rooms session snapshot exceeds its complete wire-text budget");
	}
}

export function fitSessionSnapshot(values: Argument[]): Argument[] {
	try {
		assertSessionSnapshotSize(values);
		return values;
	} catch (error) {
		const overflow = [
			"snapshot-overflow",
			error instanceof Error ? error.message : "the Rooms session snapshot is too large",
		];
		const withoutLiveViews = [...values];
		const priorIssues = Array.isArray(values[3]) ? values[3].slice(0, MAX_SESSION_ISSUES - 1) : [];
		withoutLiveViews[3] = [...priorIssues, overflow];
		withoutLiveViews[7] = "[]";
		withoutLiveViews[8] = "[]";
		withoutLiveViews[9] = "[]";
		withoutLiveViews[11] = "[]";
		try {
			assertSessionSnapshotSize(withoutLiveViews);
			return withoutLiveViews;
		} catch {
			const checkpointOnly = [...withoutLiveViews];
			checkpointOnly[3] = [overflow];
			checkpointOnly[5] = [];
			assertSessionSnapshotSize(checkpointOnly);
			return checkpointOnly;
		}
	}
}

export function encodeSessionSnapshot(
	revision: number,
	checkpoint: RoomsSessionState,
	pendingEffects: readonly string[],
	issues: readonly { subject: string; reason: string }[],
	connectedDirectories: readonly string[],
	pendingEffectDetails: readonly Argument[],
	memberLocator: string | null,
	roomViews: readonly RoomsSessionRoomView[],
	archiveShares: readonly DurableArchiveShareView[],
	directoryViews: readonly RoomsSessionDirectoryView[],
	access: RoomsSessionAccess = "admin",
	workspaceAdoption: RoomsSessionWorkspaceAdoption = "closed",
	grants: readonly RoomsSessionGrantView[] = [],
	handedRooms: readonly DurableHandedRoomView[] = [],
	suspendedNote = "",
): Argument[] {
	const encoded = [
		BigInt(revision),
		JSON.stringify(checkpoint),
		[...pendingEffects],
		issues.map((issue) => [issue.subject, issue.reason]),
		[...connectedDirectories],
		[...pendingEffectDetails],
		memberLocator,
		JSON.stringify(roomViews),
		JSON.stringify(archiveShares),
		JSON.stringify(directoryViews),
		encodeSessionAccess(access, workspaceAdoption, grants, suspendedNote),
		JSON.stringify(handedRooms),
	] as Argument[];
	return fitSessionSnapshot(encoded);
}

export function encodeSessionAccess(
	access: RoomsSessionAccess,
	workspaceAdoption: RoomsSessionWorkspaceAdoption,
	grants: readonly RoomsSessionGrantView[],
	/** Why this view has no access, when it has none. It travels with the access
	 * rather than beside it, because a holder reading "none" is exactly the
	 * holder who needs the reason. */
	suspendedNote = "",
): string {
	// The note is sent only when there is one. Nothing is suspended most of the
	// time, and an empty string would be a second way of saying what `rights`
	// already says.
	return JSON.stringify({
		version: ROOMS_SESSION_SNAPSHOT_VERSION,
		rights: access,
		workspaceAdoption,
		grants,
		...(suspendedNote === "" ? {} : { suspendedNote }),
	});
}
