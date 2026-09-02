// The checkpoint commands, one method each: the sugar half of the session
// client. Every method builds one command's arguments and rides `command`,
// so a command's wire grammar lives beside its name and nowhere else. The
// client's other half — snapshots, watching, reads, and file custody — is
// `RoomsSessionClient`, which extends this.

import type { Ref, Session } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import type { RoomsRoomJoinIntent, RoomsSessionState } from "../rooms_state.ts";
import { sessionRevision } from "./revision.ts";
import { ROOMS_SESSION_COMMAND } from "./verbs.ts";

export class RoomsSessionCommandClient {
	protected readonly session: Session;
	protected readonly capability: Ref;

	constructor(session: Session, capability: Ref) {
		this.session = session;
		this.capability = capability;
	}

	command(operationId: string, baseRevision: number, name: string, args: string[]): Promise<number> {
		return ask(
			this.session,
			this.capability,
			ROOMS_SESSION_COMMAND,
			[operationId, BigInt(baseRevision), name, ...args],
			"the Rooms session did not apply the command",
		).then((raw) => sessionRevision(raw, "command"));
	}

	setDraft(operationId: string, baseRevision: number, conversationId: string, text: string): Promise<number> {
		return this.command(operationId, baseRevision, "setDraft", [conversationId, text]);
	}

	select(operationId: string, baseRevision: number, conversationId: string | null): Promise<number> {
		return this.command(operationId, baseRevision, "select", conversationId == null ? [] : [conversationId]);
	}

	setStanding(operationId: string, baseRevision: number, standing: string): Promise<number> {
		return this.command(operationId, baseRevision, "setStanding", [standing]);
	}

	joinDirectory(
		operationId: string,
		baseRevision: number,
		directory: RoomsSessionState["directories"][number],
	): Promise<number> {
		return this.command(operationId, baseRevision, "joinDirectory", [JSON.stringify(directory)]);
	}

	leaveDirectory(operationId: string, baseRevision: number, directoryId: string): Promise<number> {
		return this.command(operationId, baseRevision, "leaveDirectory", [directoryId]);
	}

	joinRoom(
		operationId: string,
		baseRevision: number,
		intent: RoomsRoomJoinIntent,
	): Promise<number> {
		return this.command(operationId, baseRevision, "joinRoom", [JSON.stringify(intent)]);
	}

	openManagedRoom(
		operationId: string,
		baseRevision: number,
		conversation: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>,
		recoveryKey: string,
		policy: import("../room/policy.ts").RoomPolicy,
	): Promise<number> {
		return this.command(operationId, baseRevision, "openManagedRoom", [
			JSON.stringify(conversation),
			recoveryKey,
			policy.visibility,
			policy.entry,
			policy.speaking,
		]);
	}

	startDirect(
		operationId: string,
		baseRevision: number,
		conversation: Extract<RoomsSessionState["conversations"][number], { kind: "direct" }>,
	): Promise<number> {
		return this.command(operationId, baseRevision, "startDirect", [JSON.stringify(conversation)]);
	}

	leaveConversation(operationId: string, baseRevision: number, conversationId: string): Promise<number> {
		return this.command(operationId, baseRevision, "leaveConversation", [conversationId]);
	}

	closeDirect(operationId: string, baseRevision: number, conversationId: string): Promise<number> {
		return this.command(operationId, baseRevision, "closeDirect", [conversationId]);
	}

	setDirectoryStanding(
		operationId: string,
		baseRevision: number,
		directoryId: string,
		standing: string | null,
	): Promise<number> {
		return this.command(
			operationId,
			baseRevision,
			"setDirectoryStanding",
			standing == null ? [directoryId] : [directoryId, standing],
		);
	}

	setRoomStanding(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		standing: string | null,
	): Promise<number> {
		return this.command(
			operationId,
			baseRevision,
			"setRoomStanding",
			standing == null ? [conversationId] : [conversationId, standing],
		);
	}

	setIgnoredNames(operationId: string, baseRevision: number, names: readonly string[]): Promise<number> {
		return this.command(operationId, baseRevision, "setIgnoredNames", [JSON.stringify(names)]);
	}

	chooseHistoryRetention(operationId: string, baseRevision: number, keep: boolean): Promise<number> {
		return this.command(operationId, baseRevision, "chooseHistoryRetention", [String(keep)]);
	}

	chooseConnection(
		operationId: string,
		baseRevision: number,
		dmMode: RoomsSessionState["dmMode"],
		vizOverride: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "chooseConnection", [dmMode, vizOverride]);
	}

	replaceOperationsCapabilities(
		operationId: string,
		baseRevision: number,
		credentials: RoomsSessionState["capabilities"]["operations"],
	): Promise<number> {
		return this.command(operationId, baseRevision, "replaceOperationsCapabilities", [JSON.stringify(credentials)]);
	}

	selectArchive(operationId: string, baseRevision: number, sturdyref: string | null): Promise<number> {
		return this.command(operationId, baseRevision, "selectArchive", sturdyref == null ? [] : [sturdyref]);
	}

	acceptInvitation(
		operationId: string,
		baseRevision: number,
		invitationId: string,
		conversationId: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "acceptInvitation", [invitationId, conversationId]);
	}

	dismissInvitation(operationId: string, baseRevision: number, invitationId: string): Promise<number> {
		return this.command(operationId, baseRevision, "dismissInvitation", [invitationId]);
	}

	setRoomTopic(operationId: string, baseRevision: number, conversationId: string, text: string): Promise<number> {
		return this.command(operationId, baseRevision, "setRoomTopic", [conversationId, text]);
	}

	kickRoomMember(operationId: string, baseRevision: number, conversationId: string, nick: string): Promise<number> {
		return this.command(operationId, baseRevision, "kickRoomMember", [conversationId, nick]);
	}

	submitRoomBridgeForm(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		scope: string,
		action: string,
		answers: Record<string, string>,
		secrets: Record<string, string>,
	): Promise<number> {
		return this.command(operationId, baseRevision, "submitRoomBridgeForm", [
			conversationId,
			scope,
			action,
			JSON.stringify(answers),
			JSON.stringify(secrets),
		]);
	}

	ensureRoomLink(operationId: string, baseRevision: number, conversationId: string): Promise<number> {
		return this.command(operationId, baseRevision, "ensureRoomLink", [conversationId]);
	}

	takeRoomModerator(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		stewardLink?: string,
	): Promise<number> {
		return this.command(
			operationId,
			baseRevision,
			"takeRoomModerator",
			stewardLink == null ? [conversationId] : [conversationId, stewardLink],
		);
	}

	offerRoom(
		operationId: string,
		baseRevision: number,
		roomConversationId: string,
		directConversationId: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "offerRoom", [roomConversationId, directConversationId]);
	}

	say(operationId: string, baseRevision: number, conversationId: string, text: string): Promise<number> {
		return this.command(operationId, baseRevision, "say", [conversationId, text]);
	}

	editLine(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		lineId: number,
		text: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "editLine", [conversationId, String(lineId), text]);
	}

	withdrawLine(operationId: string, baseRevision: number, conversationId: string, lineId: number): Promise<number> {
		return this.command(operationId, baseRevision, "withdrawLine", [conversationId, String(lineId)]);
	}

	operator(
		operationId: string,
		baseRevision: number,
		scope: string,
		action: string,
		args: string[] = [],
	): Promise<number> {
		return this.command(operationId, baseRevision, "operator", [scope, action, ...args]);
	}
}
