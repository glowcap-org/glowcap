// Person-to-person archive handover over a live DM (ADR-0140).
//
// Live `handArchive` dies with its session. Durable `offerArchive` carries a
// Host publication the archive peer can revoke independently.

import { retainSecondaryFailure } from "@glowcap/runtime";
import * as store from "../store.ts";
import {
	archiveConversationIdentity,
	archiveShareFilter,
	type ArchiveShareKind,
} from "../../../lib/archive/handover.ts";
import type { ArchiveFilter } from "../../../lib/archive/protocol.ts";
import { reason } from "./common.ts";
import { openDm } from "./direct.ts";
import { notRegisteredForDirect } from "../commands/targets.ts";
import { hydrateDm } from "./history.ts";
import { convSession, type Live } from "./live.ts";
import type { RoomsPageContext } from "../page.ts";
import type { Conv, DmConv } from "../types.ts";
import type { ArchiveTargetController } from "./archive_target.ts";

interface PreparedShare {
	readonly home: Live;
	readonly conv: Conv;
	readonly kind: ArchiveShareKind;
	readonly pipe: DmConv;
	readonly scope: ArchiveFilter;
}

function prepareShare(
	page: RoomsPageContext,
	key: string,
	peer: string | undefined,
	records: "line" | "standing",
): PreparedShare | string {
	const projection = page.projection;
	const conv = store.getConv(projection, key);
	const home = convSession(page, key);
	if (conv == null || home === null) return "This conversation is not connected right now.";
	if (conv.type === "directory") return "This view has no archive to share.";
	const kind: ArchiveShareKind = records === "standing" ? "standing" : conv.type === "room" ? "room" : "direct";
	if (kind !== "direct" && (peer == null || peer.trim() === "")) {
		return "Name the member who should receive this archive account.";
	}
	let pipe = conv.type === "dm" ? conv : null;
	if (kind !== "direct") {
		const who = peer!.trim();
		if (store.isSelf(projection, home.id, who)) return "You can't share archive history with yourself.";
		const registration = store.peerRegistration(projection, home.id, who);
		if (registration == null) return notRegisteredForDirect(who);
		pipe = store.ensureDm(projection, home.id, registration.name, registration.registrationId);
		// The only way a pipe comes back missing is that the name resolved to
		// this reader, which the check above catches under whatever they typed
		// and this one catches under the name it registered.
		if (pipe === null) return "You can't share archive history with yourself.";
		hydrateDm(page, pipe);
	}
	if (pipe == null) return "This direct conversation is not connected right now.";
	return {
		home,
		conv,
		kind,
		pipe,
		scope: archiveShareFilter(
			kind,
			home.id,
			kind === "direct" ? pipe.persistId : archiveConversationIdentity(conv),
		),
	};
}

function namedAccount(kind: ArchiveShareKind, conv: Conv, pipe: DmConv): string {
	return kind === "direct" ? pipe.id : conv.type === "room" ? conv.id : "this directory";
}

/** Hand a scoped read-only archive facet over a live DM. The pipe is a person;
 * the facet scope is the named conversation's archive coordinate. */
export async function shareArchiveHistory(
	page: RoomsPageContext,
	archives: ArchiveTargetController,
	key: string,
	peer?: string,
	records: "line" | "standing" = "line",
): Promise<string> {
	const prepared = prepareShare(page, key, peer, records);
	if (typeof prepared === "string") return prepared;
	const { home, conv, kind, pipe, scope } = prepared;
	let facet: Awaited<ReturnType<ArchiveTargetController["prepareArchiveFacet"]>> | null = null;
	try {
		facet = await archives.prepareArchiveFacet(home, scope);
		const dm = await openDm(page, pipe);
		await dm.handArchive(home.id, kind, scope.conversation, facet.ref);
		store.deliver(
			page.projection,
			pipe.key,
			store.sysItem(
				page.projection,
				kind === "standing"
					? `You shared a read-only archive standing for ${namedAccount(kind, conv, pipe)} with ${pipe.id}.`
					: `You shared a read-only archive account of ${namedAccount(kind, conv, pipe)} with ${pipe.id}.`,
			),
		);
		return "";
	} catch (error) {
		const why = reason(error);
		store.deliver(
			page.projection,
			pipe.key,
			store.sysItem(page.projection, `Could not share archive history: ${why}`),
		);
		return why;
	} finally {
		facet?.release();
	}
}

/** Publish a revocable archive-peer share and offer its sturdyref over a DM. */
export async function offerDurableArchive(
	page: RoomsPageContext,
	archives: ArchiveTargetController,
	key: string,
	peer?: string,
	records: "line" | "standing" = "line",
): Promise<string> {
	const prepared = prepareShare(page, key, peer, records);
	if (typeof prepared === "string") return prepared;
	const { home, conv, kind, pipe, scope } = prepared;
	try {
		const dm = await openDm(page, pipe);
		const id = crypto.randomUUID();
		const sturdyref = await archives.issueShare(id, `${kind} archive share`, scope);
		try {
			await dm.offerArchive(home.id, kind, scope.conversation, sturdyref);
		} catch (error) {
			try {
				await archives.revokeShare(id);
			} catch (cleanup) {
				throw retainSecondaryFailure(error, cleanup);
			}
			throw error;
		}
		store.deliver(
			page.projection,
			pipe.key,
			store.sysItem(
				page.projection,
				kind === "standing"
					? `You offered a durable archive standing for ${namedAccount(kind, conv, pipe)} to ${pipe.id}.`
					: `You offered a durable archive account of ${namedAccount(kind, conv, pipe)} to ${pipe.id}.`,
			),
		);
		return "";
	} catch (error) {
		const why = reason(error);
		store.deliver(
			page.projection,
			pipe.key,
			store.sysItem(page.projection, `Could not offer a durable archive share: ${why}`),
		);
		return why;
	}
}
