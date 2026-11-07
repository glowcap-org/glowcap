// The Rooms server this browser uses, shown as facts a person can check: which
// server, whether it answers, what its one address means, and the directory it
// hosts. Every fact is the page's own state, the server in use, the relay's
// reach, and the directory it hosts, so what this card says is what the
// session does.
//
// The card follows the Session card's shape: a mark, the server's name with its
// state as a chip, the facts its one address means, and one line per act. A
// page with no server shows the address field in place, because choosing one
// is the next thing it needs.

import { useEffect, useState } from "react";
import { EntryAct, EntryActs } from "../EntryAct.tsx";
import { Icon } from "../icons.tsx";
import { useOpenModal } from "../modal.ts";
import {
	reachServerTitle,
	serverAddressName,
	serverAwayBlocked,
	serverAwayRefuses,
	serverAwaySilent,
	serverBlockedByBrowser,
	serverChange,
	serverChangeAct,
	serverChangeLead,
	serverChangeName,
	serverChosenHere,
	serverConnected,
	serverConnecting,
	serverFactDirectory,
	serverFromPage,
	serverNoDirectory,
	serverNone,
	serverNoneTitle,
	serverNotAnswering,
	serverNotConnected,
	serverRemoveAct,
	serverRemoveCommit,
	serverRemoveConfirm,
	serverRemoveKeep,
	serverRemoveName,
	serverRemoveSaid,
	serverTurnsAway,
	settingsCopyDirectory,
	settingsCopyServer,
	settingsRelayAway,
	settingsShareDirectory,
} from "../../../lib/text/settings.ts";
import { saveAndReload } from "../../../lib/text/controls.ts";
import { namesDirectory } from "../application.ts";
import { reloadNow } from "../boot.ts";
import { CopyField } from "../Copy.tsx";
import { Said } from "../Said.tsx";
import { chooseServer, probeServer, serverName, type ServerProbe } from "../server_choice.ts";
import { useRoomsState } from "../hooks.ts";
import { servedByRooms } from "../page_base.ts";
import { Confirm } from "../Confirm.tsx";
import { relayAway, type RelayReach } from "../store/projection.ts";
import { ServerChoice } from "./ServerChoice.tsx";
import { ServerDialog } from "./ServerDialog.tsx";

/** The registration's phase as a chip, toned the way the access chips are. A
 * registration that closed says why once the server has been asked: a server
 * that turns this page away answered, so it is not "not answering". */
function phase(
	relay: RelayReach,
	cause: ServerProbe | null,
): { tone: "quiet" | "warn" | undefined; said: string } {
	if (relay === "reached") return { tone: undefined, said: serverConnected };
	if (relay === "connecting") return { tone: "quiet", said: serverConnecting };
	if (cause?.kind === "refuses") return { tone: "warn", said: serverTurnsAway };
	if (cause?.kind === "blocked") return { tone: "warn", said: serverBlockedByBrowser };
	// Anything that answered is up, so the chip says only that this browser is
	// not connected through it.
	return { tone: "warn", said: cause?.kind === "silent" ? serverNotAnswering : serverNotConnected };
}

export function ServerCard({ relay }: { relay: RelayReach | null }) {
	// The server is fixed for this page's life: choosing another reloads it.
	const server = useRoomsState((state) => state.server);
	const directory = server?.directory ?? null;
	const [changing, setChanging] = useState(false);
	const [removing, setRemoving] = useState(false);
	const openModalFrom = useOpenModal();
	const away = relayAway(relay);
	// While the registration is closed, ask the server what Test would, so the
	// card names the one cause and its fix rather than both possibilities.
	const [cause, setCause] = useState<ServerProbe | null>(null);
	useEffect(() => {
		if (!away || server == null) {
			setCause(null);
			return;
		}
		let current = true;
		void probeServer(server.base, namesDirectory).then((probe) => {
			if (current) setCause(probe);
		});
		return () => {
			current = false;
		};
	}, [away, server]);
	const said = relay == null ? null : phase(relay, cause);
	// A directory the page could not read is unknown, not absent, while the
	// server is away, so its row waits for a server that answers.
	const directoryKnown = directory != null || !away;
	return (
		<>
			<h3 className="well-title overline" id="serverLegend">{reachServerTitle}</h3>
			<div className="group well" id="serverCard" role="group" aria-labelledby="serverLegend">
				<div className="launch">
					<span className="launch-mark" aria-hidden="true">
						<Icon name="directory" size={18} />
					</span>
					<div className="launch-copy">
						<p className="launch-title">
							{server == null
								? <span id="serverName">{serverNoneTitle}</span>
								: <span className="server-name" id="serverName">{serverName(server.base)}</span>}
							{said != null && server != null && (
								<span className="tag" id="serverConnection" data-tone={said.tone}>{said.said}</span>
							)}
						</p>
						<p className="hint">
							{server == null ? serverNone : server.chosen ? serverChosenHere : serverFromPage}
						</p>
					</div>
				</div>
				{server != null && (
					<dl className="dirfacts server-facts">
						{/* The address as another browser's server field takes it. */}
						<dt>{serverAddressName}</dt>
						<dd>
							<CopyField id="serverBase" text={server.base} label={settingsCopyServer} />
						</dd>
						{directoryKnown && (
							<>
								<dt>{serverFactDirectory}</dt>
								<dd>
									{directory == null ? <span className="dirfact-why">{serverNoDirectory}</span> : (
										<>
											<CopyField
												id="directoryLocator"
												text={directory}
												label={settingsCopyDirectory}
											/>
											<span className="hint">{settingsShareDirectory}</span>
										</>
									)}
								</dd>
							</>
						)}
					</dl>
				)}
				{away && server != null && (
					<Said id="relayAway" kind="warning">
						{cause?.kind === "refuses"
							? serverAwayRefuses(location.origin)
							: cause?.kind === "blocked"
							? serverAwayBlocked(cause.permission)
							: cause?.kind === "silent"
							? serverAwaySilent(serverName(server.base))
							: settingsRelayAway(serverName(server.base), location.origin)}
					</Said>
				)}
				{server == null ? <ServerChoice /> : (
					<EntryActs>
						<EntryAct
							name={serverChangeName}
							id="serverChange"
							act={serverChangeAct}
							onClick={(event) => openModalFrom(event.currentTarget, () => setChanging(true))}
						/>
						{/* Only a server this browser chose can be removed. The one a page came from is the page's own. */}
						{server.chosen && (removing
							? (
								<li className="entry">
									<Confirm
										label={serverRemoveConfirm}
										say={serverRemoveSaid(servedByRooms())}
										keep={serverRemoveKeep}
										commit={serverRemoveCommit}
										keepId="serverRemoveKeep"
										commitId="serverRemoveCommit"
										onKeep={() => setRemoving(false)}
										onCommit={() => {
											chooseServer(null);
											reloadNow();
										}}
									/>
								</li>
							)
							: (
								<EntryAct
									name={serverRemoveName}
									id="serverRemove"
									act={serverRemoveAct}
									onClick={() => setRemoving(true)}
								/>
							))}
					</EntryActs>
				)}
			</div>
			{server != null && (
				<ServerDialog
					title={serverChange}
					titleId="serverChangeTitle"
					lead={serverChangeLead}
					saveLabel={saveAndReload}
					open={changing}
					onClose={() => setChanging(false)}
				/>
			)}
		</>
	);
}
