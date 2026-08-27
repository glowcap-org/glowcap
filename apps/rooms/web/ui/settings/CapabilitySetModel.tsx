import { createContext, type ReactNode, useContext, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { ModalHead } from "../ModalHead.tsx";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { OPS_CATALOG } from "../ops/catalog.ts";
import { formatOpsBundle, type OpsBundleDraft, opsBundleReady, parseOpsBundleDraft } from "../ops/bundle.ts";
import { useRoomsSession } from "../controller/session.ts";
import type { OpsCap } from "../types.ts";
import { onCapabilitySetChanged } from "../ops/capability_set_events.ts";

interface CapabilitySetModel {
	readonly draft: OpsBundleDraft;
	readonly savedBundle: string;
	/** The set as it stands in the editor, whichever face is showing. */
	readonly currentBundle: string;
	/** The editor holds changes the server has not been told about. Settings
	 * reads this to ask before closing over them. */
	readonly dirty: boolean;
	/** Switches and their swiss numbers, or the whole set as text. Held here
	 * rather than in the form so a tab change does not throw away an edit. */
	readonly mode: "controls" | "text";
	readonly text: string;
	readonly loaded: boolean;
	readonly busy: boolean;
	readonly errors: readonly string[];
	readonly notice: string;
	readonly retryPending: boolean;
	readonly editing: OpsCap | null;
	readonly modalLayer: boolean;
	setDraft(draft: OpsBundleDraft): void;
	setError(error: string): void;
	edit(capability: OpsCap): void;
	setMode(mode: "controls" | "text"): void;
	setText(text: string): void;
	commit(draft: OpsBundleDraft): Promise<void>;
}

const CapabilitySetContext = createContext<CapabilitySetModel | null>(null);

export function useCapabilitySetModel(): CapabilitySetModel {
	const model = useContext(CapabilitySetContext);
	if (model == null) throw new Error("the capability-set editor is outside its owner");
	return model;
}

export function CapabilitySetProvider({ children }: { children: ReactNode }) {
	const session = useRoomsSession();
	const [draft, setDraftState] = useState<OpsBundleDraft>(() => new Map());
	const [savedBundle, setSavedBundle] = useState("");
	const [loaded, setLoaded] = useState(false);
	const [busy, setBusy] = useState(false);
	const [errors, setErrors] = useState<string[]>([]);
	const [notice, setNotice] = useState("");
	const [retryPending, setRetryPending] = useState(false);
	const [editing, setEditing] = useState<OpsCap | null>(null);
	const [mode, setMode] = useState<"controls" | "text">("controls");
	const [text, setText] = useState("");
	const [modalLayer, setModalLayer] = useState(false);
	const latest = useRef({ draft, savedBundle });
	latest.current = { draft, savedBundle };

	useEffect(() => {
		let current = true;
		const load = (refresh: boolean) =>
			session.readOpsBundle().then((bundle) => {
				if (!current) return;
				const prior = latest.current;
				const dirty = formatOpsBundle(prior.draft) !== prior.savedBundle;
				if (!refresh || !dirty) {
					setDraftState(parseOpsBundleDraft(bundle));
					setErrors([]);
				}
				setSavedBundle(bundle);
				if (refresh && dirty) setNotice("The saved capability set changed. Your unsaved edits are still here.");
				setLoaded(true);
			}, (cause) => {
				if (!current) return;
				setErrors([cause instanceof Error ? cause.message : String(cause)]);
				setLoaded(true);
			});
		void load(false);
		const stop = onCapabilitySetChanged(() => load(true));
		return () => {
			current = false;
			stop();
		};
	}, [session]);

	// The text face mirrors the switches while the switches are showing, and
	// takes the saved set again once a save has gone through under it.
	useEffect(() => {
		if (mode === "controls") setText(formatOpsBundle(draft));
	}, [mode, draft]);
	useEffect(() => {
		if (mode === "text" && notice !== "") setText(savedBundle);
	}, [mode, notice, savedBundle]);

	let currentBundle = formatOpsBundle(draft);
	if (mode === "text") {
		try {
			currentBundle = formatOpsBundle(parseOpsBundleDraft(text));
		} catch {
			currentBundle = text;
		}
	}

	const model: CapabilitySetModel = {
		draft,
		savedBundle,
		currentBundle,
		dirty: loaded && currentBundle !== savedBundle,
		mode,
		text,
		setMode,
		setText,
		loaded,
		busy,
		errors,
		notice,
		retryPending,
		editing,
		modalLayer,
		setDraft: (next) => {
			setDraftState(next);
			setErrors([]);
			setNotice("");
		},
		setError: (message) => {
			setErrors(message === "" ? [] : [message]);
			if (message === "") setNotice("");
		},
		edit: (capability) => {
			setErrors([]);
			setNotice("");
			setEditing(capability);
		},
		commit: async (wanted) => {
			setBusy(true);
			setErrors([]);
			setNotice("");
			setRetryPending(false);
			try {
				const requested = formatOpsBundle(wanted);
				const result = await session.replaceOpsBundle(requested);
				setDraftState(parseOpsBundleDraft(result.bundle));
				setSavedBundle(result.bundle);
				setErrors(
					result.failures.map(({ capability, reason }) =>
						capability == null ? reason : `${OPS_CATALOG[capability].label}: ${reason}`
					),
				);
				setRetryPending(result.bundle === requested && result.failures.length > 0);
				if (result.bundle === requested && result.failures.length === 0) setNotice("Capability set saved.");
			} catch (cause) {
				setErrors([cause instanceof Error ? cause.message : String(cause)]);
			} finally {
				setBusy(false);
			}
		},
	};

	return (
		<CapabilitySetContext.Provider value={model}>
			{children}
			<CapabilityValueModal
				capability={editing}
				draft={draft}
				onClose={() => setEditing(null)}
				onSave={(capability, swiss) => {
					const next = new Map(draft);
					next.set(capability, swiss);
					setDraftState(next);
					setEditing(null);
					setErrors([]);
					setNotice("");
				}}
				onLayer={setModalLayer}
			/>
		</CapabilitySetContext.Provider>
	);
}

function CapabilityValueModal(
	{ capability, draft, onClose, onSave, onLayer }: {
		capability: OpsCap | null;
		draft: OpsBundleDraft;
		onClose(): void;
		onSave(capability: OpsCap, swiss: string): void;
		onLayer(held: boolean): void;
	},
) {
	const open = capability != null;
	const [showing, setShowing] = useState<OpsCap>(capability ?? "listeners");
	const [swiss, setSwiss] = useState("");
	const [why, setWhy] = useState("");
	const dialog = useRef<HTMLDialogElement>(null);
	const field = useRef<HTMLInputElement>(null);
	const { held, onExited } = useHeldModal(open);
	useLayoutEffect(() => {
		onLayer(held);
		return () => onLayer(false);
	}, [held, onLayer]);
	useLayoutEffect(() => {
		if (capability == null) return;
		setShowing(capability);
		setSwiss(draft.get(capability) ?? "");
		setWhy("");
	}, [capability, draft]);
	useModalDialog(dialog, onClose, field, open, onExited);
	if (!held) return null;
	const face = OPS_CATALOG[showing];
	const save = () => {
		if (!opsBundleReady(new Map([[showing, swiss]]))) {
			setWhy("Enter the exact bare swiss number the server printed.");
			return;
		}
		onSave(showing, swiss);
	};
	return (
		<dialog ref={dialog} className="modal" aria-labelledby="capabilityValueTitle">
			<form
				className="modal-card card-plane"
				onSubmit={(event) => {
					event.preventDefault();
					save();
				}}
			>
				<ModalHead
					titleId="capabilityValueTitle"
					title={face.label}
					closeId="capabilityValueClose"
					onClose={onClose}
				/>
				<p className="lead">{face.lead}</p>
				<div className="group well">
					<Field
						id="capabilityValueSwiss"
						label="Swiss number"
						hint={
							<>
								The server mints it with <code>{face.flag}</code>. {face.how}{" "}
								It is bearer authority and is kept in the Rooms state bundle.
							</>
						}
						said={why}
					>
						{(wiring) => (
							<input
								ref={field}
								id={wiring.id}
								className="field"
								value={swiss}
								{...identifierField}
								aria-describedby={wiring.describedBy}
								aria-invalid={wiring.invalid}
								onChange={(event) => {
									setSwiss(event.currentTarget.value);
									setWhy("");
								}}
							/>
						)}
					</Field>
				</div>
				<div className="actions" data-fill>
					<Button type="submit" size="large">Save to capability set</Button>
				</div>
			</form>
		</dialog>
	);
}
