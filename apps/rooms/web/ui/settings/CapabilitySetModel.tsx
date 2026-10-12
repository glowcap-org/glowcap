import {
	createContext,
	type ReactNode,
	useContext,
	useEffect,
	useLayoutEffect,
	useReducer,
	useRef,
	useState,
} from "react";
import {
	capabilitySetMintedSaid,
	capabilitySetSaveTo,
	capabilitySetUriRefused,
	capabilityUriLabel,
} from "../../../lib/text/settings.ts";
import { holdingsSetChanged, holdingsSetSaved } from "../../../lib/text/ops.ts";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { ModalHead } from "../ModalHead.tsx";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { OPS_CATALOG } from "../ops/catalog.ts";
import { formatOpsBundle, type OpsBundleDraft, opsBundleReady, parseOpsBundleDraft } from "../ops/bundle.ts";
import { type RoomsSessionController, useRoomsSession } from "../controller/session.ts";
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
	/** Switches and their capability URIs, or the whole set as text. Held here
	 * rather than in the form so a tab change does not throw away an edit. */
	readonly mode: "controls" | "text";
	readonly text: string;
	readonly loaded: boolean;
	readonly busy: boolean;
	readonly errors: readonly string[];
	readonly notice: string;
	readonly retryPending: boolean;
	/** The capability whose URI is being entered, held here so the
	 * value card survives a tab change; `CapabilityValueEditor` draws it. */
	readonly editing: OpsCap | null;
	setDraft(draft: OpsBundleDraft): void;
	setError(error: string): void;
	edit(capability: OpsCap): void;
	stopEditing(): void;
	saveValue(capability: OpsCap, uri: string): void;
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

/** The editor's whole state. Every field moves only through `capabilitySetReducer`,
 * so a save cannot be busy with stale errors and the text face cannot show a
 * bundle the switches have left behind. */
type CapabilitySetState = {
	draft: OpsBundleDraft;
	savedBundle: string;
	loaded: boolean;
	busy: boolean;
	errors: readonly string[];
	notice: string;
	retryPending: boolean;
	editing: OpsCap | null;
	mode: "controls" | "text";
	text: string;
};

/** One transition of the editor. The reader's actions are verbs. The load
 * effect and the commit pipeline deliver outcomes. */
type CapabilitySetAction =
	| { kind: "bundle"; bundle: string; refresh: boolean }
	| { kind: "loadFailed"; message: string }
	| { kind: "mode"; mode: "controls" | "text" }
	| { kind: "text"; text: string }
	| { kind: "draft"; draft: OpsBundleDraft }
	| { kind: "error"; message: string }
	| { kind: "edit"; capability: OpsCap | null }
	| { kind: "stopEditing" }
	| { kind: "saveValue"; capability: OpsCap; uri: string }
	| { kind: "discard" }
	| { kind: "commitStarted" }
	| {
		kind: "commitSaved";
		result: Awaited<ReturnType<RoomsSessionController["replaceOpsBundle"]>>;
		wanted: OpsBundleDraft;
	}
	| { kind: "commitFailed"; message: string }
	| { kind: "commitSettled" };

const initialCapabilitySetState: CapabilitySetState = {
	draft: new Map(),
	savedBundle: "",
	loaded: false,
	busy: false,
	errors: [],
	notice: "",
	retryPending: false,
	editing: null,
	mode: "controls",
	text: "",
};

/** How the text face follows the rest. While the switches are showing, the
 * text face mirrors them. While the text face is showing, it takes the kept
 * set whenever one is announced over it: a save gone through, or a held set
 * that moved while the reader had unsaved work. */
function textFaceFollowing(
	state: CapabilitySetState,
	draft: OpsBundleDraft,
	notice: string,
	savedBundle: string,
): string {
	if (state.mode === "controls") return formatOpsBundle(draft);
	return notice !== "" ? savedBundle : state.text;
}

