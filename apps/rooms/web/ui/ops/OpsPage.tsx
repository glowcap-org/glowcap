// The Operations surface in the content cell: one address per held capability.
//
// It is not its own screen. The shell — rail, topbar, Settings — stays up,
// and this surface stands where the conversation stands, so the way back is
// the rail itself and Settings opens over it exactly as it opens over a room.
// The modal this surface replaced could only show what was already held; an
// address can be arrived at cold, so the gate lives here: a pane this tab
// holds is drawn, and one it does not hold leads to the one saved
// capability-set editor. Possession, not the address, is what grants the
// server's side.
//
// `OpsRoute` is the navigation logic and draws nothing. This module is what
// `App` puts in the content cell, loaded when the address stands in /ops.

import { Fragment, lazy, type ReactNode, Suspense, useEffect } from "react";
import { Link, useNavigate } from "react-router";
import { useShallow } from "zustand/react/shallow";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsState } from "../hooks.ts";
import { Button } from "../Button.tsx";
import { type OpsHeld, opsHeldOf } from "../types.ts";
import { peeringSourcesOf } from "../text.ts";
import { loadIrcPane, loadListenersPane, loadOpsPane, loadPeeringPane, loadVizPane, prefetch } from "../chunks.ts";
import { OPS_CATALOG } from "./catalog.ts";
import { OPS_PANES, type OpsPaneFace, paneCapsHeld, paneOf } from "./panes.ts";
import { effectiveRoomsSessionAccess } from "../controller/access.ts";
import { DirectoryPane } from "./Directory.tsx";
import { ErrorBoundary } from "../ErrorBoundary.tsx";
import { OpsLoading } from "./Loading.tsx";

const ListenersPane = lazy(() => loadListenersPane());
const GatewayPane = lazy(() => loadIrcPane());
const PeeringPane = lazy(() => loadPeeringPane());
const VizPane = lazy(() => loadVizPane());

/** A held pane's body: start its chunk as soon as the address stands here,
 * and keep the same sheen whether the wait is the chunk or the first answer. */
function HeldPane(
	{ id, what, panelId, ready, children }: {
		id: string;
		what: string;
		panelId: string;
		ready: boolean;
		children: ReactNode;
	},
) {
	useEffect(() => {
		prefetch(() => loadOpsPane(id));
	}, [id]);
	return (
		<div id={panelId} className="ops-panel card-plane">
			<ErrorBoundary part={`${what} pane`}>
				<Suspense fallback={<OpsLoading what={what} />}>
					{ready ? children : <OpsLoading what={what} />}
				</Suspense>
			</ErrorBoundary>
		</div>
	);
}

/** A pane this tab cannot open: what each capability behind it would give,
 * and the one route to the capability set, standing where the pane will. A
 * pane filled by two capabilities names both, because taking either opens the
 * address and the second is what makes it act, and it names them in the same
 * shape one capability gets rather than shrinking both into a caption. */
function GateCard({ pane, canEdit }: { pane: OpsPaneFace; canEdit: boolean }) {
	const browser = useRoomsBrowser();
	const single = pane.caps.length === 1 ? OPS_CATALOG[pane.caps[0]] : null;
	return (
		<section className="ops-gate ops-card card-plane" id={`opsGate-${pane.path}`}>
			<h2>{single?.label ?? pane.label}</h2>
			{single !== null
				? (
					<>
						<p>{single.lead}</p>
						<p className="hint">
							The server mints it with the {single.flag} flag.
						</p>
					</>
				)
				: pane.caps.map((cap) => (
					<div className="ops-gate-cap" key={cap}>
						<h3>{OPS_CATALOG[cap].label}</h3>
						<p>{OPS_CATALOG[cap].lead}</p>
						<p className="hint">
							The server mints it with the {OPS_CATALOG[cap].flag} flag.
						</p>
					</div>
				))}
			{canEdit
				? (
					<div className="actions">
						<Button
							id={`opsGateTake-${pane.path}`}
							onClick={() => {
								browser.setSettingsTab("holdings");
								browser.openSettings();
							}}
						>
							Edit capability set
						</Button>
					</div>
				)
				: <p className="hint">An administrator session capability is required to change this set.</p>}
		</section>
	);
}

/** Operations panes are real addresses, so their chooser is navigation rather
 * than a segmented tab control. The grid keeps every held capability visible
 * and reflows as a whole; no label is squeezed, clipped, or hidden behind an
 * overflow menu when the server mints the complete set. */
