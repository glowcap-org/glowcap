// A headless owner for drafts that an action would abandon.
//
// Forms own their values and save flows. This boundary owns only the question
// shared by closing a modal, leaving a page, or starting an action that reloads:
// are there local changes outside the flow being committed, and if so has the
// reader chosen to discard them? The registry belongs to one React provider.
// Nothing is process-global, and a non-modal surface can render its own prompt
// over the same context.

import { discardChangesTitle } from "../../lib/text/controls.ts";
import { unsavedDiscard, unsavedKeep, unsavedLead } from "../../lib/text/page.ts";
import {
	createContext,
	type ReactNode,
	useCallback,
	useContext,
	useEffect,
	useLayoutEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import { Button } from "./Button.tsx";
import { ModalHead } from "./ModalHead.tsx";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { Said } from "./Said.tsx";
import { coveringReload } from "./boot.ts";

interface ChangeGroup {
	dirty(): boolean;
	discard(): void | Promise<void>;
	/** A commit already in flight. A conflicting action waits for it, then
	 * re-evaluates dirtiness instead of asking to discard work being saved. */
	settling?(): Promise<void> | null;
}

interface ChangeGroupInput {
	readonly dirty: boolean;
	discard(): void | Promise<void>;
	settling?(): Promise<void> | null;
}

export interface CommitmentSelection {
	/** Guard only these groups. Omitted means every registered group. */
	readonly only?: readonly string[];
	/** A save flow excludes the draft it is about to commit. */
	readonly except?: readonly string[];
}

interface PendingCommitment {
	readonly proceed: () => void | Promise<void>;
	readonly selection: CommitmentSelection;
}

interface CommitmentBoundary {
	readonly pending: boolean;
	readonly busy: boolean;
	readonly error: string;
	register(key: string, token: symbol, group: ChangeGroup): void;
	unregister(key: string, token: symbol): void;
	request(proceed: () => void | Promise<void>, selection?: CommitmentSelection): void;
	keep(): void;
	discard(): Promise<void>;
}

const CommitmentContext = createContext<CommitmentBoundary | null>(null);

function selectedGroups(
	groups: ReadonlyMap<string, { token: symbol; group: ChangeGroup }>,
	selection: CommitmentSelection,
): Array<readonly [string, ChangeGroup]> {
	const only = selection.only == null ? null : new Set(selection.only);
	const except = new Set(selection.except ?? []);
	const selected: Array<readonly [string, ChangeGroup]> = [];
	for (const [key, registered] of groups) {
		if ((only == null || only.has(key)) && !except.has(key)) selected.push([key, registered.group]);
	}
	return selected;
}

export function CommitmentProvider({ children }: { children: ReactNode }) {
	const groups = useRef(new Map<string, { token: symbol; group: ChangeGroup }>());
	const pendingRef = useRef<PendingCommitment | null>(null);
	const allowUnload = useRef(false);
	const [pending, setPending] = useState<PendingCommitment | null>(null);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState("");
	const register = useCallback((key: string, token: symbol, group: ChangeGroup) => {
		const held = groups.current.get(key);
		if (held?.token === token) return;
		groups.current.set(key, { token, group });
	}, []);
	const unregister = useCallback((key: string, token: symbol) => {
		if (groups.current.get(key)?.token !== token) return;
		groups.current.delete(key);
	}, []);

	const run = async (proceed: PendingCommitment["proceed"]): Promise<void> => {
		allowUnload.current = true;
		try {
			await proceed();
		} finally {
			// A committed reload has already covered the page. Clearing the flag
			// here runs as a microtask before the browser unloads, and would let a
			// still-dirty form cancel the reload, leaving the cover up forever.
			if (!coveringReload()) allowUnload.current = false;
		}
	};
	const boundary = useMemo<CommitmentBoundary>(() => ({
		get pending() {
			return pending !== null;
		},
		busy,
		error,
		register,
		unregister,
		request: (proceed, selection = {}) => {
			if (pendingRef.current !== null) return;
			const selected = selectedGroups(groups.current, selection);
			const settling = selected.flatMap(([, group]) => group.settling?.() ?? []);
			if (settling.length > 0) {
				const waiting = { proceed, selection };
				pendingRef.current = waiting;
				void Promise.allSettled(settling).then(() => {
					if (pendingRef.current !== waiting) return;
					pendingRef.current = null;
					boundary.request(proceed, selection);
				});
				return;
			}
			const dirty = selected.filter(([, group]) => group.dirty());
			const request = { proceed, selection };
			if (dirty.length === 0) {
				void run(proceed);
				return;
			}
			pendingRef.current = request;
			setError("");
			setPending(request);
		},
		keep: () => {
			if (busy) return;
			pendingRef.current = null;
			setError("");
			setPending(null);
		},
		discard: async () => {
			const request = pendingRef.current;
			if (request == null || busy) return;
			setBusy(true);
			setError("");
			try {
				for (const [, group] of selectedGroups(groups.current, request.selection)) {
					if (group.dirty()) await group.discard();
				}
				pendingRef.current = null;
				setPending(null);
				await run(request.proceed);
			} catch (cause) {
				setError(cause instanceof Error ? cause.message : String(cause));
			} finally {
				setBusy(false);
			}
		},
	}), [busy, error, pending, register, unregister]);

	useEffect(() => {
		const beforeUnload = (event: BeforeUnloadEvent) => {
			if (
				allowUnload.current || coveringReload() ||
				![...groups.current.values()].some(({ group }) => group.dirty())
			) return;
			event.preventDefault();
			event.returnValue = "";
		};
		addEventListener("beforeunload", beforeUnload);
		return () => removeEventListener("beforeunload", beforeUnload);
	}, []);

	return <CommitmentContext.Provider value={boundary}>{children}</CommitmentContext.Provider>;
}

export function useCommitments(): CommitmentBoundary {
	const boundary = useContext(CommitmentContext);
	if (boundary == null) throw new Error("a change commitment was requested outside its provider");
	return boundary;
}

/** Bridge an async form commit to the first React layout that contains its
 * result. A close/navigation request arriving in that gap waits, then asks the
 * form's current dirty state. It cannot prompt about values the successful
 * commit has already reset. Instance-owned by the form using it. */
export function useCommitSettling(): {
	begin(): void;
	finish(): void;
	current(): Promise<void> | null;
} {
	const barrier = useRef<PromiseWithResolvers<void> | null>(null);
	const finished = useRef(false);
	const [, scheduleLayout] = useState(0);
	const begin = useCallback(() => {
		if (barrier.current != null) return;
		barrier.current = Promise.withResolvers<void>();
		finished.current = false;
	}, []);
	const finish = useCallback(() => {
		if (barrier.current == null) return;
		finished.current = true;
		scheduleLayout((revision) => revision + 1);
	}, []);
	const current = useCallback(() => barrier.current?.promise ?? null, []);
	useLayoutEffect(() => {
		if (!finished.current || barrier.current == null) return;
		const settled = barrier.current;
		barrier.current = null;
		finished.current = false;
		settled.resolve();
	});
	useEffect(() => () => {
		barrier.current?.resolve();
		barrier.current = null;
		finished.current = false;
	}, []);
	return useMemo(() => ({ begin, finish, current }), [begin, finish, current]);
}

/** Register one form-owned draft. The getter stays current without replacing
 * the provider registry or coupling sibling forms to one combined state. */
export function useChangeGroup(key: string, group: ChangeGroupInput): void {
	// The two verbs, not the registry they came from. These effects depend on
	// being able to call them and on nothing else about the boundary, and taking
	// them out here says so in the dependency lists below instead of leaving
	// `boundary.register` there as a path a reader has to trust is stable.
	const { register, unregister } = useCommitments();
	const token = useRef(Symbol(key));
	const dirty = useRef(group.dirty);
	const discard = useRef(group.discard);
	const settling = useRef(group.settling);
	dirty.current = group.dirty;
	useLayoutEffect(() => {
		discard.current = group.discard;
		settling.current = group.settling;
	}, [group.discard, group.settling]);
	useLayoutEffect(() => {
		const owned = token.current;
		return () => unregister(key, owned);
	}, [unregister, key]);
	useLayoutEffect(
		() => {
			register(key, token.current, {
				dirty: () => dirty.current,
				discard: () => discard.current(),
				settling: () => settling.current?.() ?? null,
			});
		},
		[register, key],
	);
}

/** Rooms' conventional rendering of the headless commitment question. It is
 * mounted beside the application rather than inside the surface it guards, so
 * it stacks over either a page or any depth of modal form. */
export function CommitmentPrompt() {
	const commitments = useCommitments();
	const dialog = useRef<HTMLDialogElement>(null);
	const close = useRef<HTMLButtonElement>(null);
	const { held, onExited } = useHeldModal(commitments.pending);
	useModalDialog(dialog, commitments.keep, close, commitments.pending, onExited);
	if (!held) return null;
	return (
		<dialog ref={dialog} className="modal" aria-labelledby="settingsUnsavedTitle">
			<div className="modal-card card-plane">
				<div className="modal-body">
					<ModalHead
						title={discardChangesTitle}
						titleId="settingsUnsavedTitle"
						closeRef={close}
						onClose={commitments.keep}
					/>
					<p className="lead" id="settingsUnsavedMessage">{unsavedLead}</p>
					{commitments.error !== "" && <Said kind="failure">{commitments.error}</Said>}
					<div className="actions">
						<Button
							id="settingsUnsavedKeep"
							type="button"
							variant="quiet"
							disabled={commitments.busy}
							onClick={commitments.keep}
						>
							{unsavedKeep}
						</Button>
						<Button
							id="settingsUnsavedDiscard"
							type="button"
							variant="danger"
							busy={commitments.busy}
							onClick={() => void commitments.discard()}
						>
							{unsavedDiscard}
						</Button>
					</div>
				</div>
			</div>
		</dialog>
	);
}
