import { refusalText } from "../../../lib/text/failure.ts";
import {
	resumeWorkspace,
	savedWorkspaceHint,
	savedWorkspaceTitle,
	separateWorkspace,
} from "../../../lib/text/session.ts";
import { Button } from "../Button.tsx";
import { Icon } from "../icons.tsx";
import { chooseWorkspace } from "../workspace_choice.ts";

export function SavedWorkspaces({ choices, openFailed, disabled, onError }: {
	choices: readonly string[];
	openFailed: boolean;
	disabled: boolean;
	onError: (text: string) => void;
}) {
	if (!choices.length && !openFailed) return null;
	const choose = (id: string | null) => {
		const refused = chooseWorkspace(id);
		if (refused) onError(refusalText(refused));
	};
	return (
		<section className="launch session-setup-choice" aria-labelledby="savedWorkspaceTitle">
			<span className="launch-mark" aria-hidden="true">
				<Icon name="session" size={20} />
			</span>
			<div className="launch-copy">
				<h2 className="launch-title" id="savedWorkspaceTitle">{savedWorkspaceTitle}</h2>
				{choices.length > 0 && <p className="hint">{savedWorkspaceHint}</p>}
			</div>
			<div className="field-row saved-workspace-actions">
				{choices.map((id) => (
					<Button key={id} disabled={disabled} onClick={() => choose(id)}>
						{resumeWorkspace(id, choices.length > 1)}
					</Button>
				))}
				{openFailed && (
					<Button disabled={disabled} variant="quiet" onClick={() => choose(null)}>
						{separateWorkspace}
					</Button>
				)}
			</div>
		</section>
	);
}
