// The persisted request drives first completion and recovery after reload.
// Capability occurrences stay in the receipt until their atomic adoption.
import { invariant } from "../../../../lib/invariant.ts";
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import type { ManagedRoomsSession } from "./session.ts";
import { type ManagedOperation, ResultAcquisitionError } from "./operation.ts";
import { conversationIdentity, type Coordinate, type DirectIntent, isCoordinate, type RoomIntent } from "./model.ts";
import { isRetainedCommandIntent } from "./admission.ts";
import { AcquisitionConflict, MAX_CONFLICT_REPREPARATIONS } from "./acquisition.ts";
import type { ResultRecipe } from "./result_recipe.ts";
import { CompletedLine, isLineResult, type LineAdoption, type LineResult } from "./completed_line.ts";
import { readDirectReceipt } from "./direct_receipt.ts";

/** Persisted receipts can outlive the build that wrote them. */
function retained(condition: unknown, diagnostic: string): asserts condition {
	if (!condition) throw new LocalRefusal("retained-result-unreadable", { cause: diagnostic });
}
function hasField<K extends string>(value: object, key: K): value is Record<K, unknown> {
	return key in value;
}
function hasStringFields<T extends string>(value: unknown, fields: readonly T[]): value is Record<T, string> {
	return value != null && typeof value === "object" && !Array.isArray(value) &&
		fields.every((field) => hasField(value, field) && typeof value[field] === "string");
}
function receiptFields<T extends string>(result: unknown, fields: readonly T[]): Record<T, string> {
	retained(hasStringFields(result, fields), "the command receipt has invalid fields");
	return result;
}
function retainedJson(value: string): unknown {
	try {
		return JSON.parse(value);
	} catch (cause) {
		throw new LocalRefusal("retained-result-unreadable", { cause });
	}
}

type Completion = Readonly<
	| { kind: "line"; name: string; args: readonly string[]; result: LineResult | null }
	| { kind: "value"; name: string; args: readonly string[]; result: unknown }
>;

/** Decode the immutable receipt input once. Conflict retries rebuild only the
 * workspace delta. The prepared value borrows command arguments and result.
 * It owns no capabilities and cannot replace the operation's original request. */
function prepareCompletion(original: unknown, result: unknown): Completion {
	let name: string;
	let args: readonly string[];
	if (Array.isArray(original)) {
		retained(isRetainedCommandIntent(original), "the retained command intent is malformed");
		if (!original[3].every((arg): arg is string => typeof arg === "string")) {
			retained(false, "a retained command argument is not a string");
		}
		name = original[2];
		args = original[3];
	} else if (original != null && typeof original === "object" && "upload" in original && original.upload != null) {
		if (!("conversation" in original) || typeof original.conversation !== "string") {
			retained(false, "a retained upload intent has no conversation");
		}
		name = "upload";
		args = [original.conversation];
	} else if (original != null && typeof original === "object" && "bridge" in original && original.bridge != null) {
		name = "bridge";
		args = [];
	} else {
		retained(false, "the retained intent has no completion owner");
	}
	switch (name) {
		case "say":
		case "upload":
		case "sendFiles":
		case "refileLine":
			if (result != null && !isLineResult(result)) {
				retained(false, "the command receipt does not have the line result shape");
			}
			return { kind: "line", name, args, result: result ?? null };
		default:
			return { kind: "value", name, args, result };
	}
}

export function completeResult(session: ManagedRoomsSession, operation: ManagedOperation): Promise<unknown> {
	return operation.complete(async (recipe) => {
		const result = await operation.result();
		let completion: Completion;
		try {
			completion = prepareCompletion(operation.request.originalIntent(), result);
		} catch (error) {
			throw new ResultAcquisitionError(result, error);
		}
		for (let attempt = 0; attempt < MAX_CONFLICT_REPREPARATIONS; attempt++) {
			try {
				return await completeOnce(session, operation, recipe, completion);
			} catch (error) {
				// Conflict installed no result custody. Recompose only the workspace
				// delta, keeping the original receipt, targets and destination keys.
				const canRetry = error instanceof AcquisitionConflict &&
					attempt + 1 < MAX_CONFLICT_REPREPARATIONS;
				if (!canRetry) throw new ResultAcquisitionError(result, error);
			}
		}
		throw new LocalRefusal("conflict");
	});
}

