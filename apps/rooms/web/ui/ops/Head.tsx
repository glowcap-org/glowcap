// The head every Operations pane shares: what this pane shows, and the one
// control that asks the server again. The refresh sits at the lead's end
// rather than at the pane's foot, because it belongs to the whole pane and a
// button under a table reads as acting on the table's last row.

import { type ReactNode, useState } from "react";
import { IconButton } from "../IconButton.tsx";

export function OpsHead({ children, refresh }: { children: ReactNode; refresh: () => Promise<void> }) {
	const [asking, setAsking] = useState(false);
	return (
		<div className="ops-head">
			<p className="lead">{children}</p>
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
		</div>
	);
}
