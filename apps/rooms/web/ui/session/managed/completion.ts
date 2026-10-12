// The persisted request drives first completion and recovery after reload.
// Capability occurrences stay in the receipt until their atomic adoption.
import type { ManagedRoomsSession } from "./session.ts";
import { type ManagedOperation, ResultAcquisitionError } from "./operation.ts";
import { conversationIdentity, type Coordinate, type DirectIntent, isCoordinate, type RoomIntent } from "./model.ts";
import { isRetainedCommandIntent } from "./admission.ts";
import { AcquisitionConflict, MAX_CONFLICT_REPREPARATIONS } from "./acquisition.ts";
import type { ResultRecipe } from "./result_recipe.ts";
import { CompletedLine, isLineResult, type LineAdoption, type LineResult } from "./completed_line.ts";
import { readDirectReceipt } from "./direct_receipt.ts";

/** A receipt's string fields, proved present before custody moves. The Rust
 * runtime owns each command's result shape. A malformed receipt names a
 * defect there, and it refuses here rather than acquiring a wrong key. */
function receiptFields<T extends string>(result: unknown, fields: readonly T[]): Record<T, string> {
	if (result == null || typeof result !== "object") {
		throw new Error("The command receipt is not an object");
	}
	for (const field of fields) {
		if (typeof (result as Record<string, unknown>)[field] !== "string") {
			throw new Error(`The command receipt's ${field} is not a string`);
		}
	}
	return result as Record<T, string>;
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
		if (!isRetainedCommandIntent(original)) throw new Error("The retained command intent is malformed");
		if (!original[3].every((arg): arg is string => typeof arg === "string")) {
			throw new Error("A retained command argument is not a string");
		}
		name = original[2];
		args = original[3];
	} else if (original != null && typeof original === "object" && "upload" in original && original.upload != null) {
		if (!("conversation" in original) || typeof original.conversation !== "string") {
			throw new Error("A retained upload intent has no conversation");
		}
		name = "upload";
		args = [original.conversation];
	} else if (original != null && typeof original === "object" && "bridge" in original && original.bridge != null) {
		name = "bridge";
		args = [];
	} else {
		throw new Error("The retained intent has no completion owner");
	}
	switch (name) {
		case "say":
		case "upload":
		case "sendFiles":
		case "refileLine":
			if (result != null && !isLineResult(result)) {
				throw new Error("The command receipt does not have the line result shape");
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
		throw new Error("Result completion exceeded conflict re-preparation attempts.");
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
		if (row.kind !== "room") throw new Error("The initiating room changed");
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
			// The receipt mirrors the Rust `results::Direct` enum: pending
			// carries no inbox; only ready does.
			const receipt = readDirectReceipt(result);
			if (receipt.status === "pending") return result;
			const directory = recipe.directory(snapshot, args[0]);
			if (directory.name == null || directory.inbox == null) {
				throw new Error("The initiating nickname registration was retired. Its receipt remains held.");
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
			if (completion.kind !== "line") throw new Error("The posting completion has no line receipt");
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
			if (invitation == null) throw new Error("The original invitation was removed. Its receipt remains held.");
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
			const access: unknown = JSON.parse(args[2]);
			if (typeof access !== "string") throw new Error("The retained publication authority is not a key");
			if (
				!snapshot.intent.conversations.some((row) =>
					row.kind === "room" && row.directory === args[0] && row.access === access
				)
			) {
				throw new Error("The original room publication authority changed");
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
				for (const row of snapshot.intent.conversations) {
					if (
						row.kind === "room" && row.access != null &&
						await session.workspace.roomManagementIdentity(
								JSON.stringify({ role: "roomAccess", key: row.access }),
							) === args[2]
					) matches.push(row);
				}
				if (matches.length !== 1) throw new Error("Manager recovery requires one exact held room");
				conversation(matches[0].id);
				matches[0].control = retain("roomControl", receipt.control);
			} else if (args[1] !== "giveModerator") return result;
			// Operator issuance publishes the grant for copying from its inventory.
			// Retire the receipt's returned occurrence through atomic adoption.
			// A held conversation needs no change: the durable directory name is
			// not its display label, and the inventory can include unjoined rooms.
			break;
		}
		case "operations": {
			if (args[1] !== "ircGateway" || args[2] !== "connection") return result;
			const receipt = receiptFields(result, ["connection"]);
			const gateway: unknown = JSON.parse(args[0]);
			if (!isCoordinate(gateway)) throw new Error("The retained gateway selection is not a coordinate");
			if (
				!snapshot.intent.operations?.some((row) =>
					row.kind === "ircGateway" && row.handle.role === gateway.role && row.handle.key === gateway.key
				)
			) throw new Error("The original gateway selection changed");
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
