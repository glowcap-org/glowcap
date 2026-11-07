// The Rooms server line under the session choices, and the dialog that
// changes it. Both doors reach through one server, so the line names it before
// anything opens, and the dialog says what saving leads to: the choice holds
// in place, attaches when Attach asked for it, or reloads when a session has
// already opened with another server.

import { saveAndReload } from "../../../lib/text/controls.ts";
import {
	sessionServerAttachLead,
	sessionServerChoose,
	sessionServerLead,
	sessionServerName,
	sessionServerNone,
	sessionServerSave,
	sessionServerSaveAttach,
	sessionServerTitle,
} from "../../../lib/text/session.ts";
import { serverChange, serverChangeAct, serverChangeLead } from "../../../lib/text/settings.ts";
import { Button } from "../Button.tsx";
import { useOpenModal } from "../modal.ts";
import { type ServerInUse, serverName } from "../server_choice.ts";
import { ServerDialog } from "../settings/ServerDialog.tsx";

/** Why the dialog is open: to change the server, or because Attach needs one. */
export type ServerChoosing = "change" | "attach" | null;

/** `held` says a session has opened and keeps its server, so saving reloads. */
export function SessionServer(
	{ server, held, busy, choosing, onChoosing, onSaved }: {
		server: ServerInUse | null;
		held: boolean;
		busy: boolean;
		choosing: ServerChoosing;
		onChoosing: (choosing: ServerChoosing) => void;
		onSaved: () => void;
	},
) {
	const openModalFrom = useOpenModal();
	return (
		<>
			<p className="session-setup-server" id="sessionServer">
				<span className="session-setup-server-label">{sessionServerName}</span>
				{server == null
					? <span className="hint">{sessionServerNone}</span>
					: <span className="server-name" id="sessionServerName">{serverName(server.base)}</span>}
				<Button
					id="sessionServerChange"
					variant="link"
					disabled={busy}
					onClick={(event) => openModalFrom(event.currentTarget, () => onChoosing("change"))}
				>
					{server == null ? sessionServerChoose : serverChangeAct}
				</Button>
			</p>
			<ServerDialog
				title={server == null ? sessionServerTitle : serverChange}
				titleId="sessionServerTitle"
				lead={held ? serverChangeLead : choosing === "attach" ? sessionServerAttachLead : sessionServerLead}
				saveLabel={held ? saveAndReload : choosing === "attach" ? sessionServerSaveAttach : sessionServerSave}
				open={choosing != null}
				onClose={() => onChoosing(null)}
				onSaved={onSaved}
			/>
		</>
	);
}
