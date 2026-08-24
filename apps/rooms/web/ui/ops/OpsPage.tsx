// The Operations surface: the /ops namespace, one address per held capability.
//
// It is not its own screen. The shell — rail, topbar, Settings — stays up,
// and the surface stands in the content cell where the conversation stands,
// so the way back is the rail itself and Settings opens over it exactly as
// it opens over a room. The modal this surface replaced could only show what
// was already held; an address can be arrived at cold, so the gate lives in
// the surface: a pane this tab holds is drawn, and one it does not hold is
// its capability's ask — the same take the Capabilities toggle opens — because
// possession, not the address, is what grants the server's side.
//
// Two halves, split the way the router splits every address: `OpsRoute` is
// the navigation logic and draws nothing, and `OpsMain` is what `App` puts
// in the content cell while the address stands in this namespace.

import { useEffect } from "react";
import { useNavigate, useParams } from "react-router";
import { usePeer } from "../peer.ts";
import * as store from "../store.ts";
import { useStore } from "../hooks.ts";
import { Button } from "../Button.tsx";
import { Tabs } from "../Tabs.tsx";
import { OPS_CAPS, type OpsCap, opsHeldOf } from "../types.ts";
import { peeringSourcesOf } from "../text.ts";
import { OPS_CATALOG } from "./catalog.ts";
import { ListenersPane } from "./Listeners.tsx";
import { DiagnosticsPane } from "./Diagnostics.tsx";
import { IrcPane } from "./Irc.tsx";
import { PeeringPane } from "./Peering.tsx";
import { VizPane } from "./Viz.tsx";

/** Each capability's segment under /ops. The listeners pane keeps the server
 * flag's own word, so the address an operator bookmarks matches the knob
 * that minted the capability. */
const PANE_PATH: Record<OpsCap, string> = {
	listeners: "admin-listeners",
	diagnostics: "diagnostics",
	irc: "irc",
	peering: "peering",
	viz: "viz",
};

function capOf(segment: string): OpsCap | null {
	for (const cap of OPS_CAPS) if (PANE_PATH[cap] === segment) return cap;
	return null;
}

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
	const peer = usePeer();
	const s = useStore();
	const navigate = useNavigate();
	const { pane: segment } = useParams();
	// Standing on operations means looking at the server, not a room: the
	// selection clears, the rail marks nothing, and any later pick is a
	// transition the router's mirror answers by leaving the namespace.
	useEffect(() => {
		if (store.get().activeKey !== null) store.clearConv();
	}, []);
	const held = opsHeldOf(s.listeners, s.diagnostics, s.irc, s.peering, s.viz);
	const cap = segment === undefined ? null : capOf(segment);
	const heldPanes = OPS_CAPS.filter((c) => held[c]);
	const heldKey = heldPanes.join(",");

	useEffect(() => {
		if (segment !== undefined) return;
		const remembered = held[s.opsTab] ? s.opsTab : undefined;
		const landing = remembered ?? heldPanes[0];
		if (landing !== undefined) navigate(`/ops/${PANE_PATH[landing]}`, { replace: true });
		// heldKey stands in for the array it derives from.
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [segment, heldKey, s.opsTab, navigate]);

	useEffect(() => {
		for (const c of OPS_CAPS) void peer.refreshOpsCap(c);
	}, [peer]);
	useEffect(() => {
		if (cap === null || !held[cap]) return;
		peer.setOpsTab(cap);
		void peer.refreshOpsCap(cap);
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [cap, heldKey, peer]);

	return null;
}

/** A pane this tab does not hold: the ask, standing where the pane will.
 * Same words as the Capabilities toggle's take, because it is the same take. */
function GateCard({ cap }: { cap: OpsCap }) {
	const peer = usePeer();
	const face = OPS_CATALOG[cap];
	return (
		<section className="ops-gate ops-card card-plane" id={`opsGate-${PANE_PATH[cap]}`}>
			<h2>{face.label}</h2>
			<p>{face.lead}</p>
			<p className="hint">
				The server mints it with the <code>{face.flag}</code> flag.
			</p>
			<Button
				id={`opsGateTake-${PANE_PATH[cap]}`}
				variant="quiet"
				onClick={() => peer.openOpsTake(cap, "ops")}
			>
				Take the capability
			</Button>
		</section>
	);
}

/** The content cell's operations surface: the pane nav in its tab well when
 * more than one capability is held, then one raised card per ask or pane.
 * `segment` is the address's word for which pane, null on the index. */
export function OpsMain({ segment }: { segment: string | null }) {
	const s = useStore();
	const navigate = useNavigate();
	const held = opsHeldOf(s.listeners, s.diagnostics, s.irc, s.peering, s.viz);
	const cap = segment === null ? null : capOf(segment);
	const heldPanes = OPS_CAPS.filter((c) => held[c]);

	return (
		<section className="ops-main" id="opsPage" aria-label="Operations">
			{heldPanes.length > 1 && (
				<Tabs
					id="opsTabs"
					tabs={heldPanes.map((c) => ({
						id: c,
						domId: `${c}OpsTab`,
						label: OPS_CATALOG[c].pane,
						panelId: `${c}OpsPanel`,
					}))}
					selected={cap !== null && held[cap] ? cap : null}
					labelledBy="operationsTitle"
					onSelect={(c) => navigate(`/ops/${PANE_PATH[c]}`)}
				/>
			)}
			<div className="ops-page-body">
				{segment !== null && cap === null && (
					<section className="ops-card card-plane ops-gate" id="opsNotFound">
						<h2>Nothing answers this address</h2>
						<p>
							<code>/ops/{segment}</code> names no operations pane.
						</p>
						<p className="hint">
							The panes are admin-listeners, diagnostics, peering, and viz; each opens when its capability
							is held.
						</p>
						<Button
							variant="quiet"
							onClick={() => navigate("/ops", { replace: true })}
						>
							The operations index
						</Button>
					</section>
				)}
				{segment === null && heldPanes.length === 0 && (
					<>
						<p className="lead">
							Nothing is held yet. Each pane below opens when this tab takes its capability from the
							server that minted it.
						</p>
						{OPS_CAPS.map((c) => <GateCard key={c} cap={c} />)}
					</>
				)}
				{cap !== null && !held[cap] && <GateCard cap={cap} />}
				{cap === "listeners" && held.listeners && (
					<div id="listenersOpsPanel" className="ops-card card-plane">
						<ListenersPane rows={s.listeners} />
					</div>
				)}
				{cap === "diagnostics" && held.diagnostics && (
					<div id="diagnosticsOpsPanel" className="ops-card card-plane">
						<DiagnosticsPane rows={s.diagnostics} trouble={s.trouble} />
					</div>
				)}
				{cap === "irc" && held.irc && (
					<div id="ircOpsPanel" className="ops-card card-plane">
						<IrcPane state={s.irc} />
					</div>
				)}
				{cap === "peering" && held.peering && (
					<div id="peeringOpsPanel" className="ops-card card-plane">
						<PeeringPane
							state={s.peering}
							sources={peeringSourcesOf(s.convs, s.homeDir, s.dirs)}
						/>
					</div>
				)}
				{cap === "viz" && held.viz && (
					<div id="vizOpsPanel" className="ops-card card-plane">
						<VizPane state={s.viz} />
					</div>
				)}
			</div>
		</section>
	);
}
