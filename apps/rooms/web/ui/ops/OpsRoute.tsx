// The operations namespace's address logic, drawn by nothing.
//
// /ops lands on the remembered held pane when it is held, else the first held
// one; with nothing held it stays, and the surface is the asks. Arriving asks
// every capability again, and standing on a held pane remembers it. The panes
// themselves load with `OpsMain` when the content cell stands here.

import * as store from "../store.ts";
import { useEffect } from "react";
import { useNavigate, useParams } from "react-router";
import { useShallow } from "zustand/react/shallow";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { useRoomsProjection, useRoomsState } from "../hooks.ts";
import { OPS_CAPS, opsHeldOf } from "../types.ts";
import { paneCapsHeld, paneForCap, paneOf } from "./panes.ts";

export function OpsRoute() {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const projection = useRoomsProjection();
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
		if (projection.get().activeKey !== null) store.clearConv(projection);
	}, [projection]);
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
