// Exhaustive admission policies at the shared command boundary. Equal text is
// never an identity for a new post. Mutation conflicts name the exact target.
import { SESSION_COMMAND_REQUIREMENTS } from "../../../../lib/session_content_data.ts";

export type CommandName = keyof typeof SESSION_COMMAND_REQUIREMENTS;
export interface GesturePolicy {
	presentation: "optimistic" | "indicate";
	conflict:
		| "workspace"
		| "directory"
		| "conversation"
		| "line"
		| "distinct"
		| "setting"
		| "peer"
		| "newRoom"
		| "archive"
		| "operator";
	retry: "originalReceipt";
	stop: "observe";
	stale: "originalSelection";
	failure: "initiator";
	limit: "effects";
}
const indicate = (conflict: GesturePolicy["conflict"]): GesturePolicy => ({
	presentation: "indicate",
	conflict,
	retry: "originalReceipt",
	stop: "observe",
	stale: "originalSelection",
	failure: "initiator",
	limit: "effects",
});
const optimistic = (conflict: GesturePolicy["conflict"]): GesturePolicy => ({
	...indicate(conflict),
	presentation: "optimistic",
});

export const GESTURES = {
	clearWorkspace: indicate("workspace"),
	setDraft: optimistic("distinct"),
	select: optimistic("distinct"),
	acceptInvitation: indicate("conversation"),
	dismissInvitation: indicate("conversation"),
	receiveRoomLinkInvitation: indicate("conversation"),
	setStanding: optimistic("setting"),
	joinDirectory: indicate("directory"),
	leaveDirectory: indicate("directory"),
	setDirectoryNick: indicate("directory"),
	chooseDirectoryNickname: indicate("directory"),
	joinRoom: indicate("conversation"),
	startDirect: indicate("peer"),
	openDirect: indicate("conversation"),
	publishPeeredRoom: indicate("conversation"),
	revokePeeredRoom: indicate("conversation"),
	replaceOperationsCapabilities: indicate("workspace"),
	replaceOperationsBundle: indicate("workspace"),
	leaveConversation: indicate("conversation"),
	closeDirect: indicate("conversation"),
	setDirectoryStanding: optimistic("directory"),
	setRoomStanding: optimistic("conversation"),
	setEffectiveStanding: optimistic("conversation"),
	dropRoomModerator: indicate("conversation"),
	dropRoomManager: indicate("conversation"),
	submitRoomBridgeForm: indicate("conversation"),
	setIgnoredNames: optimistic("setting"),
	setIgnoredName: indicate("setting"),
	chooseHistoryRetention: indicate("setting"),
	chooseConnection: indicate("setting"),
	selectArchive: indicate("setting"),
	takeRoomLink: indicate("conversation"),
	ensureRoomLink: indicate("conversation"),
	linkRoom: indicate("conversation"),
	takeRoomModerator: indicate("conversation"),
	takeRoomManager: indicate("conversation"),
	recoverRoomManager: indicate("conversation"),
	openManagedRoom: indicate("newRoom"),
	enterRoom: indicate("conversation"),
	offerRoom: indicate("conversation"),
	shareArchiveHistory: indicate("conversation"),
	offerDurableArchive: indicate("conversation"),
	revokeIssuedArchiveShare: indicate("archive"),
	setRoomTopic: indicate("conversation"),
	setRoomAway: indicate("conversation"),
	retireRoomMembership: indicate("conversation"),
	kickRoomMember: indicate("conversation"),
	issueRoomModerator: indicate("conversation"),
	say: optimistic("distinct"),
	directReady: indicate("conversation"),
	offerDirectInbox: indicate("conversation"),
	editLine: optimistic("line"),
	withdrawLine: optimistic("line"),
	operator: indicate("operator"),
	revokeManagedRoomAuthority: indicate("conversation"),
	unregisterManagedRoom: indicate("conversation"),
	setManagedRoomPolicy: indicate("conversation"),
	operations: indicate("distinct"),
} satisfies Record<CommandName, GesturePolicy>;

export function gestureScope(name: string, args: readonly string[]): string | null {
	const policy = GESTURES[name as CommandName];
	if (policy == null || policy.conflict === "distinct") return null;
	if (policy.conflict === "setting") {
		return JSON.stringify(["setting", name === "setIgnoredName" ? "setIgnoredNames" : name]);
	}
	const count = policy.conflict === "workspace" ? 0 : ["line", "peer", "newRoom"].includes(policy.conflict) ? 2 : 1;
	return JSON.stringify([policy.conflict, ...args.slice(0, count)]);
}

/** Parent retirement conflicts with work using its authority. Independent
 * line mutations and rooms otherwise proceed. Selection and draft are local
 * intentions, so the admission fence decides their current row, not a mutex. */
export function gesturesConflict(
	a: { name: string; args: readonly string[]; scope: string | null },
	b: { name: string; args: readonly string[]; scope: string | null },
	directoryOf: (conversation: string) => string | undefined,
): boolean {
	if (a.scope != null && a.scope === b.scope) return true;
	if ([a.name, b.name].includes("clearWorkspace")) return true;
	for (const [retirement, work] of [[a, b], [b, a]]) {
		if (work.name === "select" || work.name === "setDraft") continue;
		if (retirement.name === "leaveConversation" && retirement.args[0] === work.args[0]) return true;
		if (
			retirement.name === "leaveDirectory" &&
			(retirement.args[0] === work.args[0] || retirement.args[0] === directoryOf(work.args[0]))
		) return true;
	}
	return false;
}
