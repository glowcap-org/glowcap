// Draw one declared bridge form and hand its submission back.
//
// This is the rendering core an identity form and a gateway's connection and
// lease forms all share: a bridge declares fields and actions, and this draws
// them and splits a submission by the form's own declaration. It knows no
// service. The owner decides what a pressed action does; this only collects
// what a reader typed and refuses a required field left empty.

import { type ReactNode, useEffect, useRef, useState } from "react";
import { Button, type ButtonVariant } from "./Button.tsx";
import { Checkbox } from "./Checkbox.tsx";
import { Confirm } from "./Confirm.tsx";
import { Field } from "./Field.tsx";
import { identifierField } from "./field.ts";
import { Said } from "./Said.tsx";
import { Switch } from "./Switch.tsx";
import {
	type BridgeAction,
	type BridgeField,
	type BridgeForm,
	bridgeFormFields,
	bridgeFormSubmission,
	type BridgeSecretField,
	type BridgeTextField,
	type BridgeToggleField,
} from "../../lib/bridge/form.ts";

const SECRET_PROMISE = "Sent once, cleared here immediately, and never remembered.";

function prefixed(prefix: string | undefined, input: ReactNode): ReactNode {
	if (prefix == null) return input;
	return (
		<div className="field-prefixed">
			<span aria-hidden="true">{prefix}</span>
			{input}
		</div>
	);
}

function LeafField(
	{ idPrefix, field, value, off, bare = false, onChange }: {
		idPrefix: string;
		field: BridgeTextField | BridgeSecretField;
		value: string;
		off: boolean;
		/** Draw only the control, its label carried by the row it sits in. For a
		 * one-line form (a lease's channel beside its Join) a stacked label would
		 * be a second line the row exists to avoid. */
		bare?: boolean;
		onChange: (value: string) => void;
	},
) {
	const secret = field.kind === "secret";
	const hint = secret ? (field.hint == null ? SECRET_PROMISE : `${field.hint} ${SECRET_PROMISE}`) : field.hint;
	const prefix = field.kind === "text" ? field.prefix : undefined;
	const control = (id: string, describedBy?: string) => (
		<input
			id={id}
			className="field"
			name={`${idPrefix}-${field.id}`}
			type={secret ? "password" : "text"}
			value={value}
			placeholder={field.placeholder}
			disabled={off}
			{...identifierField}
			aria-label={bare ? field.label : undefined}
			aria-describedby={describedBy}
			onChange={(event) => onChange(event.currentTarget.value)}
		/>
	);
	if (bare) return prefixed(prefix, control(`${idPrefix}-${field.id}`));
	return (
		<Field id={`${idPrefix}-${field.id}`} label={field.label} hint={hint}>
			{(wiring) => prefixed(prefix, control(wiring.id, wiring.describedBy))}
		</Field>
	);
}

/** Render `form` and call `onAct` with the pressed action's split submission.
 * `idPrefix` namespaces the field dom ids so more than one form can share a
 * surface. `onAct` resolves with a refusal to show, or "" when it succeeded.
 * An action declaring `confirm` opens its second step before it runs, whatever
 * its tone: the declaration decides, not the button that carried it. */
