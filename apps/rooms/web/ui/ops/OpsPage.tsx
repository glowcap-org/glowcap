// The Operations surface: the /ops namespace, one address per held capability.
//
// It is not its own screen. The shell — rail, topbar, Settings — stays up,
// and the surface stands in the content cell where the conversation stands,
// so the way back is the rail itself and Settings opens over it exactly as
// it opens over a room. The modal this surface replaced could only show what
// was already held; an address can be arrived at cold, so the gate lives in
// the surface: a pane this tab holds is drawn, and one it does not hold leads
// to the one saved capability-set editor. Possession, not the address, is what
// grants the server's side.
//
// Two halves, split the way the router splits every address: `OpsRoute` is
// the navigation logic and draws nothing, and `OpsMain` is what `App` puts
// in the content cell while the address stands in this namespace.

import { useEffect } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { useShallow } from "zustand/react/shallow";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import * as store from "../store.ts";
import { useRoomsState } from "../hooks.ts";
import { Button } from "../Button.tsx";
import { OPS_CAPS, opsHeldOf } from "../types.ts";
import { peeringSourcesOf } from "../text.ts";
import { OPS_CATALOG } from "./catalog.ts";
import { OPS_PANES, type OpsPaneFace, paneCapsHeld, paneForCap, paneOf } from "./panes.ts";
import { ListenersPane } from "./Listeners.tsx";
import { DirectoryPane } from "./Directory.tsx";
import { IrcPane } from "./Irc.tsx";
import { OpsLoading } from "./Loading.tsx";
import { PeeringPane } from "./Peering.tsx";
import { VizPane } from "./Viz.tsx";

/** Where an address stands in the /ops namespace: not in it at all, on the
 * index, or on a segment. `App` reads this to decide what the content cell
 * draws; the route elements below own what standing there does. */
export function opsAddressOf(
	pathname: string,
): { on: false } | { on: true; segment: string | null } {
	if (pathname === "/ops" || pathname === "/ops/") return { on: true, segment: null };
	if (!pathname.startsWith("/ops/")) return { on: false };
	const segment = decodeURIComponent(pathname.slice("/ops/".length));
	return { on: true, segment: segment === "" ? null : segment };
}

/** The namespace's address logic, drawn by nothing: /ops lands on the
 * remembered held pane when it is held, else the first held one; with
 * nothing held it stays, and the surface is the asks. Arriving asks every
 * capability again, and standing on a held pane remembers it. */
export function OpsRoute() {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const s = useRoomsState(useShallow((state) => ({
		listeners: state.listeners,
		diagnostics: state.diagnostics,
		irc: state.irc,
		operator: state.operator,
		peering: state.peering,
		viz: state.viz,
		opsPane: state.opsPane,
	})));
	const navigate = useNavigate();
	const { pane: segment } = useParams();
	// Standing on operations means looking at the server, not a room: the
	// selection clears, the rail marks nothing, and any later pick is a
	// transition the router's mirror answers by leaving the namespace.
	useEffect(() => {
		if (store.get().activeKey !== null) store.clearConv();
	}, []);
	const held = opsHeldOf(s.listeners, s.diagnostics, s.irc, s.operator, s.peering, s.viz);
	const pane = segment === undefined ? null : paneOf(segment);
	const heldCaps = OPS_CAPS.filter((c) => held[c]);
	const heldKey = heldCaps.join(",");
	const paneCaps = pane === null ? [] : paneCapsHeld(pane, held);
	const paneKey = paneCaps.join(",");

	useEffect(() => {
		if (segment !== undefined) return;
		const remembered = held[s.opsPane] ? s.opsPane : undefined;
		const landing = remembered ?? heldCaps[0];
		if (landing !== undefined) navigate(`/ops/${paneForCap(landing).path}`, { replace: true });
		// heldKey stands in for the array it derives from.
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [segment, heldKey, s.opsPane, navigate]);

	// A capability's own word still answers, so an address from before the
	// directory pane lands on the pane that draws it rather than nowhere.
	useEffect(() => {
		if (segment === undefined || pane === null || pane.path === segment) return;
		navigate(`/ops/${pane.path}`, { replace: true });
	}, [segment, pane, navigate]);

	useEffect(() => {
		if (paneCaps.length === 0) return;
		browser.setOpsPane(paneCaps[0]);
		for (const cap of paneCaps) void session.refreshOpsCap(cap);
		// paneKey stands in for the array it derives from.
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [browser, paneKey, session]);

	return null;
}

/** A pane this tab cannot open: what each capability behind it would give,
 * and the one route to the capability set, standing where the pane will. A
 * pane filled by two capabilities names both, because taking either opens the
 * address and the second is what makes it act. */
function GateCard({ pane }: { pane: OpsPaneFace }) {
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
							The server mints it with the <code>{single.flag}</code> flag.
						</p>
					</>
				)
				: pane.caps.map((cap) => (
					<p className="hint" key={cap}>
						<strong>{OPS_CATALOG[cap].label}</strong> {OPS_CATALOG[cap].lead} The server mints it with the
						{" "}
						<code>{OPS_CATALOG[cap].flag}</code> flag.
					</p>
				))}
			<div className="actions">
				<Button
					id={`opsGateTake-${pane.path}`}
					onClick={() => {
						browser.setSettingsTab("settings");
						browser.openSettings();
					}}
				>
					Edit capability set
				</Button>
			</div>
		</section>
	);
}

