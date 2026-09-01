// The page's async graphs, named once so a prefetch and a `lazy()` load the
// same module. Each function is the one import() for that wait.

/** Hold a download whose failure this call must not explain. Hover prefetch
 * and an abandoned parallel import are not this page's opening; a required
 * load is the one that can stamp the opening screen lost. */
export function prefetch(load: () => Promise<unknown>): void {
	void load().then(() => {}, () => {});
}

export function loadSessionSetup(): Promise<typeof import("./SessionSetup.tsx")> {
	return import("./SessionSetup.tsx");
}

export function loadEstablished(): Promise<typeof import("./established.tsx")> {
	return import("./established.tsx");
}

export function loadOpsPage(): Promise<typeof import("./ops/OpsPage.tsx")> {
	return import("./ops/OpsPage.tsx");
}

export function loadKitchen(): Promise<typeof import("./KitchenBundle.tsx")> {
	return import("./KitchenBundle.tsx");
}

export function loadListenersPane() {
	return import("./ops/Listeners.tsx").then((m) => ({ default: m.ListenersPane }));
}

export function loadIrcPane() {
	return import("./ops/Irc.tsx").then((m) => ({ default: m.IrcPane }));
}

export function loadPeeringPane() {
	return import("./ops/Peering.tsx").then((m) => ({ default: m.PeeringPane }));
}

export function loadVizPane() {
	return import("./ops/Viz.tsx").then((m) => ({ default: m.VizPane }));
}

export function loadOperatorPane() {
	return import("./ops/Operator.tsx").then((m) => ({ default: m.OperatorPane }));
}

export function loadDiagnosticsPane() {
	return import("./ops/Diagnostics.tsx").then((m) => ({ default: m.DiagnosticsPane }));
}

/** Prefetch a pane, or one capability that fills the directory pane. */
export function loadOpsPane(id: string): Promise<unknown> {
	switch (id) {
		case "listeners":
			return loadListenersPane();
		case "irc":
			return loadIrcPane();
		case "peering":
			return loadPeeringPane();
		case "viz":
			return loadVizPane();
		case "operator":
			return loadOperatorPane();
		case "diagnostics":
			return loadDiagnosticsPane();
		default:
			return Promise.resolve();
	}
}
