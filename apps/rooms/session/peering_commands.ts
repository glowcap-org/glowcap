// Pure checkpoint mutations for durable foreign-room publication intent.
//
// The capability set and the publication list are one invariant: removing a
// peering capability removes every intent it authorized, while adding and
// revoking one publication changes only the restartable intent. Keeping all
// three transitions here prevents the generic command dispatcher from owning
// half of that relation.

import {
	peeringIntentsForOperations,
	type RoomsSessionState,
	WorkspaceOperationCredentialsSchema,
	WorkspacePeeringIntentSchema,
} from "../lib/rooms_state.ts";
import { commandJson, validatedRoomsSessionState } from "./command_data.ts";

export function applyPeeringCommand(
	current: RoomsSessionState,
	command: "publishPeeredRoom" | "revokePeeredRoom" | "replaceOperationsCapabilities",
	args: string[],
): RoomsSessionState {
	if (command === "publishPeeredRoom") {
		if (args.length !== 1) throw new Error("publishPeeredRoom takes one publication intent");
		const intent = commandJson(args[0], command, WorkspacePeeringIntentSchema);
		if (
			!current.capabilities.operations.some((entry) =>
				entry.capability === "peering" && entry.scope === intent.destination
			)
		) {
			throw new Error("publishPeeredRoom needs a peering capability for its destination");
		}
		if (current.peering.some((entry) => entry.id === intent.id)) {
			const existing = current.peering.find((entry) => entry.id === intent.id);
			if (JSON.stringify(existing) !== JSON.stringify(intent)) {
				throw new Error("publishPeeredRoom reuses an id for different intent");
			}
			return current;
		}
		return validatedRoomsSessionState({ ...current, peering: [...current.peering, intent] });
	}
	if (command === "revokePeeredRoom") {
		if (args.length !== 1) throw new Error("revokePeeredRoom takes one publication id");
		if (!current.peering.some((entry) => entry.id === args[0])) {
			throw new Error("revokePeeredRoom names no publication in this session");
		}
		return validatedRoomsSessionState({
			...current,
			peering: current.peering.filter((entry) => entry.id !== args[0]),
		});
	}
	if (args.length !== 1) throw new Error("replaceOperationsCapabilities takes one credential list");
	const operations = commandJson(args[0], command, WorkspaceOperationCredentialsSchema);
	return validatedRoomsSessionState({
		...current,
		peering: peeringIntentsForOperations(operations, current.peering),
		capabilities: { ...current.capabilities, operations },
	});
}
