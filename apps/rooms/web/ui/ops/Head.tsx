// The head every Operations pane shares: what this pane shows, and, where
// there is something to ask, the one control that asks the server again. The
// refresh sits at the lead's end rather than at the pane's foot, because it
// belongs to the whole pane and a button under a table reads as acting on the
// table's last row.
//
// A pane with no `refresh` has nothing to ask: the visualizer draws the
// publishing socket the store already knows about, so it gets the lead and
// no control that could only redraw what is there.

import { type ReactNode, useState } from "react";
import { IconButton } from "../IconButton.tsx";
import { Said } from "../Said.tsx";
import { refusalText } from "../../../lib/text/failure.ts";
import { opsRefresh, opsRefreshing } from "../../../lib/text/ops.ts";

export function OpsHead({ children, refresh }: { children: ReactNode; refresh?: () => Promise<void> }) {
	const [asking, setAsking] = useState(false);
	const [why, setWhy] = useState("");
	return (
		<div className="ops-head">
			<div className="ops-head-copy">
				<p className="lead">{children}</p>
				{why !== "" && <Said kind="failure">{why}</Said>}
			</div>
			{refresh !== undefined && (
				<IconButton
					icon="retry"
					label={asking ? opsRefreshing : opsRefresh}
					title={asking ? opsRefreshing : opsRefresh}
					size="small"
					variant="ghost"
					className="ops-refresh"
					busy={asking}
					onClick={() => {
						setAsking(true);
						setWhy("");
						void refresh().catch((error) => setWhy(refusalText(error)))
							.finally(() => setAsking(false));
					}}
				/>
			)}
		</div>
	);
}