function capabilitySetReducer(state: CapabilitySetState, action: CapabilitySetAction): CapabilitySetState {
	switch (action.kind) {
		case "bundle": {
			// A delivered bundle becomes baseline. A background delivery keeps the
			// reader's unsaved draft and says the held set moved instead.
			const dirty = formatOpsBundle(state.draft) !== state.savedBundle;
			const adopt = !action.refresh || !dirty;
			const draft = adopt ? parseOpsBundleDraft(action.bundle) : state.draft;
			const notice = action.refresh && dirty ? holdingsSetChanged : state.notice;
			return {
				...state,
				draft,
				savedBundle: action.bundle,
				errors: adopt ? [] : state.errors,
				notice,
				text: textFaceFollowing(state, draft, notice, action.bundle),
				loaded: true,
			};
		}
		case "loadFailed":
			return { ...state, errors: [action.message], loaded: true };
		case "mode":
			return {
				...state,
				mode: action.mode,
				text: action.mode === "controls"
					? formatOpsBundle(state.draft)
					: state.notice !== ""
					? state.savedBundle
					: state.text,
			};
		case "text":
			return { ...state, text: action.text, retryPending: false };
		case "draft":
			return {
				...state,
				draft: action.draft,
				text: textFaceFollowing(state, action.draft, "", state.savedBundle),
				retryPending: false,
				errors: [],
				notice: "",
			};
		case "error":
			return {
				...state,
				errors: action.message === "" ? [] : [action.message],
				notice: action.message === "" ? "" : state.notice,
			};
		case "edit":
			return { ...state, errors: [], notice: "", editing: action.capability };
		case "stopEditing":
			return { ...state, editing: null };
		case "saveValue": {
			const draft = new Map(state.draft);
			draft.set(action.capability, action.uri);
			return {
				...state,
				draft,
				text: textFaceFollowing(state, draft, "", state.savedBundle),
				retryPending: false,
				editing: null,
				errors: [],
				notice: "",
			};
		}
		case "discard":
			return {
				...state,
				draft: parseOpsBundleDraft(state.savedBundle),
				text: state.savedBundle,
				mode: "controls",
				errors: [],
				notice: "",
				retryPending: false,
			};
		case "commitStarted":
			return { ...state, busy: true, errors: [], notice: "", retryPending: false };
		case "commitSaved": {
			// A refused atomic replacement keeps the requested draft for repair.
			// Only its returned committed bundle becomes baseline.
			const clean = action.result.bundle === formatOpsBundle(action.wanted) &&
				action.result.failures.length === 0;
			const draft = action.result.failures.length === 0
				? parseOpsBundleDraft(action.result.bundle)
				: action.wanted;
			const notice = clean ? holdingsSetSaved : state.notice;
			return {
				...state,
				draft,
				savedBundle: action.result.bundle,
				errors: action.result.failures.map(({ capability, reason }) =>
					capability == null ? reason : `${OPS_CATALOG[capability].label}: ${reason}`
				),
				retryPending: action.result.failures.length > 0,
				notice,
				text: textFaceFollowing(state, draft, notice, action.result.bundle),
			};
		}
		case "commitFailed":
			return { ...state, errors: [action.message] };
		case "commitSettled":
			return { ...state, busy: false };
	}
}

