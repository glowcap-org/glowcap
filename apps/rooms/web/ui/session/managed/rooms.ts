// Room use, control and receipt occurrences stay in separately typed fields.
import { conversationById } from "./conversation_lookup.ts";
import { invariant } from "../../../../lib/invariant.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { RoomsRoomController } from "../../controller/session.ts";
import * as store from "../../store.ts";
import { LocalRefusal, refusalText } from "../../../../lib/text/failure.ts";
import { coordinate, fieldKey, type RoomIntent, type WorkspaceSnapshot } from "./model.ts";
import type { BridgeForm } from "../../../../lib/bridge/form.ts";
import { ResultRecipe } from "./result_recipe.ts";

export function managedRoomActions(page: RoomsPageContext, session: ManagedRoomsSession): RoomsRoomController {
	const projection = page.projection;
	const held = (snapshot: WorkspaceSnapshot | null, id: string | undefined): RoomIntent => {
		const row = conversationById(snapshot, id);
		if (row?.kind !== "room") throw new LocalRefusal("room-gone");
		return row;
	};
	const room = (key: string) => {
		const view = store.getConv(projection, key);
		return held(session.current, view?.type === "room" ? view.persistId : undefined);
	};
	const outcome = async (work: () => Promise<unknown>): Promise<string> => {
		try {
			await work();
			return "";
		} catch (error) {
			return refusalText(error);
		}
	};
	async function role(key: string, property: "moderator" | "control", uri: string): Promise<void> {
		const selected = room(key);
		const snapshot = await session.candidateBeforeSending();
		const row = held(snapshot, selected.id);
		const access = fieldKey();
		row[property] = access;
		const kind = property === "moderator" ? "roomAccess" : "roomControl";
		await session.actions.replace(snapshot, [], [{ coordinate: { role: kind, key: access }, uri }]);
	}
	async function drop(key: string, property: "moderator" | "control", expected: string): Promise<void> {
		const selected = room(key);
		if (selected[property] !== expected) {
			throw new LocalRefusal("room-authority-changed");
		}
		const snapshot = await session.candidateBeforeSending();
		const row = held(snapshot, selected.id);
		if (property === "moderator") delete row.moderator;
		else row.control = null;
		await session.actions.replace(snapshot);
	}
	return {
		bridgeForm: async (key) => {
			const row = room(key);
			if (row.seat == null) return null;
			const seat = coordinate("roomSeat", row.seat);
			const form: BridgeForm | null = await session.request((workspace) => workspace.readBridgeForm(seat));
			return form;
		},
		submitBridgeForm: (key, scope, action, answers, secrets) =>
			outcome(async () => {
				const row = room(key);
				if (row.seat == null) throw new LocalRefusal("room-gone");
				const seat = coordinate("roomSeat", row.seat);
				const declaration: BridgeForm | null = await session.request((workspace) =>
					workspace.readBridgeForm(seat)
				);
				if (declaration == null || declaration.scope !== scope) {
					throw new LocalRefusal("room-access-changed");
				}
				const operation = crypto.randomUUID();
				const credentials = Object.keys(secrets).length === 0 ? null : fieldKey();
				// Each preparation reads its own base, so one prepared again over a
				// new link starts from what that link's session holds.
				const command = await session.perform(operation, async (workspace) => {
					const snapshot = await session.readNow();
					return workspace().prepareBridge(
						JSON.stringify({
							bridge: { declaration, action, answers },
							operation,
							base: Number(snapshot.revision),
							room: row.id,
							seat: row.seat,
							access: row.access != null
								? { role: "roomAccess", key: row.access }
								: row.accepted != null
								? { role: "acceptedAccess", key: row.accepted }
								: null,
							credentials,
							reapply: null,
						}),
						JSON.stringify(secrets),
					);
				});
				session.finish(command);
			}),
		stewardRoom: (key, uri) =>
			outcome(async () => {
				if (uri != null) return role(key, "moderator", uri);
				const selected = room(key);
				const recipe = new ResultRecipe();
				const current = session.current;
				invariant(current != null, "room() found the room in this snapshot in this turn");
				recipe.conversation(current, selected.id);
				return await session.actions.run("issueRoomModerator", [selected.id], (snapshot) => {
					recipe.conversation(snapshot, selected.id);
				});
			}),
		managerRoom: (key, uri) => outcome(() => role(key, "control", uri)),
		dropRoomManager: (key, token) => outcome(() => drop(key, "control", token)),
		dropRoomModerator: (key, token) => outcome(() => drop(key, "moderator", token)),
		revokeManagedRoomAuthority: (key, kind, token) =>
			outcome(() =>
				session.actions.run("revokeManagedRoomAuthority", [room(key).id, kind, JSON.stringify(token)])
			),
		unregisterManagedRoom: (key) => outcome(() => session.actions.run("unregisterManagedRoom", [room(key).id])),
		setManagedRoomPolicy: (key, policy) =>
			outcome(() =>
				session.actions.run("setManagedRoomPolicy", [
					room(key).id,
					policy.visibility,
					policy.entry,
					policy.speaking,
				])
			),
		createRoomLink: (key) =>
			outcome(async () => {
				const selected = room(key);
				await session.actions.run("ensureRoomLink", [selected.id]);
			}),
		recoverRoom: (key, uri) =>
			outcome(async () => {
				const selected = room(key);
				const snapshot = await session.candidateBeforeSending();
				const row = held(snapshot, selected.id);
				if (uri != null && uri !== "") {
					const access = fieldKey();
					row.access = access;
					row.reconnect = "requested";
					delete row.accepted;
					delete row.publicEntry;
					delete row.publication;
					await session.actions.replace(snapshot, [], [{
						coordinate: { role: "roomAccess", key: access },
						uri,
					}]);
				} else {
					row.reconnect = "requested";
					await session.actions.replace(snapshot);
				}
			}),
		askRoomMemberOut: (key, name) => outcome(() => session.actions.run("kickRoomMember", [room(key).id, name])),
	};
}
