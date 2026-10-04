// One saved operations-capability bundle, projected as switches or text.

import { Button } from "../Button.tsx";
import {
	capabilitySetEditSwiss,
	capabilitySetInclude,
	capabilitySetPlaceholder,
	capabilitySetRetry,
	capabilitySetSave,
	capabilitySetTitle,
} from "../../../lib/text/settings.ts";
import { holdingsEditAsControls, holdingsEditAsText } from "../../../lib/text/ops.ts";
import { IconButton } from "../IconButton.tsx";
import { OPS_CATALOG } from "../ops/catalog.ts";
import { formatOpsBundle, OPS_BUNDLE_CAPABILITIES, opsBundleReady, parseOpsBundleDraft } from "../ops/bundle.ts";
import { Switch } from "../Switch.tsx";
import { Said } from "../Said.tsx";
import { CapabilityValueEditor, useCapabilitySetModel } from "./CapabilitySetModel.tsx";

export function CapabilitySetForm() {
	const model = useCapabilitySetModel();
	const { mode, text, setMode, setText } = model;

	const showText = () => {
		setText(formatOpsBundle(model.draft));
		model.setError("");
		setMode("text");
	};
	const showControls = () => {
		try {
			const parsed = parseOpsBundleDraft(text);
			if (parsed.size > 0 && !opsBundleReady(parsed)) {
				throw new Error("Supply a swiss number for every enabled capability.");
			}
			model.setDraft(parsed);
			model.setError("");
			setMode("controls");
		} catch (cause) {
			model.setError(cause instanceof Error ? cause.message : String(cause));
		}
	};
	const save = () => {
		try {
			const wanted = mode === "controls" ? model.draft : parseOpsBundleDraft(text);
			if (wanted.size > 0 && !opsBundleReady(wanted)) {
				throw new Error("Supply a swiss number for every enabled capability.");
			}
			void model.commit(wanted);
		} catch (cause) {
			model.setError(cause instanceof Error ? cause.message : String(cause));
		}
	};
	const dirty = model.dirty;
	const actionable = dirty || model.retryPending;

	return (
		<>
			<form
				id="opsCapabilitySetForm"
				className="group"
				onSubmit={(event) => {
					event.preventDefault();
					save();
				}}
			>
				<div className="capability-set-head">
					<p className="field-label" id="opsCapabilitySetLabel">{capabilitySetTitle}</p>
					<IconButton
						id={mode === "controls" ? "opsCapabilitySetEditText" : "opsCapabilitySetEditControls"}
						icon={mode === "controls" ? "pencil" : "check"}
						label={mode === "controls" ? holdingsEditAsText : holdingsEditAsControls}
						size="small"
						variant="ghost"
						disabled={model.busy || !model.loaded}
						onClick={mode === "controls" ? showText : showControls}
					/>
				</div>
				{mode === "text"
					? (
						<textarea
							id="opsCapabilitySet"
							className="field capability-set-text"
							rows={6}
							value={text}
							disabled={model.busy || !model.loaded}
							aria-labelledby="opsCapabilitySetLabel"
							aria-invalid={model.errors.length > 0 || undefined}
							onChange={(event) => {
								setText(event.currentTarget.value);
								model.setError("");
							}}
							placeholder={capabilitySetPlaceholder}
							spellCheck={false}
						/>
					)
					: (
						<div className="capability-set-controls" aria-labelledby="opsCapabilitySetLabel">
							{OPS_BUNDLE_CAPABILITIES.map(({ capability }) => {
								const enabled = model.draft.has(capability);
								const face = OPS_CATALOG[capability];
								return (
									<div className="capability-set-row" key={capability}>
										<div className="switch-row">
											<div className="capability-set-label">
												<p className="group-label" id={`opsCapabilitySet-${capability}-label`}>
													{face.label}
												</p>
												<span className="capability-set-edit-slot">
													{enabled && (
														<IconButton
															icon="pencil"
															label={capabilitySetEditSwiss(face.label)}
															size="small"
															variant="ghost"
															onClick={() => model.edit(capability)}
														/>
													)}
												</span>
											</div>
											<Switch
												id={face.toggleId}
												checked={enabled}
												label={capabilitySetInclude(face.label)}
												aria-labelledby={`opsCapabilitySet-${capability}-label`}
												disabled={model.busy || !model.loaded}
												onClick={() => {
													if (!enabled) {
														model.edit(capability);
														return;
													}
													const next = new Map(model.draft);
													next.delete(capability);
													model.setDraft(next);
													model.setError("");
												}}
											/>
										</div>
									</div>
								);
							})}
						</div>
					)}
				<div className="actions">
					<Button
						id="opsCapabilitySetDiscard"
						type="button"
						variant="quiet"
						disabled={!dirty || model.busy}
						onClick={model.discard}
					>
						Discard
					</Button>
					<Button
						id="opsCapabilitySetSave"
						type="submit"
						busy={model.busy}
						disabled={!actionable || model.busy}
					>
						{!dirty && model.retryPending ? capabilitySetRetry : capabilitySetSave}
					</Button>
				</div>
				{model.notice !== "" && <Said id="opsCapabilitySetSaved" kind="success">{model.notice}</Said>}
				{model.errors.length > 0 && (
					<div className="capability-set-errors">
						{model.errors.map((error) => <Said key={error} kind="failure">{error}</Said>)}
					</div>
				)}
			</form>
			<CapabilityValueEditor />
		</>
	);
}
