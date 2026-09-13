// Carrying a session snapshot's shared state into the store: directory
// standings, room and direct-line rows, drafts, invitations, the ignore list,
// what the join card remembers, and the archive shares on offer.
//
// Every snapshot passes through here, and a snapshot arrives for a member
// coming online anywhere. So each field is a replace-if-changed write: the
// candidate is built, compared with what the store holds, and written only
// when it moved. The store's identity contract, a line or a keystroke must
// not rebuild the shell, holds only if the session side keeps it too, and
// `apps/rooms/test/attached/shared_state_identity_test.ts` is where that is
// checked.

import * as store from "../store.ts";
import type { RoomsPageContext } from "../page.ts";
import type { Conv, DirView, Invitation } from "../types.ts";
import { conversationCarries, dirId, isSessionConv } from "../types.ts";
import type { ArchiveShareView } from "../archive_model.ts";
import type { RoomsSessionIssue, RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import type { SelectionRepair } from "./topology.ts";
import { reconcileDraftPreviews } from "../link_preview.ts";
import { authorityToken } from "../store/rooms.ts";

/** What the snapshot carries besides the checkpoint, already sorted by the
 * caller into what the store draws. */
export interface SharedStateInput {
	readonly session: RoomsSessionState;
	readonly keyOf: (conversationId: string) => string | undefined;
	readonly pendingDraft: (conversationId: string) => string | undefined;
	readonly sessionEffects: RoomsSessionSnapshot["pendingEffectDetails"];
	readonly sessionAccess: RoomsSessionSnapshot["access"];
	readonly suspendedNote: string;
	readonly sessionGrants: RoomsSessionSnapshot["grants"];
	readonly issues: ReadonlyMap<string, RoomsSessionIssue>;
	readonly archiveShares: RoomsSessionSnapshot["archiveShares"];
	readonly handedRooms: RoomsSessionSnapshot["handedRooms"];
	readonly selectionRepair: SelectionRepair;
	/** Whether the session's own selection moved since the last snapshot. */
	readonly selectionChanged: boolean;
}

/** The archive shares that arrived as offers this time, for the caller to
 * announce in their conversations. */
export function projectSharedState(page: RoomsPageContext, input: SharedStateInput): readonly ArchiveShareView[] {
	const projection = page.projection;
	const current = projection.get();
	const { session, keyOf, issues } = input;
	const patch: Partial<store.State> = {};

	let dirs: Map<store.State["dirs"] extends ReadonlyMap<infer K, unknown> ? K : never, DirView> | null = null;
	for (const intended of session.directories) {
		const key = dirId(intended.id);
		const directory = current.dirs.get(key);
		if (directory != null && directory.standing !== intended.standing) {
			dirs ??= new Map(current.dirs);
			dirs.set(key, { ...directory, standing: intended.standing });
		}
	}
	if (dirs !== null) patch.dirs = dirs;

	// Drafts are written only for the conversations the session names. A row
	// keyed by a directory view is this tab's own, has no checkpoint behind it,
	// and stays exactly as the reader left it.
	let drafts: Map<string, store.Draft> | null = null;
	let convs: Map<string, Conv> | null = null;
	for (const intended of session.conversations) {
		const key = keyOf(intended.id);
		if (key == null) continue;
		const conversation = current.convs.get(key);
		if (conversation == null) continue;
		const localDraft = current.drafts.get(key);
		const text = localDraft?.changing != null ? localDraft.text : input.pendingDraft(intended.id) ?? intended.draft;
		const nextDraft = text === "" && localDraft == null ? undefined : localDraft?.text === text ? localDraft : {
			...(localDraft ?? { files: [] }),
			text,
			previews: conversationCarries(conversation, "previews")
				? reconcileDraftPreviews(localDraft?.previews ?? [], text, () => projection.allocItemId())
				: [],
		};
		if (nextDraft !== localDraft) {
			drafts ??= new Map(current.drafts);
			if (nextDraft === undefined) drafts.delete(key);
			else drafts.set(key, nextDraft);
		}
		const next = nextConversation(conversation, intended, issues);
		if (next !== conversation) {
			convs ??= new Map(current.convs);
			convs.set(key, next);
		}
	}
	if (drafts !== null) patch.drafts = drafts;
	if (convs !== null) patch.convs = convs;

	const invites: Invitation[] = [
		...session.invitations.map((invitation) => ({
			id: invitation.id,
			dir: dirId(invitation.directory),
			locator: invitation.locator,
			nick: invitation.nick,
			way: "link" as const,
			label: invitation.label,
			from: invitation.from,
			link: invitation.link,
		})),
		...input.handedRooms.map((invitation) => ({
			id: invitation.id,
			dir: dirId(invitation.directory),
			way: "handed" as const,
			label: invitation.label,
			from: invitation.from,
			link: "",
		})),
	];
	if (!sameRows(current.invites, invites, sameInvitation)) patch.invites = invites;

	const directoryView = current.activeKey == null ? null : current.convs.get(current.activeKey);
	const sessionActiveKey = session.active == null ? null : keyOf(session.active) ?? null;
	const activeKey = directoryView != null && !isSessionConv(directoryView)
		? current.activeKey
		: input.selectionChanged
		? sessionActiveKey
		: input.selectionRepair.kind === "replaced"
		? input.selectionRepair.key
		: current.activeKey;
	if (activeKey !== current.activeKey) patch.activeKey = activeKey;

	if (session.standing !== current.standing) patch.standing = session.standing;
	if (!sameSet(current.ignored, session.ignored)) patch.ignored = new Set(session.ignored);
	if (session.keepHistory !== current.keepHistory) patch.keepHistory = session.keepHistory;
	if (
		session.join.room !== current.remembered.room || session.join.locator !== current.remembered.locator ||
		session.join.nick !== current.remembered.nick
	) patch.remembered = { ...session.join };
	patch.sessionEffects = input.sessionEffects;
	patch.sessionAccess = input.sessionAccess;
	if (input.suspendedNote !== current.sessionSuspendedNote) patch.sessionSuspendedNote = input.suspendedNote;
	patch.sessionGrants = input.sessionGrants;

	const archiveShares = input.archiveShares.flatMap((share) => {
		const conversationKey = keyOf(share.conversationId);
		return conversationKey == null ? [] : [{
			id: share.id,
			conversationKey,
			from: share.from,
			status: share.status,
			error: share.error,
			kind: share.kind,
			scopeConversation: share.scopeConversation,
			custody: share.custody,
			copyable: share.custody === "durable" && share.sturdyref !== "",
		}];
	});
	if (!sameRows(current.archiveShares, archiveShares, sameShare)) patch.archiveShares = archiveShares;

	projection.set(patch);

	const previousShares = new Set(current.archiveShares.map((share) => share.id));
	return archiveShares.filter((share) => !previousShares.has(share.id) && share.status === "offered");
}

/** The conversation row a checkpoint conversation calls for, or the row
 * itself when nothing the checkpoint owns has moved. */
function nextConversation(
	conversation: Conv,
	intended: RoomsSessionState["conversations"][number],
	issues: ReadonlyMap<string, RoomsSessionIssue>,
): Conv {
	if (conversation.type === "room" && intended.kind === "room") {
		const linkToken = intended.link == null ? undefined : authorityToken(intended.link);
		const managerToken = intended.manager == null ? undefined : authorityToken(intended.manager);
		const stewardToken = intended.steward == null ? undefined : authorityToken(intended.steward);
		const bridgeIssue = issues.get(`room-bridge:${intended.directory}:${intended.id}`)?.reason ?? "";
		const bridgeIntent = Object.hasOwn(intended, "bridgeIntent") ? intended.bridgeIntent : undefined;
		if (
			conversation.standing === intended.standing && conversation.bridgeIssue === bridgeIssue &&
			conversation.reconnect === (intended.reconnect ?? undefined) &&
			conversation.linkToken === linkToken && conversation.managerToken === managerToken &&
			conversation.stewardToken === stewardToken &&
			JSON.stringify(conversation.bridgeIntent) === JSON.stringify(bridgeIntent)
		) return conversation;
		const {
			bridgeIntent: _bridgeIntent,
			linkToken: _link,
			managerToken: _manager,
			reconnect: _reconnect,
			stewardToken: _steward,
			...withoutIntent
		} = conversation;
		return {
			...withoutIntent,
			standing: intended.standing,
			bridgeIssue,
			...(intended.reconnect == null ? {} : { reconnect: intended.reconnect }),
			...(linkToken == null ? {} : { linkToken }),
			...(managerToken == null ? {} : { managerToken }),
			...(stewardToken == null ? {} : { stewardToken }),
			...(Object.hasOwn(intended, "bridgeIntent") ? { bridgeIntent: intended.bridgeIntent } : {}),
		};
	}
	if (conversation.type === "dm" && intended.kind === "direct") {
		const directIssue = issues.has(`direct:${intended.directory}:${intended.id}`) ||
			issues.has(`direct-retired:${intended.id}`);
		const line = intended.closed ? "closed" : directIssue ? "introducing" : conversation.line;
		return line === conversation.line ? conversation : { ...conversation, line };
	}
	return conversation;
}

function sameSet(left: ReadonlySet<string>, right: readonly string[]): boolean {
	if (left.size !== right.length) return false;
	for (const value of right) if (!left.has(value)) return false;
	return true;
}

function sameRows<T>(left: readonly T[], right: readonly T[], same: (a: T, b: T) => boolean): boolean {
	return left.length === right.length && left.every((row, index) => same(row, right[index]));
}

function sameInvitation(a: Invitation, b: Invitation): boolean {
	return a.id === b.id && a.dir === b.dir && a.locator === b.locator && a.nick === b.nick && a.way === b.way &&
		a.label === b.label && a.from === b.from && a.link === b.link;
}

function sameShare(a: ArchiveShareView, b: ArchiveShareView): boolean {
	return a.id === b.id && a.conversationKey === b.conversationKey && a.from === b.from && a.status === b.status &&
		a.error === b.error && a.kind === b.kind && a.scopeConversation === b.scopeConversation &&
		a.custody === b.custody && a.copyable === b.copyable;
}
