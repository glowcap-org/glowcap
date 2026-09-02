// The tab's shareable archive occurrence.
//
// Storage belongs to the page's archive backend, while a Ref is projected on
// one concrete Session. The weak map gives each session one occurrence backed
// by that backend; when a caller hands that Ref to its partner it crosses as an
// ordinary OCapN capability. No publication or readable swiss name is created
// implicitly.

import { Ref, type Session } from "@glowcap/runtime";
import { spawnArchive } from "../../lib/archive/protocol.ts";
import type { RoomsPageContext } from "./page.ts";

/** Session-keyed archive Refs for this page's member-owned backend. */
export class PageArchiveRefs {
	readonly occurrences = new WeakMap<Session, Ref>();
}

/** The member-owned archive capability hosted on `session`. The caller owns
 * the returned occurrence and decides whether and to whom it is handed. */
export function tabArchiveRef(page: RoomsPageContext, session: Session): Ref {
	const held = page.archiveRefs.occurrences;
	let archive = held.get(session);
	if (archive === undefined) {
		archive = spawnArchive(session, page.archive);
		held.set(session, archive);
	}
	return archive;
}