export function BridgeFormView(
	{ form, idPrefix, connected, resetOnDone = false, layout = "stack", standingIssue = "", onAct }: {
		form: BridgeForm;
		idPrefix: string;
		connected: boolean;
		/** Clear the fields after an action that succeeds, for a form that opens
		 * something new rather than editing a standing identity. */
		resetOnDone?: boolean;
		/** How the form is laid out. A wide surface (the operations pane's
		 * connection form) packs its fields into a `grid` with a footer; a short
		 * one-field-and-act form (a lease's channel beside Join) is a single `row`;
		 * everything else `stack`s. It is where the form is drawn, not what it asks,
		 * so it is the caller's choice rather than the bridge's. */
		layout?: "stack" | "grid" | "row";
		/** A failure the owner already knows about (a bridge link that dropped),
		 * shown in the form's own refusal line while no act has one of its own. */
		standingIssue?: string;
		onAct: (action: string, answers: Record<string, string>, secrets: Record<string, string>) => Promise<string>;
	},
) {
	const [values, setValues] = useState<Record<string, string>>(() => {
		const initial: Record<string, string> = {};
		for (const field of bridgeFormFields(form)) {
			if (field.kind === "text" && field.value != null) initial[field.id] = field.value;
		}
		return initial;
	});
	const [toggles, setToggles] = useState<ReadonlySet<string>>(() => {
		const on = new Set<string>();
		for (const field of form.fields) if (field.kind === "toggle" && field.on) on.add(field.id);
		return on;
	});
	const [working, setWorking] = useState<string | null>(null);
	const [confirming, setConfirming] = useState<string | null>(null);
	const [why, setWhy] = useState("");
	const request = useRef(0);

	// A newly declared form re-seeds what the bridge already knows and drops a
	// half-finished confirmation from the last state, while what the reader is
	// mid-typing stays theirs. Owners re-fetch a form when its state moves (a
	// seat change, a snapshot refresh), so sameness is judged by content: a
	// fresh object carrying the same declaration is the same form, and the
	// comparison runs only when the object changes, never per keystroke.
	const seeded = useRef<string | null>(null);
	useEffect(() => {
		const declared = JSON.stringify(form);
		if (seeded.current === declared) return;
		const first = seeded.current === null;
		seeded.current = declared;
		// The state initializers already seeded the mount's own form.
		if (first) return;
		setConfirming(null);
		setValues((current) => {
			const next = { ...current };
			for (const field of bridgeFormFields(form)) {
				if (field.kind === "text" && field.value != null && (next[field.id] ?? "") === "") {
					next[field.id] = field.value;
				}
			}
			return next;
		});
		setToggles((current) => {
			const next = new Set(current);
			for (const field of form.fields) if (field.kind === "toggle" && field.on) next.add(field.id);
			return next;
		});
	}, [form]);

	const off = !connected || working !== null;
	const requiredMissing = bridgeFormFields(form).some((field) => {
		if (field.kind === "toggle" || !field.required) return false;
		const revealedBy = form.fields.find((toggle) =>
			toggle.kind === "toggle" && toggle.reveals.some((leaf) => leaf.id === field.id)
		);
		if (revealedBy != null && !toggles.has(revealedBy.id)) return false;
		return (values[field.id] ?? "") === "";
	});

	const clearSecrets = () =>
		setValues((current) => {
			const next = { ...current };
			for (const field of bridgeFormFields(form)) if (field.kind === "secret") delete next[field.id];
			return next;
		});

	const act = (action: BridgeAction) => {
		const own = ++request.current;
		setConfirming(null);
		const submission = bridgeFormSubmission(form, action, values, toggles);
		clearSecrets();
		if ("why" in submission) {
			setWhy(submission.why);
			return;
		}
		setWorking(action.id);
		setWhy("");
		void onAct(action.id, submission.answers, submission.secrets)
			.then((refused) => {
				if (request.current !== own) return;
				setWhy(refused);
				if (refused === "" && resetOnDone) {
					setValues({});
					setToggles(() => {
						const on = new Set<string>();
						for (const field of form.fields) if (field.kind === "toggle" && field.on) on.add(field.id);
						return on;
					});
				}
			})
			.finally(() => {
				if (request.current === own) setWorking(null);
			});
	};

	const primary = form.actions.find((action) => action.tone === "primary");
	// The declaration decides whether an act runs now or opens its second step;
	// the tone only picks the button, so Enter on a confirmed primary confirms.
	const press = (action: BridgeAction) => {
		if (action.confirm != null) setConfirming(action.id);
		else act(action);
	};
	const renderToggle = (field: BridgeToggleField) => (
		<div key={field.id} className="group">
			<label className="check-row">
				<Checkbox
					id={`${idPrefix}-${field.id}`}
					checked={toggles.has(field.id)}
					disabled={off}
					onChange={(event) => {
						const on = event.target.checked;
						setToggles((current) => {
							const next = new Set(current);
							if (on) next.add(field.id);
							else next.delete(field.id);
							return next;
						});
					}}
				/>
				<span>{field.label}</span>
			</label>
			{toggles.has(field.id) && field.reveals.map((leaf) => (
				<LeafField
					key={leaf.id}
					idPrefix={idPrefix}
					field={leaf}
					value={values[leaf.id] ?? ""}
					off={off}
					onChange={(value) => setValues((current) => ({ ...current, [leaf.id]: value }))}
				/>
			))}
		</div>
	);
	const renderLeaf = (field: BridgeTextField | BridgeSecretField) => (
		<LeafField
			key={field.id}
			idPrefix={idPrefix}
			field={field}
			value={values[field.id] ?? ""}
			off={off}
			bare={layout === "row"}
			onChange={(value) => setValues((current) => ({ ...current, [field.id]: value }))}
		/>
	);
	const pending = form.actions.find((action) => action.id === confirming && action.confirm != null);
	const actions = pending?.confirm != null
		? (
			<Confirm
				label={pending.label}
				say={pending.confirm.say}
				keep={pending.confirm.keep}
				commit={pending.confirm.commit}
				busy={working === pending.id}
				commitId={`${idPrefix}Confirm-${pending.id}`}
				onKeep={() => setConfirming(null)}
				onCommit={() => act(pending)}
			/>
		)
		: (
			<div className="actions">
				{form.actions.map((action) => (
					<Button
						key={action.id}
						id={`${idPrefix}Act-${action.id}`}
						type={action.tone === "primary" ? "submit" : "button"}
						variant={action.tone as ButtonVariant}
						busy={working === action.id}
						disabled={action.tone === "primary"
							? !connected || working !== null || requiredMissing
							: !connected || working !== null}
						onClick={action.tone === "primary" ? undefined : () => press(action)}
					>
						{working === action.id ? action.busyLabel : action.label}
					</Button>
				))}
			</div>
		);
	// On a wide grid a reveal-less toggle is a footer control beside the action,
	// the way IRC's TLS sat next to Open connection, not a field floating on its
	// own line. A disclosure toggle keeps its place in the field flow so its
	// revealed fields follow it.
	const inFooter = (field: BridgeField): boolean =>
		layout === "grid" && field.kind === "toggle" && field.reveals.length === 0;
	const footerToggles = form.fields.filter(inFooter);
	return (
		<form
			className={layout === "grid" ? "group bridge-form-grid" : layout === "row" ? "bridge-form-row" : "group"}
			aria-busy={working !== null}
			aria-label={form.title}
			onSubmit={(event) => {
				event.preventDefault();
				if (primary == null || off || requiredMissing) return;
				press(primary);
			}}
		>
			{form.fields.map((field) =>
				inFooter(field) ? null : field.kind === "toggle" ? renderToggle(field) : renderLeaf(field)
			)}
			{footerToggles.length > 0
				? (
					<div className="bridge-form-foot">
						{footerToggles.map((field) => (
							<div key={field.id} className="switch-row">
								<p className="group-label" id={`${idPrefix}-${field.id}-label`}>{field.label}</p>
								<Switch
									id={`${idPrefix}-${field.id}`}
									checked={toggles.has(field.id)}
									label={field.label}
									aria-labelledby={`${idPrefix}-${field.id}-label`}
									disabled={off}
									onClick={() =>
										setToggles((current) => {
											const next = new Set(current);
											if (next.has(field.id)) next.delete(field.id);
											else next.add(field.id);
											return next;
										})}
								/>
							</div>
						))}
						{form.said !== "" && <p className="hint">{form.said}</p>}
						{actions}
					</div>
				)
				: actions}
			{(why !== "" || standingIssue !== "") && (
				<Said id={`${idPrefix}Why`} kind="failure">{why !== "" ? why : standingIssue}</Said>
			)}
		</form>
	);
}
