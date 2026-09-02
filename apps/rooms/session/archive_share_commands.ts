// CapTP command admission for runtime-only archive shares.

import { type Argument, type Behavior } from "@glowcap/runtime";
import { mayInteract, type RoomsSessionAccess } from "../lib/session/client.ts";
import type { DurableRoomsRuntime } from "./runtime.ts";
import { archiveRecordRow } from "../lib/archive/protocol.ts";
import { parseArchiveShareKind } from "../lib/archive/handover.ts";

export const ARCHIVE_SHARE_UNHANDLED = Symbol("archive share verb not handled");

export function dispatchArchiveShareCommand(
	rights: RoomsSessionAccess,
	verb: string,
	args: Argument[],
	runtime: DurableRoomsRuntime,
): ReturnType<Behavior> | typeof ARCHIVE_SHARE_UNHANDLED {
	if (
		verb !== "shareArchive" && verb !== "readArchiveShare" && verb !== "dropArchiveShare" &&
		verb !== "offerDurableArchive" && verb !== "listArchiveShares" && verb !== "revokeArchiveShare"
	) return ARCHIVE_SHARE_UNHANDLED;
	if (!mayInteract(rights)) throw new Error("this Rooms session facet cannot share archive history");
	if (verb === "listArchiveShares") {
		if (args.length !== 0) throw new Error("listArchiveShares takes no arguments");
		return runtime.listIssuedArchiveShares().then((listed) =>
			listed.map((share) => [share.id, share.label, [
				share.filter.source,
				share.filter.generation,
				share.filter.kind,
				share.filter.conversationKind,
				share.filter.directory,
				share.filter.conversation,
				share.filter.digest,
			], share.sturdyref])
		) as ReturnType<Behavior>;
	}
	if (verb === "revokeArchiveShare") {
		if (args.length !== 1 || typeof args[0] !== "string") {
			throw new Error("revokeArchiveShare takes one share id");
		}
		return runtime.revokeIssuedArchiveShare(args[0]).then((revoked) => revoked) as ReturnType<Behavior>;
	}
	if (verb === "shareArchive" || verb === "offerDurableArchive") {
		if (
			args.length < 2 || args.length > 3 || typeof args[0] !== "string" || typeof args[1] !== "string" ||
			(args.length === 3 && typeof args[2] !== "string")
		) {
			throw new Error(`${verb} takes a kind, conversation id, and optional peer`);
		}
		const kind = parseArchiveShareKind(args[0]);
		const conversationId = args[1];
		const peer = typeof args[2] === "string" ? args[2] : "";
		return (verb === "offerDurableArchive"
			? runtime.offerDurableArchive(kind, conversationId, peer)
			: runtime.shareArchiveHistory(kind, conversationId, peer)).then(() => null) as ReturnType<Behavior>;
	}
	if (
		args.length < 1 || args.length > 2 || typeof args[0] !== "string" ||
		(args.length === 2 &&
			(typeof args[1] !== "bigint" || args[1] < 0n || args[1] > BigInt(Number.MAX_SAFE_INTEGER)))
	) {
		throw new Error(`${verb} takes an archive share id and optional revision cursor`);
	}
	const id = args[0];
	if (verb === "dropArchiveShare") {
		runtime.dropArchiveShare(id);
		return null;
	}
	const after = args.length === 2 ? Number(args[1]) : 0;
	return runtime.readArchiveShare(id, after).then(({ view, page }) => [
		JSON.stringify(view),
		BigInt(page.next),
		page.more,
		page.records.map((entry) => archiveRecordRow(entry.record)),
	]) as ReturnType<Behavior>;
}
