// The tab's shareable archive occurrence.
//
// Storage is tab-wide, while a Ref is projected on one concrete Session. The
// weak map gives each session one occurrence backed by the same archive; when
// a caller hands that Ref to its partner it crosses as an ordinary OCapN
// capability. No publication or readable swiss name is created implicitly.

import { Ref, type Session } from "@pancake/runtime";
import { spawnArchive } from "../../lib/archive.ts";
import { tabArchiveBackend } from "./archive_store.ts";

const occurrences = new WeakMap<Session, Ref>();

/** The member-owned archive capability hosted on `session`. The caller owns
 * the returned occurrence and decides whether and to whom it is handed. */
export function tabArchiveRef(session: Session): Ref {
	let archive = occurrences.get(session);
	if (archive === undefined) {
		archive = spawnArchive(session, tabArchiveBackend);
		occurrences.set(session, archive);
	}
	return archive;
}
