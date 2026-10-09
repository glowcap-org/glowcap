// The persisted request drives first completion and recovery after reload.
// Capability occurrences stay in the receipt until their atomic adoption.
import type { ManagedRoomsSession } from "./session.ts";
import type { ManagedOperation } from "./operation.ts";
import { type Coordinate, type DirectIntent, type RoomIntent } from "./model.ts";
import { AcquisitionConflict } from "./acquisition.ts";
import type { ResultRecipe } from "./result_recipe.ts";

export function completeResult(session: ManagedRoomsSession, operation: ManagedOperation): Promise<unknown> {
	return operation.complete(async (recipe) => {
		for (let attempt = 0;; attempt++) {
			try {
				return await completeOnce(session, operation, recipe);
			} catch (error) {
				// Conflict installed no result custody. Recompose only the workspace
				// delta, keeping the original receipt, targets and destination keys.
				if (!(error instanceof AcquisitionConflict) || attempt === 3) throw error;
			}
		}
	});
}

async function completeOnce(
	session: ManagedRoomsSession,
	operation: ManagedOperation,
	recipe: ResultRecipe,
): Promise<unknown> {
	const result = await operation.result();
	if (operation.acquired || await operation.request.adopted()) {
		await session.refresh();
		return result;
	}
	const original = operation.request.originalIntent();
	const [name, args]: [string, string[]] = Array.isArray(original)
		? [original[2], original[3]]
		: original.upload != null
		? ["upload", [original.conversation]]
		: ["bridge", []];
	const snapshot = await session.candidate();
	const mappings: { result: Coordinate; destination: Coordinate }[] = [];
	const releases: Coordinate[] = [];
	let source: string | undefined;
	const data = result as {
		room: string;
		control: string;
		status: "ready" | "pending";
		inbox: string;
		line: string | null;
		id: number | null;
		entrance: string;
		lease: string;
		steward: string | null;
		moderator: string;
		name: string;
		connection: string;
	} | null;
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
	switch (name) {
		case "openManagedRoom": {
			recipe.directory(snapshot, args[0]);
			source = recipe.source();
			snapshot.intent.conversations.push({
				kind: "room",
				id: operation.id,
				directory: args[0],
				name: args[1],
				source,
				access: retain("roomAccess", data!.room),
				control: retain("roomControl", data!.control),
				reconnect: "requested",
				standing: null,
				draft: "",
			});
			snapshot.intent.active = operation.id;
			break;
		}
		case "startDirect": {
			if (data!.status === "pending") return result;
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
				access: retain("directAccess", data!.inbox),
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
			const row = conversation(args[0]);
			// The composer owns draft admission. Acquiring a line cannot clear a
			// later draft, even when its caption equals the submitted message.
			if (data?.line != null && data.id != null) {
				const replaced = row.lines?.find((line) => line.id === data.id);
				recipe.check(`line:${row.id}:${data.id}`, replaced?.handle ?? null);
				// Direct settlement already installed sender provenance at this field.
				// Atomic acquisition verifies the existing occurrence equals the reply.
				const preserved = row.kind === "direct" ? replaced?.handle : undefined;
				if (preserved != null) {
					mappings.push({
						result: { role: "line", key: data.line },
						destination: { role: "line", key: preserved },
					});
				}
				row.lines = [...(row.lines ?? []).filter((line) => line.id !== data.id), {
					id: data.id,
					handle: preserved ?? retain("line", data.line),
				}];
				if (replaced != null && preserved == null) releases.push({ role: "line", key: replaced.handle });
			}
			break;
		}
		case "acceptInvitation": {
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
				accepted: retain("acceptedAccess", data!.entrance),
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
			const row = room(args[0]);
			row.moderator = retain("roomAccess", data!.moderator);
			break;
		}
		case "ensureRoomLink": {
			const row = room(args[0]);
			row.access = retain("roomAccess", data!.room);
			delete row.accepted;
			delete row.publicEntry;
			break;
		}
		case "publishPeeredRoom": {
			const access: string = JSON.parse(args[2]);
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
				lease: retain("publicationLease", data!.lease),
			});
			break;
		}
		case "operator": {
			if (args[1] === "giveManager") {
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
				matches[0].control = retain("roomControl", data!.control);
			} else if (args[1] !== "giveModerator") return result;
			// Operator issuance publishes the grant for copying from its inventory.
			// Retire the receipt's returned occurrence through atomic adoption.
			// A held conversation needs no change: the durable directory name is
			// not its display label, and the inventory can include unjoined rooms.
			break;
		}
		case "operations": {
			if (args[1] !== "ircGateway" || args[2] !== "connection") return result;
			const gateway: Coordinate = JSON.parse(args[0]);
			if (
				!snapshot.intent.operations?.some((row) =>
					row.kind === "ircGateway" && row.handle.role === gateway.role && row.handle.key === gateway.key
				)
			) throw new Error("The original gateway selection changed");
			snapshot.intent.operations = [...(snapshot.intent.operations ?? []), {
				kind: "ircConnection",
				handle: { role: "ircConnection", key: retain("ircConnection", data!.connection) },
				connection: { operation: operation.id, gateway, id: args[3] },
			}];
			break;
		}
		default:
			return result;
	}
	await operation.acquire(snapshot, mappings, releases, source, name === "openManagedRoom");
	await session.refresh();
	return result;
}
