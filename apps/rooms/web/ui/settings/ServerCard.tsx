// The Rooms server this browser uses, shown as facts a person can check: which
// server, whether it answers, what its one address means, and the directory it
// hosts. The two WebSockets are read from the same Rust front the session
// dials through, so what this card says is what the session does.
//
// The card follows the Session card's shape: a mark, the server's name with its
// state as a chip, the facts its one address means, and one line per act. A
// page with no server shows the address field in place, because choosing one
// is the next thing it needs.

import { useEffect, useMemo, useState } from "react";
import { EntryAct, EntryActs } from "../EntryAct.tsx";
import { Icon } from "../icons.tsx";
import { useOpenModal } from "../modal.ts";
import { Submodal } from "../Submodal.tsx";
import {
	reachServerTitle,
	serverAddressName,
	serverAwayRefuses,
	serverAwaySilent,
	serverChange,
	serverChangeAct,
	serverChangeLead,
	serverChosenHere,
	serverConnected,
	serverConnecting,
	serverFactDirectory,
	serverFactReachable,
	serverFactRelay,
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
	settingsRelayAway,
	settingsShareDirectory,
} from "../../../lib/text/settings.ts";
import { namesDirectory, serverRoutes } from "../application.ts";
import { CopyField } from "../Copy.tsx";
import { Said } from "../Said.tsx";
import { chooseServer, probeServer, serverInUse, type ServerProbe } from "../server_choice.ts";
import { servedByRooms } from "../page_base.ts";
import { Confirm } from "../Confirm.tsx";
import { relayAway, type RelayReach } from "../store/projection.ts";
import { ServerChoice } from "./ServerChoice.tsx";

/** The registration's phase as a chip, toned the way the access chips are. A
 * registration that closed says why once the server has been asked: a server
 * that turns this page away answered, so it is not "not answering". */
function phase(
	relay: RelayReach,
	cause: ServerProbe["kind"] | null,
): { tone: "quiet" | "warn" | undefined; said: string } {
	if (relay === "reached") return { tone: undefined, said: serverConnected };
	if (relay === "connecting") return { tone: "quiet", said: serverConnecting };
	if (cause === "refuses") return { tone: "warn", said: serverTurnsAway };
	// Anything that answered is up, so the chip says only that this browser is
	// not connected through it.
	return { tone: "warn", said: cause === "silent" ? serverNotAnswering : serverNotConnected };
}

/** A server named the way a person typed it: its host, and its path when it
 * lives below the root. */
function serverName(base: string): string {
	const url = new URL(base);
	return url.pathname === "/" ? url.host : url.host + url.pathname.replace(/\/$/, "");
}

export function ServerCard(
	{ directory, relay, reload = () => location.reload() }: {
		directory: string | null;
		relay: RelayReach | null;
		reload?: () => void;
	},
) {
	// The server is fixed for this page's life: choosing another reloads it.
	const [server] = useState(() => serverInUse());
	const routes = useMemo(() => server == null ? null : serverRoutes(server.base), [server]);
	const [changing, setChanging] = useState(false);
	const [removing, setRemoving] = useState(false);
	const openModalFrom = useOpenModal();
	const away = relayAway(relay);
	// While the registration is closed, ask the server what Test would, so the
	// card names the one cause and its fix rather than both possibilities.
	const [cause, setCause] = useState<ServerProbe["kind"] | null>(null);
	useEffect(() => {
		if (!away || server == null) {
			setCause(null);
			return;
		}
		let current = true;
		void probeServer(server.base, namesDirectory).then((probe) => {
			if (current) setCause(probe.kind);
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
				{server != null && routes != null && (
					<dl className="dirfacts server-facts">
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
						<dt>{serverFactRelay}</dt>
						<dd>
							<code className="server-route" id="serverRelay">{routes.relay}</code>
						</dd>
						<dt>{serverFactReachable}</dt>
						<dd>
							<code className="server-route" id="serverRegister">{routes.register}</code>
						</dd>
					</dl>
				)}
				{away && server != null && (
					<Said id="relayAway" kind="warning">
						{cause === "refuses"
							? serverAwayRefuses(location.origin)
							: cause === "silent"
							? serverAwaySilent(serverName(server.base))
							: settingsRelayAway(serverName(server.base), location.origin)}
					</Said>
				)}
				{server == null ? <ServerChoice /> : (
					<EntryActs>
						<EntryAct
							name={serverAddressName}
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
											reload();
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
				<Submodal
					title={serverChange}
					titleId="serverChangeTitle"
					open={changing}
					onClose={() => setChanging(false)}
				>
					<p className="lead">{serverChangeLead}</p>
					<ServerChoice framed />
				</Submodal>
			)}
		</>
	);
}