function OpsNav(
	{ panes, selected, held }: {
		panes: readonly OpsPaneFace[];
		selected: OpsPaneFace | null;
		held: OpsHeld;
	},
) {
	const prefetchPane = (pane: OpsPaneFace) => {
		prefetch(() => loadOpsPane(pane.id));
		for (const cap of paneCapsHeld(pane, held)) prefetch(() => loadOpsPane(cap));
	};
	return (
		<nav
			id="opsNav"
			className="ops-nav"
			data-count={String(panes.length)}
			aria-labelledby="operationsTitle"
		>
			{panes.map((pane) => (
				<Link
					key={pane.id}
					id={`${pane.id}OpsLink`}
					className={pane === selected ? "ops-nav-item here" : "ops-nav-item"}
					to={`/ops/${pane.path}`}
					aria-current={pane === selected ? "page" : undefined}
					onPointerEnter={() => prefetchPane(pane)}
					onFocus={() => prefetchPane(pane)}
				>
					{pane.label}
				</Link>
			))}
		</nav>
	);
}

/** The content cell's operations surface: pane navigation when
 * more than one capability is held, then one raised card per ask or pane.
 * `segment` is the address's word for which pane, null on the index. */
export function OpsMain({ segment }: { segment: string | null }) {
	const s = useRoomsState(useShallow((state) => ({
		listeners: state.listeners,
		diagnostics: state.diagnostics,
		irc: state.irc,
		operator: state.operator,
		peering: state.peering,
		viz: state.viz,
		trouble: state.trouble,
		convs: state.convs,
		homeDir: state.homeDir,
		dirs: state.dirs,
		sessionAccess: state.sessionAccess,
	})));
	const browser = useRoomsBrowser();
	const navigate = useNavigate();
	const held = opsHeldOf(s.listeners, s.diagnostics, s.irc, s.operator, s.peering, s.viz);
	const pane = segment === null ? null : paneOf(segment);
	const open = pane !== null && paneCapsHeld(pane, held).length > 0;
	const heldPanes = OPS_PANES.filter((face) => paneCapsHeld(face, held).length > 0);
	const canEdit = effectiveRoomsSessionAccess(browser.roomsController(), s.sessionAccess) === "admin";

	return (
		<section className="ops-main" id="opsPage" aria-label="Operations">
			{heldPanes.length > 1 && <OpsNav panes={heldPanes} selected={open ? pane : null} held={held} />}
			<div className="ops-page-body">
				{segment !== null && pane === null && (
					<section className="ops-card card-plane ops-gate" id="opsNotFound">
						<h2>Nothing answers this address</h2>
						<p>
							/ops/{segment} names no operations pane.
						</p>
						{
							/* Named the way the chooser names them, and each name is the way
							   there. The list used to be the address segments themselves,
							   which asked a reader who had just mistyped one to read four
							   more and retype the right one. */
						}
						<p className="hint">
							The panes are {OPS_PANES.map((face, at) => (
								<Fragment key={face.id}>
									{at > 0 && (at === OPS_PANES.length - 1 ? ", and " : ", ")}
									<Link to={`/ops/${face.path}`}>{face.label}</Link>
								</Fragment>
							))}. Each opens when this tab holds a capability that fills it.
						</p>
						<div className="actions">
							<Button
								variant="quiet"
								onClick={() =>
									navigate("/ops", { replace: true })}
							>
								The operations index
							</Button>
						</div>
					</section>
				)}
				{segment === null && heldPanes.length === 0 && (
					<>
						<p className="lead">
							Nothing is held yet. Each pane below opens when this tab takes its capability from the
							server that minted it.
						</p>
						{OPS_PANES.map((face) => <GateCard key={face.id} pane={face} canEdit={canEdit} />)}
					</>
				)}
				{pane !== null && !open && <GateCard pane={pane} canEdit={canEdit} />}
				{open && pane?.id === "listeners" && (
					<HeldPane
						id="listeners"
						what="listeners"
						panelId="listenersOpsPanel"
						ready={s.listeners !== null}
					>
						<ListenersPane rows={s.listeners} />
					</HeldPane>
				)}
				{open && pane?.id === "directory" && (
					<div id="directoryOpsPanel" className="ops-panel card-plane">
						<DirectoryPane
							operatorHeld={held.operator}
							operator={s.operator}
							inspectHeld={held.diagnostics}
							rows={s.diagnostics}
							trouble={s.trouble}
						/>
					</div>
				)}
				{open && pane?.id === "irc" && (
					<HeldPane id="irc" what="IRC bridges" panelId="ircOpsPanel" ready={s.irc !== null}>
						<GatewayPane state={s.irc} />
					</HeldPane>
				)}
				{open && pane?.id === "peering" && (
					<HeldPane
						id="peering"
						what="peered rooms"
						panelId="peeringOpsPanel"
						ready={s.peering !== null}
					>
						<PeeringPane
							state={s.peering}
							sources={peeringSourcesOf(s.convs, s.homeDir, s.dirs)}
						/>
					</HeldPane>
				)}
				{open && pane?.id === "viz" && (
					<HeldPane
						id="viz"
						what="visualizer status"
						panelId="vizOpsPanel"
						ready={s.viz !== null}
					>
						<VizPane state={s.viz} />
					</HeldPane>
				)}
			</div>
		</section>
	);
}
