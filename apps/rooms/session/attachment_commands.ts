// Attached-view file mutation admission for one durable Rooms session.

import { type Argument, type Behavior, type Session } from "@pancake/runtime";
import { type Attachment, readAttachmentsExact } from "../lib/attachment.ts";
import {
	mayInteract,
	ROOMS_SESSION_FILES,
	ROOMS_SESSION_REFILE,
	type RoomsSessionAccess,
} from "../lib/session/client.ts";
import type { DurableRoomsRuntime } from "./runtime.ts";
import type { DurableRoomsSessionState } from "./state.ts";
import { validateOperationId } from "./effects.ts";
import { materializeAttachmentSources, type MaterializedAttachmentSource } from "./file_mutation.ts";
import { prepareConversationEffect } from "./conversation_admission.ts";
import { refuseCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";

export const ATTACHMENT_COMMAND_UNHANDLED = Symbol("attachment command not handled");

interface AttachmentCommandOwner {
	state: DurableRoomsSessionState;
	runtime: DurableRoomsRuntime;
}

function fileDescriptor(source: MaterializedAttachmentSource) {
	return {
		name: source.name,
		mime: source.mime,
		size: source.bytes.length,
		width: source.width ?? 0,
		height: source.height ?? 0,
		digest: source.digest,
	};
}

function unresolved(action: string, error: unknown): Error {
	return new Error(
		`the ${action} outcome is unresolved; the operation will not be retried automatically: ${
			error instanceof Error ? error.message : error
		}`,
	);
}

export function dispatchAttachmentCommand(
	rights: RoomsSessionAccess,
	verb: string,
	args: Argument[],
	session: Session,
	owner: AttachmentCommandOwner,
): ReturnType<Behavior> | typeof ATTACHMENT_COMMAND_UNHANDLED {
	if (verb !== ROOMS_SESSION_FILES && verb !== ROOMS_SESSION_REFILE) return ATTACHMENT_COMMAND_UNHANDLED;
	if (!mayInteract(rights)) {
		refuseCapabilityArguments(session, args, "this Rooms session facet cannot change files");
	}
	if (verb === ROOMS_SESSION_FILES) return sendFiles(args, session, owner);
	return refileLine(args, session, owner);
}

function sendFiles(
	args: Argument[],
	session: Session,
	owner: AttachmentCommandOwner,
): ReturnType<Behavior> {
	if (
		args.length < 4 || typeof args[0] !== "string" || typeof args[1] !== "bigint" || args[1] < 0n ||
		args[1] > BigInt(Number.MAX_SAFE_INTEGER) || typeof args[2] !== "string" || typeof args[3] !== "string"
	) {
		refuseCapabilityArguments(
			session,
			args,
			"sendFiles takes an operation id, base revision, conversation, caption, and file records",
		);
	}
	try {
		validateOperationId(args[0]);
	} catch (error) {
		throwAfterReleasingCapabilities(session, args, error);
	}
	let attachments: Attachment[];
	try {
		attachments = readAttachmentsExact(args, 4);
	} catch (error) {
		throwAfterReleasingCapabilities(session, args, error);
	}
	if (attachments.length === 0) throw new Error("sendFiles takes at least one valid file record");
	const operationId = args[0];
	const baseRevision = Number(args[1]);
	const conversationId = args[2];
	const caption = args[3];
	return (async () => {
		// Custody crosses before the attached view may disconnect. The operation
		// identity binds the exact bytes, not only their user-visible metadata.
		const files = await materializeAttachmentSources(session, attachments);
		const operationMaterial = JSON.stringify([
			"sendFiles",
			conversationId,
			caption,
			...files.map(fileDescriptor),
		]);
		const conversation = owner.state.snapshot().checkpoint.conversations.find((entry) =>
			entry.id === conversationId
		);
		if (conversation == null) throw new Error("that conversation is no longer part of this Rooms session");
		const admission = await prepareConversationEffect(
			owner.state,
			owner.runtime,
			operationId,
			baseRevision,
			operationMaterial,
			conversation.kind,
			conversationId,
		);
		if (admission.kind === "committed") return BigInt(admission.revision);
		try {
			await owner.runtime.sendFiles(conversationId, caption, files);
		} catch (error) {
			throw unresolved("file-send", error);
		}
		return BigInt(await owner.state.commitEffect(operationId, operationMaterial));
	})() as ReturnType<Behavior>;
}

function refileLine(
	args: Argument[],
	session: Session,
	owner: AttachmentCommandOwner,
): ReturnType<Behavior> {
	if (
		args.length < 5 || typeof args[0] !== "string" || typeof args[1] !== "bigint" || args[1] < 0n ||
		args[1] > BigInt(Number.MAX_SAFE_INTEGER) || typeof args[2] !== "string" || typeof args[3] !== "bigint" ||
		args[3] <= 0n || args[3] > BigInt(Number.MAX_SAFE_INTEGER) || typeof args[4] !== "string"
	) {
		refuseCapabilityArguments(
			session,
			args,
			"refileLine takes an operation id, revision, conversation, line, caption, and files",
		);
	}
	try {
		validateOperationId(args[0]);
	} catch (error) {
		throwAfterReleasingCapabilities(session, args, error);
	}
	const operationId = args[0];
	const baseRevision = Number(args[1]);
	const conversationId = args[2];
	const lineId = Number(args[3]);
	const caption = args[4];
	const keep: number[] = [];
	const seen = new Set<number>();
	let at = 5;
	while (at < args.length && typeof args[at] === "bigint") {
		const index = Number(args[at]);
		if (!Number.isSafeInteger(index) || index < 0 || seen.has(index)) {
			refuseCapabilityArguments(session, args, "refileLine has invalid kept indices");
		}
		seen.add(index);
		keep.push(index);
		at += 1;
	}
	let attachments: Attachment[];
	try {
		attachments = readAttachmentsExact(args, at);
	} catch (error) {
		throwAfterReleasingCapabilities(session, args, error);
	}
	return (async () => {
		const sources = await materializeAttachmentSources(session, attachments);
		const operationMaterial = JSON.stringify([
			"refileLine",
			conversationId,
			lineId,
			caption,
			keep,
			sources.map(fileDescriptor),
		]);
		const conversation = owner.state.snapshot().checkpoint.conversations.find((entry) =>
			entry.id === conversationId
		);
		if (conversation == null) throw new Error("that conversation is no longer part of this Rooms session");
		const admission = await prepareConversationEffect(
			owner.state,
			owner.runtime,
			operationId,
			baseRevision,
			operationMaterial,
			conversation.kind,
			conversationId,
		);
		if (admission.kind === "committed") return BigInt(admission.revision);
		try {
			await owner.runtime.refileLine(conversationId, lineId, caption, keep, sources);
		} catch (error) {
			throw unresolved("file-refile", error);
		}
		return BigInt(await owner.state.commitEffect(operationId, operationMaterial));
	})() as ReturnType<Behavior>;
}
