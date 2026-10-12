// Configuration and archive selection are revision-checked managed intent.
// Exported display data carries no authority. Imports cannot restore it by ID.
import type { RoomsPageContext } from "../../page.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { RoomsWorkspaceController } from "../../controller/session.ts";
import { type Coordinate, fieldKey, type WorkspaceIntent } from "./model.ts";
import { refusalText } from "../../../../lib/text/failure.ts";
import { coverForReload, finishCommittedMove, uncoverReload } from "../../boot.ts";
import { writeSearch } from "../../prefs.ts";
import { viewPreferences } from "../../view_preferences.ts";
import { parseRoomsViewState } from "../../../../lib/view_state.ts";

type Configuration = Pick<
	RoomsWorkspaceController,
	| "applySettings"
	| "exportRoomsState"
	| "importRoomsState"
	| "clearRoomsState"
	| "setKeepHistory"
	| "takeArchivePeer"
	| "retryArchivePeer"
	| "useOwnedArchive"
>;
export function managedWorkspaceActions(
	page: RoomsPageContext,
	session: ManagedRoomsSession,
	retryHistory: () => Promise<void>,
): Configuration {
	const outcome = async (work: () => Promise<unknown>): Promise<string> => {
		try {
			await work();
			return "";
		} catch (error) {
			return refusalText(error);
		}
	};
	return {
		applySettings: async (next) => {
			coverForReload();
			try {
				const current = await session.refresh();
				const dm = next.dm ?? current.intent.connection;
				await session.actions.run("chooseConnection", [dm]);
				const url = new URL(location.href);
				writeSearch(url, { dm });
				history.replaceState(null, "", url);
			} catch (error) {
				uncoverReload();
				throw error;
			}
			await finishCommittedMove(() => session.close());
			return true;
		},
		exportRoomsState: async (includeCapabilities = false) => {
			if (includeCapabilities) {
				const exported: { revision: string; intent: WorkspaceIntent; coordinates: Coordinate[] } = await session
					.workspace.exportConfiguration();
				const imports: { coordinate: Coordinate; uri: string }[] = [];
				for (const coordinate of exported.coordinates) {
					const uri: string | null = await session.workspace.custodyRecipe(JSON.stringify(coordinate));
					if (uri == null) {
						throw new Error(
							`The selected ${coordinate.role} has no durable recipe. A complete capability export is unavailable.`,
						);
					}
					imports.push({ coordinate, uri });
				}
				if ((await session.refresh()).revision !== exported.revision) {
					throw new Error(
						"The configuration changed during export. Review its current selections before exporting again.",
					);
				}
				return JSON.stringify(
					{
						version: 1,
						kind: "rooms-configuration",
						intent: exported.intent,
						imports,
						view: viewPreferences(page.projection),
					},
					null,
					2,
				);
			}
			const intent = session.current?.intent;
			if (intent == null) throw new Error("The workspace is not available");
			return JSON.stringify(
				{
					version: 1,
					kind: "rooms-presentation",
					directories: intent.directories.map((row) => ({ id: row.id, nick: row.nick })),
					conversations: intent.conversations.map((row) => ({
						kind: row.kind,
						id: row.id,
						directory: row.directory,
						label: row.kind === "room" ? row.name : row.peer,
						draft: row.draft,
					})),
					standing: intent.standing,
					ignored: intent.ignored,
					view: viewPreferences(page.projection),
				},
				null,
				2,
			);
		},
		importRoomsState: (raw) =>
			outcome(async () => {
				const data: unknown = JSON.parse(raw);
				if (
					data == null || typeof data !== "object" || !("version" in data) || data.version !== 1 ||
					!("kind" in data)
				) throw new Error("Invalid workspace export");
				const { view, ...configuration } = data as Record<string, unknown>;
				const preferences = view == null ? null : parseRoomsViewState(view);
				const encoded = JSON.stringify(configuration);
				if (data.kind === "rooms-configuration") {
					await session.actions.importState(encoded);
				} else {
					if (data.kind !== "rooms-presentation") throw new Error("Unknown workspace export kind");
					await session.actions.importState(encoded, true);
				}
				if (preferences != null) page.projection.set(preferences);
			}),
		clearRoomsState: () => outcome(() => session.actions.clear()),
		setKeepHistory: async (keep) => {
			await session.actions.run("chooseHistoryRetention", [String(keep)]);
		},
		takeArchivePeer: (uri) =>
			outcome(async () => {
				const snapshot = await session.candidate();
				const access = fieldKey();
				snapshot.intent.archive = access;
				snapshot.intent.archiveControl = null;
				await session.actions.replace(snapshot, [], [{
					coordinate: { role: "archiveAccess", key: access },
					uri,
				}]);
			}),
		retryArchivePeer: () => outcome(retryHistory),
		useOwnedArchive: async () => {
			const snapshot = await session.candidate();
			snapshot.intent.archive = null;
			snapshot.intent.archiveControl = null;
			await session.actions.replace(snapshot);
		},
	};
}
