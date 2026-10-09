// Room use, control and receipt occurrences stay in separately typed fields.
import type { RoomsPageContext } from "../../page.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { RoomsRoomController } from "../../controller/session.ts";
import * as store from "../../store.ts";
import { refusalText } from "../../../../lib/text/failure.ts";
import { coordinate, fieldKey, type RoomIntent } from "./model.ts";
import type { BridgeForm } from "../../../../lib/bridge/form.ts";
import { WorkspaceConflict } from "./operation.ts";
import { ResultRecipe } from "./result_recipe.ts";

export function managedRoomActions(page: RoomsPageContext, session: ManagedRoomsSession): RoomsRoomController {
	const projection = page.projection;
	const room = (key: string) => {
		const view = store.getConv(projection, key);
		const row = view?.type === "room"
			? session.current?.intent.conversations.find((row) => row.id === view.persistId)
			: null;
		if (row?.kind !== "room") throw new Error("This room is no longer in the workspace");
		return row;
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
		const snapshot = await session.candidate();
		const row = snapshot.intent.conversations.find((row) => row.id === selected.id) as RoomIntent;
		const access = fieldKey();
		row[property] = access;
		const kind = property === "moderator" ? "roomAccess" : "roomControl";
		await session.actions.replace(snapshot, [], [{ coordinate: { role: kind, key: access }, uri }]);
	}
	async function drop(key: string, property: "moderator" | "control", expected: string): Promise<void> {
		const selected = room(key);
		if (selected[property] !== expected) throw new Error("The selected room authority changed");
		const snapshot = await session.candidate();
		const row = snapshot.intent.conversations.find((row) => row.id === selected.id) as RoomIntent;
		if (property === "moderator") delete row.moderator;
		else row.control = null;
		await session.actions.replace(snapshot);
	}
	return {
		bridgeForm: async (key) => {
			const row = room(key);
			if (row.seat == null) return null;
			return await session.workspace.readBridgeForm(coordinate("roomSeat", row.seat)) as BridgeForm | null;
		},
		submitBridgeForm: (key, scope, action, answers, secrets) =>
			outcome(async () => {
				const row = room(key);
				if (row.seat == null) throw new Error("The original room membership is not held");
				const declaration: BridgeForm | null = await session.workspace.readBridgeForm(
					coordinate("roomSeat", row.seat),
				);
				if (declaration == null || declaration.scope !== scope) {
					throw new Error("The bridge form changed. Review its current declaration before submitting.");
				}
				const operation = crypto.randomUUID();
				const snapshot = await session.refresh();
				const credentials = Object.keys(secrets).length === 0 ? null : fieldKey();
				const command = await session.perform(operation, () =>
					session.workspace.prepareBridge(
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
					));
				session.finish(command);
			}),
		stewardRoom: (key, uri) =>
			outcome(async () => {
				if (uri != null) return role(key, "moderator", uri);
				const selected = room(key);
				const recipe = new ResultRecipe();
				recipe.conversation(session.current!, selected.id);
				const operation = crypto.randomUUID();
				for (let attempt = 0;; attempt++) {
					try {
						const command = await session.command(
							"issueRoomModerator",
							[selected.id],
							operation,
							(snapshot) => {
								recipe.conversation(snapshot, selected.id);
							},
						);
						return await session.completeResult(command);
					} catch (error) {
						if (!(error instanceof WorkspaceConflict) || attempt === 3) throw error;
					}
				}
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
				const command = await session.command("ensureRoomLink", [selected.id]);
				await session.completeResult(command);
			}),
		recoverRoom: (key, uri) =>
			outcome(async () => {
				const selected = room(key);
				const snapshot = await session.candidate();
				const row = snapshot.intent.conversations.find((row) => row.id === selected.id) as RoomIntent;
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
