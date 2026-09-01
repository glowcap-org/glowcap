// One Rooms member's own identity on a bridged service, drawn from the
// bridge's declared form.
//
// The bridge says what it needs and Rooms decides what that looks like, so
// nothing here knows any service's fields or states. The form is asked for
// when the surface opens and again when the seat moves, because a form is
// declared for the state its bridge is in now. Credentials never enter the
// composer or browser store: a secret field is cleared before the room ask
// starts, and the promise under it is Rooms' own, not the bridge's to word.

import { useEffect, useRef, useState } from "react";
import { Button, type ButtonVariant } from "./Button.tsx";
import { Checkbox } from "./Checkbox.tsx";
import { Field } from "./Field.tsx";
import { identifierField } from "./field.ts";
import { useRoomsSession } from "./controller/session.ts";
import { Said } from "./Said.tsx";
import {
	type BridgeAction,
	type BridgeForm,
	bridgeFormFields,
	bridgeFormSubmission,
	type BridgeSecretField,
	type BridgeTextField,
} from "../../lib/bridge/form.ts";
import type { RoomConv } from "./types.ts";

const SECRET_PROMISE = "Sent once, cleared here immediately, and never remembered.";

function fieldId(id: string): string {
	return `convcardBridge-${id}`;
}

function LeafField(
	{ field, value, off, onChange }: {
		field: BridgeTextField | BridgeSecretField;
		value: string;
		off: boolean;
		onChange: (value: string) => void;
	},
) {
	const secret = field.kind === "secret";
	const hint = secret ? (field.hint == null ? SECRET_PROMISE : `${field.hint} ${SECRET_PROMISE}`) : field.hint;
	return (
		<Field id={fieldId(field.id)} label={field.label} hint={hint}>
			{(wiring) => (
				<input
					id={wiring.id}
					className="field"
					name={fieldId(field.id)}
					type={secret ? "password" : "text"}
					value={value}
					disabled={off}
					{...identifierField}
					aria-describedby={wiring.describedBy}
					onChange={(event) => onChange(event.currentTarget.value)}
				/>
			)}
		</Field>
	);
}

export function BridgeIdentityForm(
	{ conv, connected, stateKey }: { conv: RoomConv; connected: boolean; stateKey: string },
) {
	const session = useRoomsSession();
	const [form, setForm] = useState<BridgeForm | null>(null);
	const [values, setValues] = useState<Record<string, string>>({});
	const [toggles, setToggles] = useState<ReadonlySet<string>>(new Set());
	const [working, setWorking] = useState<string | null>(null);
	const [why, setWhy] = useState("");
	// A superseded promise no longer owns this form. Fetches and acts carry
	// separate tokens: a seat change refetching the form must not steal an
	// in-flight act's right to clear its own busy state.
	const fetchRequest = useRef(0);
	const actRequest = useRef(0);

	useEffect(() => {
		const own = ++fetchRequest.current;
		void session.bridgeForm(conv.key).then((declared) => {
			if (fetchRequest.current !== own || declared == null) return;
			setForm(declared);
			// The bridge fills what it already knows, so a reader corrects
			// rather than retypes; what the reader is mid-typing stays theirs.
			// A secret field never carries a starting value by declaration.
			setValues((current) => {
				const next = { ...current };
				for (const field of bridgeFormFields(declared)) {
					if (field.kind === "text" && field.value != null && (next[field.id] ?? "") === "") {
						next[field.id] = field.value;
					}
				}
				return next;
			});
			setToggles((current) => {
				const next = new Set(current);
				for (const field of declared.fields) {
					if (field.kind === "toggle" && field.on) next.add(field.id);
				}
				return next;
			});
		}).catch((error) => {
			if (fetchRequest.current === own) setWhy(error instanceof Error ? error.message : String(error));
		});
	}, [session, conv.key, stateKey]);

	if (form == null) {
		return why === "" ? null : <Said id="convcardBridgeWhy" kind="failure">{why}</Said>;
	}
	const off = !connected || working !== null;
	const requiredMissing = bridgeFormFields(form).some((field) => {
		if (field.kind === "toggle" || !field.required) return false;
		const revealedBy = form.fields.find((toggle) =>
			toggle.kind === "toggle" && toggle.reveals.some((leaf) => leaf.id === field.id)
		);
		if (revealedBy != null && !toggles.has(revealedBy.id)) return false;
		return (values[field.id] ?? "") === "";
	});

	const act = (action: BridgeAction) => {
		const own = ++actRequest.current;
		const submission = bridgeFormSubmission(form, action, values, toggles);
		// Whatever the outcome, a typed secret does not outlive the press.
		setValues((current) => {
			const next = { ...current };
			for (const field of bridgeFormFields(form)) {
				if (field.kind === "secret") delete next[field.id];
			}
			return next;
		});
		if ("why" in submission) {
			setWhy(submission.why);
			return;
		}
		setWorking(action.id);
		setWhy("");
		void session.submitBridgeForm(conv.key, form.scope, action.id, submission.answers, submission.secrets)
			.then((refused) => {
				if (actRequest.current === own) setWhy(refused);
			})
			.finally(() => {
				if (actRequest.current === own) setWorking(null);
			});
	};

	const primary = form.actions.find((action) => action.tone === "primary");
	return (
		<div className="group well" role="group" aria-label={form.title}>
			<p className="group-label">{form.title}</p>
			<p className="hint" id="convcardBridgeState">{form.said}</p>
			<form
				className="group"
				aria-busy={working !== null}
				onSubmit={(event) => {
					event.preventDefault();
					if (primary == null || off || requiredMissing) return;
					act(primary);
				}}
			>
				{form.fields.map((field) =>
					field.kind === "toggle"
						? (
							<div key={field.id} className="group">
								<label className="check-row">
									<Checkbox
										id={fieldId(field.id)}
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
										field={leaf}
										value={values[leaf.id] ?? ""}
										off={off}
										onChange={(value) => setValues((current) => ({ ...current, [leaf.id]: value }))}
									/>
								))}
							</div>
						)
						: (
							<LeafField
								key={field.id}
								field={field}
								value={values[field.id] ?? ""}
								off={off}
								onChange={(value) => setValues((current) => ({ ...current, [field.id]: value }))}
							/>
						)
				)}
				<div className="actions">
					{form.actions.map((action) => (
						<Button
							key={action.id}
							id={`convcardBridgeAct-${action.id}`}
							type={action.tone === "primary" ? "submit" : "button"}
							variant={action.tone as ButtonVariant}
							busy={working === action.id}
							disabled={action.tone === "primary"
								? !connected || working !== null || requiredMissing
								: !connected || working !== null}
							onClick={action.tone === "primary" ? undefined : () => act(action)}
						>
							{working === action.id ? action.busyLabel : action.label}
						</Button>
					))}
				</div>
				{why !== "" || conv.bridgeIssue !== ""
					? <Said id="convcardBridgeWhy" kind="failure">{why !== "" ? why : conv.bridgeIssue}</Said>
					: null}
			</form>
		</div>
	);
}
