// Existing workspace choices survive older tabs that lost their startup ID.
import { useState } from "react";
import { refusalText } from "../../../lib/text/failure.ts";
import { Button } from "../Button.tsx";
import { reloadPage } from "../page_base.ts";
import { pinWorkspace, savedWorkspaces } from "../workspace_choice.ts";

export function SavedWorkspaces({ disabled, onError }: {
	disabled: boolean;
	onError: (text: string) => void;
}) {
	const [choices] = useState(savedWorkspaces);
	if (!choices.length) return null;
	return (
		<section className="launch session-setup-choice" aria-labelledby="savedWorkspaceTitle">
			<div className="launch-copy">
				<h2 id="savedWorkspaceTitle">Saved on this device</h2>
				<p className="hint">
					Resume a workspace with its rooms, messages and access. If it is open in another tab, close that tab
					first.
				</p>
				{choices.map((id) => (
					<Button
						key={id}
						disabled={disabled}
						onClick={() => {
							const refused = pinWorkspace(id);
							if (refused) onError(refusalText(refused));
							else reloadPage();
						}}
					>
						{choices.length === 1 ? "Resume workspace" : `Resume workspace · ${id.slice(0, 8)}`}
					</Button>
				))}
			</div>
		</section>
	);
}