export function CapabilitySetProvider({ children }: { children: ReactNode }) {
	const session = useRoomsSession();
	const [state, dispatch] = useReducer(capabilitySetReducer, initialCapabilitySetState);
	const loadGeneration = useRef(0);
	const committing = useRef(false);
	const commitWork = useRef<Promise<void> | null>(null);
	const commitBarrier = useRef<PromiseWithResolvers<void> | null>(null);
	const commitFinished = useRef(false);

	useEffect(() => {
		let current = true;
		const load = (refresh: boolean) => {
			const generation = ++loadGeneration.current;
			return session.readOpsBundle().then((bundle) => {
				if (!current || generation !== loadGeneration.current) return;
				dispatch({ kind: "bundle", bundle, refresh });
			}, (cause) => {
				if (!current || generation !== loadGeneration.current) return;
				dispatch({ kind: "loadFailed", message: cause instanceof Error ? cause.message : String(cause) });
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

	let currentBundle = formatOpsBundle(state.draft);
	if (state.mode === "text") {
		try {
			currentBundle = formatOpsBundle(parseOpsBundleDraft(state.text));
		} catch {
			currentBundle = state.text;
		}
	}
	const dirty = state.loaded && currentBundle !== state.savedBundle;
	const discard = () => {
		if (committing.current) throw new Error("Wait for the capability set to finish saving.");
		dispatch({ kind: "discard" });
	};
	// After a commit's final state lands, release the change group's settle.
	// `busy` falling is that render: the settled transition carries every
	// result field, so nothing arrives later that the group should wait for.
	useLayoutEffect(() => {
		if (state.busy || !commitFinished.current || commitBarrier.current == null) return;
		commitFinished.current = false;
		commitWork.current = null;
		commitBarrier.current.resolve();
		commitBarrier.current = null;
	}, [state.busy]);
	useChangeGroup("settings-capability-set", {
		dirty,
		discard,
		settling: () => commitBarrier.current?.promise ?? null,
	});

	const commit = async (wanted: OpsBundleDraft): Promise<void> => {
		if (commitWork.current != null) return await commitWork.current;
		committing.current = true;
		commitFinished.current = false;
		commitBarrier.current = Promise.withResolvers<void>();
		loadGeneration.current += 1;
		dispatch({ kind: "commitStarted" });
		const work = (async () => {
			try {
				const requested = formatOpsBundle(wanted);
				const result = await session.replaceOpsBundle(requested);
				dispatch({ kind: "commitSaved", result, wanted });
			} catch (cause) {
				dispatch({ kind: "commitFailed", message: cause instanceof Error ? cause.message : String(cause) });
			} finally {
				committing.current = false;
				commitFinished.current = true;
				dispatch({ kind: "commitSettled" });
			}
		})();
		commitWork.current = work;
		await work;
	};

	const model: CapabilitySetModel = {
		draft: state.draft,
		savedBundle: state.savedBundle,
		currentBundle,
		dirty,
		mode: state.mode,
		text: state.text,
		setMode: (mode) => dispatch({ kind: "mode", mode }),
		setText: (value) => dispatch({ kind: "text", text: value }),
		discard,
		loaded: state.loaded,
		busy: state.busy,
		errors: state.errors,
		notice: state.notice,
		retryPending: state.retryPending,
		editing: state.editing,
		setDraft: (next) => dispatch({ kind: "draft", draft: next }),
		setError: (message) => dispatch({ kind: "error", message }),
		edit: (capability) => dispatch({ kind: "edit", capability }),
		stopEditing: () => dispatch({ kind: "stopEditing" }),
		saveValue: (capability, uri) => dispatch({ kind: "saveValue", capability, uri }),
		commit,
	};

	return (
		<CapabilitySetContext.Provider value={model}>
			{children}
		</CapabilitySetContext.Provider>
	);
}

/** The card for one capability's URI. Drawn inside Settings, beside
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
		onSave(capability: OpsCap, uri: string): void;
	},
) {
	const commitments = useCommitments();
	const open = capability != null;
	const [showing, setShowing] = useState<OpsCap>(capability ?? "listeners");
	const [uri, setUri] = useState("");
	const [why, setWhy] = useState("");
	const dialog = useRef<HTMLDialogElement>(null);
	const field = useRef<HTMLInputElement>(null);
	const { held, onExited } = useHeldModal(open);
	useLayoutEffect(() => {
		if (capability == null) return;
		setShowing(capability);
		setUri(draft.get(capability) ?? "");
		setWhy("");
	}, [capability, draft]);
	useChangeGroup("settings-capability-value", {
		dirty: open && uri !== (draft.get(showing) ?? ""),
		discard: () => {
			setUri(draft.get(showing) ?? "");
			setWhy("");
		},
	});
	const requestClose = () => commitments.request(onClose, { only: ["settings-capability-value"] });
	useModalDialog(dialog, requestClose, field, open, onExited);
	if (!held) return null;
	const face = OPS_CATALOG[showing];
	const save = () => {
		if (!opsBundleReady(new Map([[showing, uri]]))) {
			setWhy(capabilitySetUriRefused);
			return;
		}
		onSave(showing, uri);
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
							id="capabilityValueUri"
							label={capabilityUriLabel}
							hint={capabilitySetMintedSaid(face.flag, face.how)}
							said={why}
						>
							{(wiring) => (
								<input
									ref={field}
									id={wiring.id}
									className="field"
									value={uri}
									{...identifierField}
									aria-describedby={wiring.describedBy}
									aria-invalid={wiring.invalid}
									onChange={(event) => {
										setUri(event.currentTarget.value);
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
