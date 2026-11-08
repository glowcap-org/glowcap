// The server dialog an act opens in the workspace when it reaches through a
// Rooms server and the page has none: the question session choice asks before
// Attach, asked where the act was. A session that has opened keeps its
// server, so saving reloads the page, standing at the act's own address so
// it picks up there.

import { saveAndReload } from "../../../lib/text/controls.ts";
import { serverAskAfterDoor, serverAskLead, sessionServerTitle } from "../../../lib/text/session.ts";
import { reloadNow } from "../boot.ts";
import { useRoomsProjection, useRoomsState } from "../hooks.ts";
import { pageBase } from "../page_base.ts";
import { ServerDialog } from "../settings/ServerDialog.tsx";
import * as store from "../store.ts";

export function ServerAsk() {
	const projection = useRoomsProjection();
	const ask = useRoomsState((state) => state.serverAsk);
	const saved = () => {
		// The act's address is a route under the page base, so the reload lands
		// on it under whatever base this build has.
		if (ask?.resume != null) {
			const at = new URL(ask.resume.replace(/^\//, ""), pageBase());
			globalThis.history.replaceState(globalThis.history.state, "", at);
		}
		reloadNow();
	};
	return (
		<ServerDialog
			title={sessionServerTitle}
			titleId="serverAskTitle"
			lead={ask?.why == null ? serverAskLead : serverAskAfterDoor(ask.why)}
			saveLabel={saveAndReload}
			open={ask != null}
			onClose={() => store.dismissServerAsk(projection)}
			onSaved={saved}
		/>
	);
}