async function completeOnce(
	session: ManagedRoomsSession,
	operation: ManagedOperation,
	recipe: ResultRecipe,
	completion: Completion,
): Promise<unknown> {
	const { name, args, result } = completion;
	const completed = () =>
		completion.kind === "line"
			? new CompletedLine(completion.result, operation.acquired ? recipe.line : undefined)
			: result;
	if (operation.acquired || await operation.request.adopted()) {
		await session.refresh();
		return completed();
	}
	let lineAdoption: LineAdoption | undefined;
	const snapshot = await session.candidate();
	const mappings: { result: Coordinate; destination: Coordinate }[] = [];
	const releases: Coordinate[] = [];
	let source: string | undefined;
	function retain(role: string, key: string): string {
		const destination = recipe.destination(role, key);
		mappings.push({ result: { role, key }, destination: { role, key: destination } });
		return destination;
	}
	function conversation(id: string) {
		return recipe.conversation(snapshot, id);
	}
	function room(id: string): RoomIntent {
		const row = conversation(id);
		if (row.kind !== "room") throw new LocalRefusal("room-gone");
		return row;
	}
	// The retained command name discriminates its receipt. Each case proves
	// the exact fields that command's Rust result returns before reading them.
	switch (name) {
		case "openManagedRoom": {
			const receipt = receiptFields(result, ["room", "control"]);
			recipe.directory(snapshot, args[0]);
			source = recipe.source();
			snapshot.intent.conversations.push({
				kind: "room",
				id: operation.id,
				directory: args[0],
				name: args[1],
				source,
				access: retain("roomAccess", receipt.room),
				control: retain("roomControl", receipt.control),
				reconnect: "requested",
				standing: null,
				draft: "",
			});
			break;
		}
		case "startDirect": {
			// The receipt owns one exact inbox.
			const receipt = readDirectReceipt(result);
			const directory = recipe.directory(snapshot, args[0]);
			if (directory.name == null || directory.inbox == null) {
				throw new LocalRefusal("target-gone-held");
			}
			const introduction = {
				access: directory.access,
				name: directory.name,
				callback: directory.inbox,
				registration: args[2],
				opening: args[3],
			};
			recipe.check(`introduction:${operation.id}`, introduction);
			source = recipe.source();
			const previous = snapshot.intent.conversations.findLast((row): row is DirectIntent =>
				row.kind === "direct" && row.closed && row.directory === args[0] &&
				row.introduction?.registration === args[2]
			);
			recipe.check(
				`direct-reopening:${operation.id}`,
				previous == null ? null : [
					previous.id,
					previous.source,
					previous.access,
					previous.introduction,
				],
			);
			const next = {
				kind: "direct",
				id: previous?.id ?? operation.id,
				directory: args[0],
				peer: args[1],
				source,
				access: retain("directAccess", receipt.inbox),
				introduction,
				closed: false,
				draft: previous?.draft ?? "",
			} as const;
			if (previous == null) snapshot.intent.conversations.push(next);
			else snapshot.intent.conversations[snapshot.intent.conversations.indexOf(previous)] = next;
			break;
		}
		case "say":
		case "upload":
		case "sendFiles":
		case "refileLine": {
			invariant(completion.kind === "line", "the posting completion has no line receipt");
			const receipt = completion.result;
			const row = conversation(args[0]);
			// The composer owns draft admission. Acquiring a line cannot clear a
			// later draft, even when its caption equals the submitted message.
			if (receipt?.line != null && receipt.id != null) {
				const replaced = row.lines?.find((line) => line.id === receipt.id);
				recipe.check(`line:${row.id}:${receipt.id}`, replaced?.handle ?? null);
				// Direct settlement already installed sender provenance at this field.
				// Atomic acquisition verifies the existing occurrence equals the reply.
				const preserved = row.kind === "direct" ? replaced?.handle : undefined;
				if (preserved != null) {
					mappings.push({
						result: { role: "line", key: receipt.line },
						destination: { role: "line", key: preserved },
					});
				}
				row.lines = [...(row.lines ?? []).filter((line) => line.id !== receipt.id), {
					id: receipt.id,
					handle: preserved ?? retain("line", receipt.line),
				}];
				lineAdoption = {
					conversation: row.id,
					identity: conversationIdentity(row),
					inbox: row.inbox,
					handle: row.lines[row.lines.length - 1].handle,
				};
				if (replaced != null && preserved == null) releases.push({ role: "line", key: replaced.handle });
			}
			break;
		}
		case "acceptInvitation": {
			const receipt = receiptFields(result, ["entrance"]);
			const invitation = snapshot.intent.invitations.find((row) => row.id === args[0]);
			if (invitation == null) throw new LocalRefusal("target-gone-held");
			recipe.check(`invitation:${invitation.id}`, [
				invitation.directory,
				invitation.authority,
				invitation.source,
			]);
			source = recipe.source();
			snapshot.intent.conversations.push({
				kind: "room",
				id: operation.id,
				directory: invitation.directory,
				name: invitation.label,
				access: null,
				accepted: retain("acceptedAccess", receipt.entrance),
				source,
				control: null,
				reconnect: "requested",
				standing: null,
				draft: "",
			});
			snapshot.intent.invitations = snapshot.intent.invitations.filter((row) => row.id !== invitation.id);
			snapshot.intent.active = operation.id;
			releases.push(invitation.authority);
			break;
		}
		case "issueRoomModerator": {
			const receipt = receiptFields(result, ["moderator"]);
			const row = room(args[0]);
			row.moderator = retain("roomAccess", receipt.moderator);
			break;
		}
		case "ensureRoomLink": {
			const receipt = receiptFields(result, ["room"]);
			const row = room(args[0]);
			row.access = retain("roomAccess", receipt.room);
			delete row.accepted;
			delete row.publicEntry;
			break;
		}
		case "publishPeeredRoom": {
			const receipt = receiptFields(result, ["lease"]);
			const access: unknown = retainedJson(args[2]);
			retained(typeof access === "string", "the retained publication authority is not a key");
			if (
				!snapshot.intent.conversations.some((row) =>
					row.kind === "room" && row.directory === args[0] && row.access === access
				)
			) {
				throw new LocalRefusal("room-access-changed");
			}
			snapshot.intent.peering.push({
				id: operation.id,
				directory: args[0],
				name: args[1],
				room: access,
				lease: retain("publicationLease", receipt.lease),
			});
			break;
		}
		case "operator": {
			if (args[1] === "giveManager") {
				const receipt = receiptFields(result, ["control"]);
				const matches: RoomIntent[] = [];
				const unanswered: unknown[] = [];
				for (const row of snapshot.intent.conversations) {
					if (row.kind !== "room" || row.seat == null) continue;
					// A seat the room has since retired answers nothing, and the
					// room it stood in is not the one the operator named here. Its
					// failure is kept so that no match reports why, rather than
					// reading a lost route as a missing room.
					try {
						const identity = await session.workspace.roomManagementIdentity(
							JSON.stringify({ role: "roomSeat", key: row.seat }),
						);
						if (identity === args[2]) matches.push(row);
					} catch (error) {
						unanswered.push(error);
					}
				}
				if (matches.length === 0 && unanswered.length > 0) throw unanswered[0];
				if (matches.length === 0) throw new LocalRefusal("target-gone-held");
				if (matches.length > 1) throw new LocalRefusal("room-saved-twice");
				conversation(matches[0].id);
				matches[0].control = retain("roomControl", receipt.control);
			} else return result;
			break;
		}
		case "operations": {
			if (args[1] !== "ircGateway" || args[2] !== "connection") return result;
			const receipt = receiptFields(result, ["connection"]);
			const gateway: unknown = retainedJson(args[0]);
			retained(isCoordinate(gateway), "the retained gateway selection is not a coordinate");
			if (
				!snapshot.intent.operations?.some((row) =>
					row.kind === "ircGateway" && row.handle.role === gateway.role && row.handle.key === gateway.key
				)
			) throw new LocalRefusal("gateway-changed");
			snapshot.intent.operations = [...(snapshot.intent.operations ?? []), {
				kind: "ircConnection",
				handle: { role: "ircConnection", key: retain("ircConnection", receipt.connection) },
				connection: { operation: operation.id, gateway, id: args[3] },
			}];
			break;
		}
		default:
			return result;
	}
	// Retain the candidate's scalar witness through an uncertain acquisition.
	// It becomes usable only after that exact acquisition is confirmed.
	if (lineAdoption != null) recipe.line = lineAdoption;
	await operation.acquire(snapshot, mappings, releases, source, name === "openManagedRoom");
	await session.refresh();
	return completed();
}
