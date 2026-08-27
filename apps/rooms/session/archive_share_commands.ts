// CapTP command admission for runtime-only archive shares.

import { type Argument, type Behavior } from "@pancake/runtime";
import type { RoomsSessionFacet } from "../lib/rooms_session.ts";
import type { DurableRoomsRuntime } from "./runtime.ts";
import { archiveRecordRow } from "../lib/archive.ts";

export const ARCHIVE_SHARE_UNHANDLED = Symbol("archive share verb not handled");

export function dispatchArchiveShareCommand(
	rights: RoomsSessionFacet,
	verb: string,
	args: Argument[],
	runtime: DurableRoomsRuntime,
): ReturnType<Behavior> | typeof ARCHIVE_SHARE_UNHANDLED {
	if (
		verb !== "shareArchive" && verb !== "readArchiveShare" && verb !== "dropArchiveShare"
	) return ARCHIVE_SHARE_UNHANDLED;
	if (rights === "observe") throw new Error("this Rooms session facet cannot share archive history");
	if (verb === "shareArchive") {
		if (args.length !== 1 || typeof args[0] !== "string") {
			throw new Error("shareArchive takes one direct conversation id");
		}
		return runtime.shareArchiveHistory(args[0]).then(() => null) as ReturnType<Behavior>;
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
