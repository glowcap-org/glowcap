// The Operations modal: the operator capabilities this tab holds.
//
// Settings → Advanced keeps one toggle per capability, and a toggle that is
// on means the capability is in hand — taking it happened in the take modal
// the toggle opened. While any is held the Operations control appears in the
// Settings head, and this modal draws one pane per held capability; with two
// or more a tab bar picks between them, with exactly one there is nothing to
// pick. Settings leaves without an exit while this is up, the same reason
// Help does: a dialog on a dialog is a shape neither the browser nor a
// screen reader handles well.

import { useEffect, useLayoutEffect, useRef } from "react";
import { usePeer } from "../peer.ts";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { IconButton } from "../IconButton.tsx";
import {
	type DiagnosticRow,
	type ListenerRow,
	OPS_CAPS,
	type OpsCap,
	type OpsHeld,
	type VizPublishState,
} from "../types.ts";
import { ListenersPane } from "./Listeners.tsx";
import { DiagnosticsPane } from "./Diagnostics.tsx";
import { VizPane } from "./Viz.tsx";
import { OPS_CATALOG } from "./catalog.ts";

export function Operations(
	{ open, held: holding, tab, diagnostics, listeners, viz, onLayer }: {
		open: boolean;
		/** Which capabilities are in hand, derived from the row fields. */
		held: OpsHeld;
		tab: OpsCap;
		diagnostics: readonly DiagnosticRow[] | null;
		listeners: readonly ListenerRow[] | null;
		viz: VizPublishState | null;
		onLayer: (held: boolean) => void;
	},
) {
	const peer = usePeer();
	const titleId = "operationsTitle";
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	const { held, onExited } = useHeldModal(open);
	useLayoutEffect(() => {
		onLayer(held);
		return () => onLayer(false);
	}, [held, onLayer]);
	useModalDialog(dialog, () => peer.closeOperations(), close, open, onExited);

	// A held capability's pane shows what the server said when it was last
	// asked, so opening the modal asks again. Both refreshes no-op unheld;
	// the viz pane draws this tab's own publishing state and asks nothing.
	useEffect(() => {
		if (!open) return;
		void peer.refreshListeners();
		void peer.refreshDiagnostics();
	}, [open, peer]);

	if (!held) return null;

	const panes = OPS_CAPS.filter((cap) => holding[cap]);
	const pane = panes.includes(tab) ? tab : panes[0] ?? "listeners";

	const select = (next: OpsCap) => {
		peer.setOpsTab(next);
		if (next === "listeners") void peer.refreshListeners();
		else if (next === "diagnostics") void peer.refreshDiagnostics();
	};

	return (
		<dialog
			ref={dialog}
			className="modal"
			aria-labelledby={titleId}
		>
			<div className="modal-card">
				<div className="settings-head-row">
					<h2 id={titleId}>Operations</h2>
					<IconButton
						id={open ? "operationsClose" : undefined}
						ref={close}
						icon="close"
						label="Close"
						title="Close"
						size="small"
						variant="ghost"
						onClick={() => peer.closeOperations()}
					/>
				</div>
				{panes.length > 1 && (
					<div
						className="settings-tabs ops-tabs"
						id="opsTabs"
						data-count={String(panes.length)}
						data-thumb={String(Math.max(0, panes.indexOf(pane)))}
						role="tablist"
						aria-labelledby={titleId}
						onKeyDown={(event) => {
							const at = Math.max(0, panes.indexOf(pane));
							const go = (next: OpsCap) => {
								event.preventDefault();
								select(next);
							};
							if (event.key === "Home") go(panes[0]);
							else if (event.key === "End") go(panes[panes.length - 1]);
							else if (event.key === "ArrowRight" || event.key === "ArrowDown") {
								go(panes[Math.min(panes.length - 1, at + 1)]);
							} else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
								go(panes[Math.max(0, at - 1)]);
							}
						}}
					>
						<span className="settings-tabs-thumb" aria-hidden="true" />
						{panes.map((cap) => (
							<button
								key={cap}
								id={`${cap}OpsTab`}
								type="button"
								className="settings-tab"
								role="tab"
								aria-selected={pane === cap}
								aria-controls={pane === cap ? `${cap}OpsPanel` : undefined}
								tabIndex={pane === cap ? 0 : -1}
								onClick={() => select(cap)}
							>
								{OPS_CATALOG[cap].pane}
							</button>
						))}
					</div>
				)}
				{pane === "listeners" && holding.listeners && (
					<div
						id="listenersOpsPanel"
						role={panes.length > 1 ? "tabpanel" : undefined}
						aria-labelledby={panes.length > 1 ? "listenersOpsTab" : undefined}
					>
						<ListenersPane rows={listeners} />
					</div>
				)}
				{pane === "diagnostics" && holding.diagnostics && (
					<div
						id="diagnosticsOpsPanel"
						role={panes.length > 1 ? "tabpanel" : undefined}
						aria-labelledby={panes.length > 1 ? "diagnosticsOpsTab" : undefined}
					>
						<DiagnosticsPane rows={diagnostics} />
					</div>
				)}
				{pane === "viz" && holding.viz && (
					<div
						id="vizOpsPanel"
						role={panes.length > 1 ? "tabpanel" : undefined}
						aria-labelledby={panes.length > 1 ? "vizOpsTab" : undefined}
					>
						<VizPane state={viz} />
					</div>
				)}
			</div>
		</dialog>
	);
}