/** Operations panes are real addresses, so their chooser is navigation rather
 * than a segmented tab control. The grid keeps every held capability visible
 * and reflows as a whole; no label is squeezed, clipped, or hidden behind an
 * overflow menu when the server mints the complete set. */
function OpsNav({ panes, selected }: { panes: readonly OpsPaneFace[]; selected: OpsPaneFace | null }) {
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
	})));
	const navigate = useNavigate();
	const held = opsHeldOf(s.listeners, s.diagnostics, s.irc, s.operator, s.peering, s.viz);
	const pane = segment === null ? null : paneOf(segment);
	const open = pane !== null && paneCapsHeld(pane, held).length > 0;
	const heldPanes = OPS_PANES.filter((face) => paneCapsHeld(face, held).length > 0);

	return (
		<section className="ops-main" id="opsPage" aria-label="Operations">
			{heldPanes.length > 1 && <OpsNav panes={heldPanes} selected={open ? pane : null} />}
			<div className="ops-page-body">
				{segment !== null && pane === null && (
					<section className="ops-card card-plane ops-gate" id="opsNotFound">
						<h2>Nothing answers this address</h2>
						<p>
							<code>/ops/{segment}</code> names no operations pane.
						</p>
						<p className="hint">
							The panes are {OPS_PANES.map((face) =>
								face.path
							).join(", ")}. Each opens when this tab holds a capability that fills it.
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
						{OPS_PANES.map((face) => <GateCard key={face.id} pane={face} />)}
					</>
				)}
				{pane !== null && !open && <GateCard pane={pane} />}
				{open && pane?.id === "listeners" && (
					<div id="listenersOpsPanel" className="ops-card card-plane">
						{s.listeners === null ? <OpsLoading what="listeners" /> : <ListenersPane rows={s.listeners} />}
					</div>
				)}
				{open && pane?.id === "directory" && (
					<div id="directoryOpsPanel" className="ops-card card-plane">
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
					<div id="ircOpsPanel" className="ops-card card-plane">
						{s.irc === null ? <OpsLoading what="IRC bridges" /> : <IrcPane state={s.irc} />}
					</div>
				)}
				{open && pane?.id === "peering" && (
					<div id="peeringOpsPanel" className="ops-card card-plane">
						{s.peering === null ? <OpsLoading what="peered rooms" /> : (
							<PeeringPane
								state={s.peering}
								sources={peeringSourcesOf(s.convs, s.homeDir, s.dirs)}
							/>
						)}
					</div>
				)}
				{open && pane?.id === "viz" && (
					<div id="vizOpsPanel" className="ops-card card-plane">
						{s.viz === null ? <OpsLoading what="visualizer status" /> : <VizPane state={s.viz} />}
					</div>
				)}
			</div>
		</section>
	);
}
