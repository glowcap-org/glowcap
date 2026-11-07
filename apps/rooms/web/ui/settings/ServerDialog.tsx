// The dialog that chooses a Rooms server, wherever it opens: over session
// setup, from the server card in Settings, and in the workspace when an act
// reaches through a server the page has none of. The lead says why it is open
// and what saving leads to, and the form is the one the card holds in place.

import { Submodal } from "../Submodal.tsx";
import { ServerChoice } from "./ServerChoice.tsx";

export function ServerDialog(
	{ title, titleId, lead, saveLabel, open, onClose, onSaved }: {
		title: string;
		titleId: string;
		lead: string;
		saveLabel: string;
		open: boolean;
		onClose: () => void;
		/** Runs once the choice is kept. By default the page reloads under it. */
		onSaved?: () => void;
	},
) {
	return (
		<Submodal title={title} titleId={titleId} open={open} onClose={onClose}>
			<p className="lead">{lead}</p>
			<ServerChoice framed saveLabel={saveLabel} onSaved={onSaved} />
		</Submodal>
	);
}
