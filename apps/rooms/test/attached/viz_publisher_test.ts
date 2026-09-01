/// <reference lib="dom" />

// A shared session already publishes through its durable visualizer. This tab
// must not arm a second producer from the session's swiss: a refusal would
// toast as if the tab had been the holder, and erase the remembered secret.

const ENDPOINT = "ws://rooms.test/viz";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

Object.defineProperty(globalThis, "location", {
	configurable: true,
	value: { search: `?viz=${encodeURIComponent(ENDPOINT)}`, reload() {} },
});

const { RoomsPage } = await import("../../web/ui/page.ts");
const { ensureVizPublisher, takeVizCap } = await import("../../web/ui/net/viz.ts");

function pageWithRememberedViz(): InstanceType<typeof RoomsPage> {
	const page = new RoomsPage();
	page.workspace.retained = {
		...page.workspace.retained,
		operations: [{ capability: "viz", scope: ENDPOINT, swiss: "viz-swiss" }],
	};
	return page;
}

function stopArmed(page: InstanceType<typeof RoomsPage>): void {
	const holding = page.viz.armed;
	if (holding == null) return;
	page.viz.armed = null;
	holding.publisher.stop();
	holding.uninstall();
}

Deno.test("a remembered visualizer arms this tab when the session is local", async () => {
	const page = pageWithRememberedViz();
	await ensureVizPublisher(page);
	try {
		if (page.viz.armed == null) throw new Error("the local tab did not arm its remembered visualizer");
	} finally {
		stopArmed(page);
	}
});

Deno.test("a shared session does not arm this tab's visualizer publisher", async () => {
	const page = pageWithRememberedViz();
	page.attachedSession.hold({} as never);
	await ensureVizPublisher(page);
	if (page.viz.armed !== null) throw new Error("the attached tab armed a local visualizer");
});

Deno.test("a shared session refuses a visualizer take on this tab", async () => {
	const page = pageWithRememberedViz();
	page.attachedSession.hold({} as never);
	const why = await takeVizCap(page, "viz-swiss", true);
	if (!why.includes("shared session")) {
		throw new Error(`the attached take was not refused as this tab's: ${why}`);
	}
	if (page.viz.armed !== null) throw new Error("the attached take armed a local visualizer");
});
