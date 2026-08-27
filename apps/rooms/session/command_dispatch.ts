// Admission and execution of commands issued through a durable Rooms session.

import { type Argument, type Behavior, type Session } from "@pancake/runtime";
import { type RoomsSessionFacet } from "../lib/rooms_session.ts";
import { lineCost, MAX_LINE, MAX_TOPIC, nickRefusal } from "../lib/limits.ts";
import { DurableRoomsSessionState } from "./state.ts";
import { DurableRoomsRuntime } from "./runtime.ts";
import { applyRoomsSessionCommand, prepareRoomOffer, roomsSessionCommandImpact } from "./commands.ts";
import { performResultCommand } from "./result_effect.ts";
import { validateOperationId } from "./effects.ts";
import { prepareConversationEffect } from "./conversation_admission.ts";

export const MAX_SESSION_COMMAND_ARGUMENTS = 64;
export const MAX_SESSION_COMMAND_BYTES = 512 * 1024;

function jsonStringByteLength(value: string): number {
	let bytes = 2;
	for (let at = 0; at < value.length; at += 1) {
		const code = value.charCodeAt(at);
		if (code < 0x20) {
			bytes += code === 8 || code === 9 || code === 10 || code === 12 || code === 13 ? 2 : 6;
		} else if (code === 0x22 || code === 0x5c) {
			bytes += 2;
		} else if (code >= 0xd800 && code <= 0xdbff) {
			const next = value.charCodeAt(at + 1);
			if (next >= 0xdc00 && next <= 0xdfff) {
				bytes += 4;
				at += 1;
			} else bytes += 6;
		} else if (code >= 0xdc00 && code <= 0xdfff) {
			bytes += 6;
		} else if (code <= 0x7f) {
			bytes += 1;
		} else if (code <= 0x7ff) {
			bytes += 2;
		} else if (code <= 0xffff) {
			bytes += 3;
		}
	}
	return bytes;
}

/** Check command cardinality and its exact JSON byte budget before the command
 * material is materialized or hashed. */
export function assertSessionCommandEnvelope(args: readonly Argument[]): void {
	if (args.length < 3) {
		throw new Error("session command takes an operation id, base revision, name, and string arguments");
	}
	if (args.length - 3 > MAX_SESSION_COMMAND_ARGUMENTS) {
		throw new Error("session command has too many arguments");
	}
	let bytes = 1;
	for (let at = 2; at < args.length; at += 1) {
		const argument = args[at];
		if (typeof argument !== "string") {
			throw new Error("session command takes an operation id, base revision, name, and string arguments");
		}
		bytes += (at === 2 ? 0 : 1) + jsonStringByteLength(argument);
	}
	bytes += 1;
	if (bytes > MAX_SESSION_COMMAND_BYTES) throw new Error("session command exceeds its byte ceiling");
}

async function performExternalEffect(
	state: DurableRoomsSessionState,
	operationId: string,
	baseRevision: number,
	operationMaterial: string,
	effect: () => Promise<void>,
	label: string,
	preflight?: () => void,
): Promise<number> {
	const admission = await state.prepareEffect(operationId, baseRevision, operationMaterial, preflight);
	if (admission.kind === "committed") return admission.revision;
	try {
		await effect();
	} catch (error) {
		throw new Error(
			`the ${label} outcome is unresolved; the operation will not be retried automatically: ${
				error instanceof Error ? error.message : error
			}`,
		);
	}
	return await state.commitEffect(operationId, operationMaterial);
}

export interface RoomsSessionCommandContext {
	readonly state: DurableRoomsSessionState;
	readonly runtime: DurableRoomsRuntime;
	readonly session: Session;
}

function requiresAdministration(command: string): boolean {
	return command === "replaceOperationsCapabilities" || command === "selectArchive";
}

/** Admit one command and dispatch it to either the durable reducer or the
 * runtime effect ledger. All command arms live here so the behavior module
 * remains responsible for CapTP facets and observation only. */
