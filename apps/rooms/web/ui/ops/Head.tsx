// The head every Operations pane shares: what this pane shows, and, where
// there is something to ask, the one control that asks the server again. The
// refresh sits at the lead's end rather than at the pane's foot, because it
// belongs to the whole pane and a button under a table reads as acting on the
// table's last row.
//
// A pane with no `refresh` has nothing to ask: the visualizer draws this
// tab's own publishing socket, which the store already knows about, so it
// gets the lead and no control that could only redraw what is there.

import { type ReactNode, useState } from "react";
import { IconButton } from "../IconButton.tsx";

export function OpsHead({ children, refresh }: { children: ReactNode; refresh?: () => Promise<void> }) {
	const [asking, setAsking] = useState(false);
	return (
		<div className="ops-head">
			<p className="lead">{children}</p>
			{refresh !== undefined && (
				<IconButton
					icon="retry"
					label="Refresh"
					title="Refresh"
					size="small"
					variant="ghost"
					className="ops-refresh"
					data-asking={asking ? "true" : undefined}
					aria-busy={asking || undefined}
					disabled={asking}
					onClick={() => {
						setAsking(true);
						void refresh().finally(() => setAsking(false));
					}}
				/>
			)}
		</div>
	);
}
