import { createContext, type ReactNode, useContext, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
	capabilitySetMintedSaid,
	capabilitySetSaveTo,
	capabilitySetSwissRefused,
	capabilitySwissLabel,
} from "../../../lib/text/settings.ts";
import { holdingsSetChanged, holdingsSetSaved } from "../../../lib/text/ops.ts";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { ModalHead } from "../ModalHead.tsx";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { OPS_CATALOG } from "../ops/catalog.ts";
import { formatOpsBundle, type OpsBundleDraft, opsBundleReady, parseOpsBundleDraft } from "../ops/bundle.ts";
import { useRoomsSession } from "../controller/session.ts";
import type { OpsCap } from "../types.ts";
import { useChangeGroup, useCommitments } from "../commitment.tsx";

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
	/** The capability whose swiss number is being entered, held here so the
	 * value card survives a tab change; `CapabilityValueEditor` draws it. */
	readonly editing: OpsCap | null;
	setDraft(draft: OpsBundleDraft): void;
	setError(error: string): void;
	edit(capability: OpsCap): void;
	stopEditing(): void;
	saveValue(capability: OpsCap, swiss: string): void;
	setMode(mode: "controls" | "text"): void;
	setText(text: string): void;
	discard(): void;
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
	const latest = useRef({ draft, savedBundle });
	const loadGeneration = useRef(0);
	const committing = useRef(false);
	const commitWork = useRef<Promise<void> | null>(null);
	const commitBarrier = useRef<PromiseWithResolvers<void> | null>(null);
	const commitFinished = useRef(false);
	latest.current = { draft, savedBundle };

	useEffect(() => {
		let current = true;
		const load = (refresh: boolean) => {
			const generation = ++loadGeneration.current;
			return session.readOpsBundle().then((bundle) => {
				if (!current || generation !== loadGeneration.current) return;
				const prior = latest.current;
				const dirty = formatOpsBundle(prior.draft) !== prior.savedBundle;
				if (!refresh || !dirty) {
					setDraftState(parseOpsBundleDraft(bundle));
					setErrors([]);
				}
				setSavedBundle(bundle);
				if (refresh && dirty) setNotice(holdingsSetChanged);
				setLoaded(true);
			}, (cause) => {
				if (!current || generation !== loadGeneration.current) return;
				setErrors([cause instanceof Error ? cause.message : String(cause)]);
				setLoaded(true);
			});
		};
		void load(false);
		// The explicit commit below owns its returned snapshot. Its own change
		// notification can arrive before that outcome and must not publish a
		// competing "saved bundle changed" notice over a partial refusal.
		const stop = session.watchOpsBundle(() => committing.current ? undefined : load(true));
		return () => {
			current = false;
			loadGeneration.current += 1;
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
	const discard = () => {
		if (committing.current) throw new Error("Wait for the capability set to finish saving.");
		setDraftState(parseOpsBundleDraft(savedBundle));
		setText(savedBundle);
		setMode("controls");
		setErrors([]);
		setNotice("");
		setRetryPending(false);
	};
	const dirty = loaded && currentBundle !== savedBundle;
	useLayoutEffect(() => {
		if (busy || !commitFinished.current || commitBarrier.current == null) return;
		commitFinished.current = false;
		commitWork.current = null;
		commitBarrier.current.resolve();
		commitBarrier.current = null;
	}, [busy, dirty, errors, notice]);
	useChangeGroup("settings-capability-set", {
		dirty,
		discard,
		settling: () => commitBarrier.current?.promise ?? null,
	});

	const model: CapabilitySetModel = {
		draft,
		savedBundle,
		currentBundle,
		dirty,
		mode,
		text,
		setMode,
		setText: (value) => {
			setText(value);
			setRetryPending(false);
		},
		discard,
		loaded,
		busy,
		errors,
		notice,
		retryPending,
		editing,
		setDraft: (next) => {
			setDraftState(next);
			setRetryPending(false);
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
		stopEditing: () => setEditing(null),
		saveValue: (capability, swiss) => {
			const next = new Map(draft);
			next.set(capability, swiss);
			setDraftState(next);
			setRetryPending(false);
			setEditing(null);
			setErrors([]);
			setNotice("");
		},
		commit: async (wanted) => {
			if (commitWork.current != null) return await commitWork.current;
			committing.current = true;
			commitFinished.current = false;
			commitBarrier.current = Promise.withResolvers<void>();
			loadGeneration.current += 1;
			setBusy(true);
			setErrors([]);
			setNotice("");
			setRetryPending(false);
			const work = (async () => {
				try {
					const requested = formatOpsBundle(wanted);
					const result = await session.replaceOpsBundle(requested);
					// A refused atomic replacement keeps the requested draft for
					// repair. Only its returned committed bundle becomes baseline.
					setDraftState(result.failures.length === 0 ? parseOpsBundleDraft(result.bundle) : wanted);
					setSavedBundle(result.bundle);
					setErrors(
						result.failures.map(({ capability, reason }) =>
							capability == null ? reason : `${OPS_CATALOG[capability].label}: ${reason}`
						),
					);
					setRetryPending(result.failures.length > 0);
					if (result.bundle === requested && result.failures.length === 0) setNotice(holdingsSetSaved);
				} catch (cause) {
					setErrors([cause instanceof Error ? cause.message : String(cause)]);
				} finally {
					committing.current = false;
					commitFinished.current = true;
					setBusy(false);
				}
			})();
			commitWork.current = work;
			await work;
		},
	};

	return (
		<CapabilitySetContext.Provider value={model}>
			{children}
		</CapabilitySetContext.Provider>
	);
}

/** The card for one capability's swiss number. Drawn inside Settings, beside
 * the form that opens it, so it stacks over Settings the way the other
 * settings cards do instead of standing in its place. */
export function CapabilityValueEditor() {
	const model = useCapabilitySetModel();
	return (
		<CapabilityValueModal
			capability={model.editing}
			draft={model.draft}
			onClose={model.stopEditing}
			onSave={model.saveValue}
		/>
	);
}

function CapabilityValueModal(
	{ capability, draft, onClose, onSave }: {
		capability: OpsCap | null;
		draft: OpsBundleDraft;
		onClose(): void;
		onSave(capability: OpsCap, swiss: string): void;
	},
) {
	const commitments = useCommitments();
	const open = capability != null;
	const [showing, setShowing] = useState<OpsCap>(capability ?? "listeners");
	const [swiss, setSwiss] = useState("");
	const [why, setWhy] = useState("");
	const dialog = useRef<HTMLDialogElement>(null);
	const field = useRef<HTMLInputElement>(null);
	const { held, onExited } = useHeldModal(open);
	useLayoutEffect(() => {
		if (capability == null) return;
		setShowing(capability);
		setSwiss(draft.get(capability) ?? "");
		setWhy("");
	}, [capability, draft]);
	useChangeGroup("settings-capability-value", {
		dirty: open && swiss !== (draft.get(showing) ?? ""),
		discard: () => {
			setSwiss(draft.get(showing) ?? "");
			setWhy("");
		},
	});
	const requestClose = () => commitments.request(onClose, { only: ["settings-capability-value"] });
	useModalDialog(dialog, requestClose, field, open, onExited);
	if (!held) return null;
	const face = OPS_CATALOG[showing];
	const save = () => {
		if (!opsBundleReady(new Map([[showing, swiss]]))) {
			setWhy(capabilitySetSwissRefused);
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
				<div className="modal-body">
					<ModalHead
						titleId="capabilityValueTitle"
						title={face.label}
						closeId="capabilityValueClose"
						onClose={requestClose}
					/>
					<p className="lead">{face.lead}</p>
					<div className="group well">
						<Field
							id="capabilityValueSwiss"
							label={capabilitySwissLabel}
							hint={capabilitySetMintedSaid(face.flag, face.how)}
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
						<Button type="submit" size="large">{capabilitySetSaveTo}</Button>
					</div>
				</div>
			</form>
		</dialog>
	);
}