export function dispatchRoomsSessionCommand(
	rights: RoomsSessionFacet,
	args: Argument[],
	context: RoomsSessionCommandContext,
): ReturnType<Behavior> {
	if (rights === "observe") throw new Error("this Rooms session facet cannot issue commands");
	if (
		args.length < 3 || typeof args[0] !== "string" || typeof args[1] !== "bigint" || args[1] < 0n ||
		args[1] > BigInt(Number.MAX_SAFE_INTEGER) || typeof args[2] !== "string"
	) throw new Error("session command takes an operation id, base revision, name, and string arguments");
	validateOperationId(args[0]);
	assertSessionCommandEnvelope(args);
	const operationId = args[0];
	const baseRevision = Number(args[1]);
	const command = args[2];
	if (rights !== "admin" && requiresAdministration(command)) {
		throw new Error("this Rooms session facet cannot administer retained capabilities");
	}
	const commandArgs = args.slice(3) as string[];
	if (commandArgs.some((argument) => argument.length > 64 * 1024)) {
		throw new Error("session command contains an oversized argument");
	}
	const operationMaterial = JSON.stringify([command, ...commandArgs]);
	if (command === "offerRoom") {
		const offer = prepareRoomOffer(context.state.snapshot().checkpoint, commandArgs);
		return performExternalEffect(
			context.state,
			operationId,
			baseRevision,
			operationMaterial,
			() =>
				context.runtime.offerRoom(
					offer.roomConversationId,
					offer.directConversationId,
					offer.label,
					offer.link,
				),
			"room invitation",
		).then(BigInt) as ReturnType<Behavior>;
	}
	if (command === "openPrivateRoom" || command === "ensureRoomLink" || command === "takeRoomModerator") {
		return performResultCommand(
			context.state,
			context.runtime,
			operationId,
			baseRevision,
			command,
			commandArgs,
			operationMaterial,
		).then(BigInt) as ReturnType<Behavior>;
	}
	if (command === "setRoomTopic" || command === "kickRoomMember") {
		if (commandArgs.length !== 2) throw new Error(`${command} has invalid arguments`);
		if (command === "setRoomTopic" && commandArgs[1].length > MAX_TOPIC) {
			throw new Error(`a room topic may be at most ${MAX_TOPIC} characters`);
		}
		if (command === "kickRoomMember") {
			const refusal = nickRefusal(commandArgs[1]);
			if (refusal != null) throw new Error(refusal);
		}
		const effect = command === "setRoomTopic"
			? () => context.runtime.setRoomTopic(commandArgs[0], commandArgs[1])
			: () => context.runtime.kickRoomMember(commandArgs[0], commandArgs[1]);
		return performExternalEffect(
			context.state,
			operationId,
			baseRevision,
			operationMaterial,
			effect,
			command === "setRoomTopic" ? "room topic" : "room kick",
		).then(BigInt) as ReturnType<Behavior>;
	}
	if (command === "say") {
		if (commandArgs.length !== 2 || lineCost(commandArgs[1]) > MAX_LINE) {
			throw new Error("say takes a conversation id and bounded text");
		}
		const conversationId = commandArgs[0];
		return (async () => {
			const conversation = context.state.snapshot().checkpoint.conversations.find((entry) =>
				entry.id === conversationId
			);
			if (conversation == null) throw new Error("that conversation is no longer part of this Rooms session");
			const conversationKind = conversation.kind;
			const admission = await prepareConversationEffect(
				context.state,
				context.runtime,
				operationId,
				baseRevision,
				operationMaterial,
				conversationKind,
				conversationId,
			);
			if (admission.kind === "committed") return BigInt(admission.revision);
			try {
				await context.runtime.say(conversationKind, conversationId, commandArgs[1]);
			} catch (error) {
				throw new Error(
					`the ${conversationKind === "room" ? "room send" : "direct message send"} outcome is unresolved; ` +
						`the operation will not be retried automatically: ${
							error instanceof Error ? error.message : error
						}`,
				);
			}
			return BigInt(await context.state.commitEffect(operationId, operationMaterial));
		})() as ReturnType<Behavior>;
	}
	if (command === "editLine" || command === "withdrawLine") {
		const expected = command === "editLine" ? 3 : 2;
		const lineId = Number(commandArgs[1]);
		if (
			commandArgs.length !== expected || !Number.isSafeInteger(lineId) || lineId <= 0 ||
			(command === "editLine" && lineCost(commandArgs[2]) > MAX_LINE)
		) {
			throw new Error(
				`${command} takes a conversation id, positive line id${
					command === "editLine" ? ", and bounded text" : ""
				}`,
			);
		}
		return (async () => {
			const admission = await context.state.prepareEffect(operationId, baseRevision, operationMaterial);
			if (admission.kind === "committed") return BigInt(admission.revision);
			try {
				if (command === "editLine") {
					await context.runtime.editLine(commandArgs[0], lineId, commandArgs[2]);
				} else await context.runtime.withdrawLine(commandArgs[0], lineId);
			} catch (error) {
				throw new Error(
					`the line-change outcome is unresolved; the operation will not be retried automatically: ${
						error instanceof Error ? error.message : error
					}`,
				);
			}
			return BigInt(await context.state.commitEffect(operationId, operationMaterial));
		})() as ReturnType<Behavior>;
	}
	if (command === "operator") {
		if (commandArgs.length < 2) throw new Error("operator takes a scope, action, and action arguments");
		const effect = context.runtime.operatorEffect(commandArgs[0], commandArgs[1], commandArgs.slice(2));
		return ledgeredEffect(context, operationId, baseRevision, operationMaterial, effect, "operator");
	}
	if (command === "operations") {
		if (commandArgs.length < 3) {
			throw new Error("operations takes a scope, capability, action, and action arguments");
		}
		const effect = context.runtime.operationsEffect(
			commandArgs[0],
			commandArgs[1],
			commandArgs[2],
			commandArgs.slice(3),
		);
		return ledgeredEffect(context, operationId, baseRevision, operationMaterial, effect, "operations");
	}
	if (command === "replaceOperationsCapabilities") {
		return settledCheckpointMutation(
			context,
			operationId,
			baseRevision,
			operationMaterial,
			command,
			commandArgs,
		) as ReturnType<Behavior>;
	}
	if (command === "selectArchive") {
		if (commandArgs.length > 1) throw new Error("selectArchive takes zero or one sturdyref");
		return (async () => {
			if (commandArgs[0] != null) await context.runtime.prepareArchive(commandArgs[0]);
			return await settledCheckpointMutation(
				context,
				operationId,
				baseRevision,
				operationMaterial,
				command,
				commandArgs,
			);
		})() as ReturnType<Behavior>;
	}
	return context.state.mutate({
		operationId,
		baseRevision,
		material: operationMaterial,
		impact: roomsSessionCommandImpact(command),
		change: (current) => applyRoomsSessionCommand(current, command, commandArgs),
	}).then(BigInt) as ReturnType<Behavior>;
}

async function settledCheckpointMutation(
	context: RoomsSessionCommandContext,
	operationId: string,
	baseRevision: number,
	operationMaterial: string,
	command: string,
	commandArgs: string[],
): Promise<bigint> {
	const revision = await context.state.mutate({
		operationId,
		baseRevision,
		material: operationMaterial,
		impact: roomsSessionCommandImpact(command),
		change: (current) => applyRoomsSessionCommand(current, command, commandArgs),
	});
	await context.runtime.settled();
	return BigInt(revision);
}

function ledgeredEffect(
	context: RoomsSessionCommandContext,
	operationId: string,
	baseRevision: number,
	operationMaterial: string,
	effect: () => Promise<void>,
	label: string,
): ReturnType<Behavior> {
	return (async () => {
		const admission = await context.state.prepareEffect(operationId, baseRevision, operationMaterial);
		if (admission.kind === "committed") return BigInt(admission.revision);
		try {
			await effect();
		} catch (error) {
			throw new Error(
				`the ${label} outcome is unresolved; the operation will not be retried automatically: ${
					error instanceof Error ? error.message : error
				}`,
			);
		}
		return BigInt(await context.state.commitEffect(operationId, operationMaterial));
	})() as ReturnType<Behavior>;
}
