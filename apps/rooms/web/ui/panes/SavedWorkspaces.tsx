import { useState } from "react";
import { Select } from "../Select.tsx";
import { Said } from "../Said.tsx";
import { refusalText } from "../../../lib/text/failure.ts";
import {
	resumeWorkspace,
	savedWorkspaceHint,
	savedWorkspaceOption,
	savedWorkspacesHint,
	savedWorkspaceTitle,
	separateWorkspace,
} from "../../../lib/text/session.ts";
import { Button } from "../Button.tsx";
import { Icon } from "../icons.tsx";
import { chooseWorkspace, lastWorkspace } from "../workspace_choice.ts";

export function SavedWorkspaces({ choices, initialError, disabled }: {
	choices: readonly string[];
	initialError: string;
	disabled: boolean;
}) {
	const [error, setError] = useState(initialError);
	const last = lastWorkspace();
	const recentFirst = last && choices.includes(last) ? [last, ...choices.filter((id) => id !== last)] : choices;
	const [selected, setSelected] = useState(recentFirst[0]);
	const choose = (id: string | null) => {
		const refused = chooseWorkspace(id);
		if (refused) setError(refusalText(refused));
	};
	return (
		<section className="launch session-setup-choice" aria-labelledby="savedWorkspaceTitle">
			<span className="launch-mark" aria-hidden="true">
				<Icon name="session" size={20} />
			</span>
			<div className="launch-copy">
				<h2 className="launch-title" id="savedWorkspaceTitle">{savedWorkspaceTitle}</h2>
				{choices.length > 0 && (
					<p className="hint">{choices.length > 1 ? savedWorkspacesHint : savedWorkspaceHint}</p>
				)}
			</div>
			<div className="field-row saved-workspace-actions">
				{error && <Said id="savedWorkspaceFailure" kind="failure">{error}</Said>}
				{choices.length > 1 && (
					<Select
						aria-labelledby="savedWorkspaceTitle"
						value={selected}
						disabled={disabled}
						onChange={(event) => setSelected(event.currentTarget.value)}
					>
						{recentFirst.map((id) => (
							<option key={id} value={id}>{savedWorkspaceOption(id, choices, last)}</option>
						))}
					</Select>
				)}
				{selected && <Button disabled={disabled} onClick={() => choose(selected)}>{resumeWorkspace}</Button>}
				{initialError && (
					<Button disabled={disabled} variant="quiet" onClick={() => choose(null)}>
						{separateWorkspace}
					</Button>
				)}
			</div>
		</section>
	);
}
