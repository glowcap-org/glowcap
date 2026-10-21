import { assert, assertEquals } from "@std/assert";
import { type NodeKind, resolveGesture, surfaceDefault, toolAcceptsNode } from "./gesture-resolver.ts";
import { ALL_SURFACES, ALL_TOOLS, dummyHit } from "./gesture-resolver-test/harness.ts";
import { type GestureContext, type Hit, NO_MODIFIERS } from "./types.ts";

function ctx(opts: Partial<GestureContext> & { hit: Hit }): GestureContext {
	return {
		modifiers: NO_MODIFIERS,
		spaceHeld: false,
		activeTool: "select",
		...opts,
	};
}

// ─────────────────────── totality ────────────────────────

Deno.test("resolveGesture is total over (every surface × every tool)", () => {
	for (const surface of ALL_SURFACES) {
		for (const tool of ALL_TOOLS) {
			const result = resolveGesture(
				ctx({ hit: dummyHit(surface), activeTool: tool }),
			);
			assert(
				result !== undefined && "tier" in result,
				`no resolution for ${tool} on ${surface}`,
			);
		}
	}
});

// ─────────────────────── Spacebar wins ──────────────────────

Deno.test("spaceHeld → tier=space-pan regardless of surface/tool/modifier", () => {
	for (const surface of ALL_SURFACES) {
		for (const tool of ALL_TOOLS) {
			const r = resolveGesture(
				ctx({
					hit: dummyHit(surface),
					activeTool: tool,
					spaceHeld: true,
					modifiers: { shift: true, cmd: true, alt: true },
				}),
			);
			assertEquals(r.tier, "space-pan", `${tool} on ${surface} + space`);
			if (r.tier === "space-pan") {
				assertEquals(r.verb.kind, "pan-surface");
			}
		}
	}
});

// ─────────────────────── Hand tool wins after Space ───────────────────

Deno.test("Hand tool → tier=hand-tool regardless of surface/modifier", () => {
	for (const surface of ALL_SURFACES) {
		const r = resolveGesture(
			ctx({
				hit: dummyHit(surface),
				activeTool: "hand",
				modifiers: { shift: true, cmd: false, alt: false },
			}),
		);
		assertEquals(r.tier, "hand-tool");
	}
});

// ─────────────────────── Select tool = surface defaults ──────────

Deno.test("Select tool with no modifier returns the default verb", () => {
	for (const surface of ALL_SURFACES) {
		const hit = dummyHit(surface);
		const expected = surfaceDefault(hit);
		const r = resolveGesture(ctx({ hit, activeTool: "select" }));
		assertEquals(r.tier, "default", `${surface}`);
		if (r.tier === "default") assertEquals(r.verb, expected);
	}
});

// ─────────────────────── Modifiers veto tool-create ──────────────

Deno.test("Add Peer + Shift → falls through to default (no tool-create)", () => {
	const r = resolveGesture(
		ctx({
			hit: dummyHit("stage-empty"),
			activeTool: "add-peer",
			modifiers: { shift: true, cmd: false, alt: false },
		}),
	);
	assert(r.tier !== "tool-create", `expected non-tool-create, got ${r.tier}`);
});

Deno.test("Open Session + Cmd on peer → surface default", () => {
	const hit = dummyHit("stage-peer", { peerId: "alice" });
	const r = resolveGesture(
		ctx({
			hit,
			activeTool: "open-session",
			modifiers: { shift: false, cmd: true, alt: false },
		}),
	);
	assertEquals(r.tier, "default");
	if (r.tier === "default") {
		assertEquals(r.verb.kind, "select-or-drag-peer");
	}
});

// ─────────────────────── Tool-create paths ────────────────────────────

Deno.test("Add Peer on empty stage → create-peer-at", () => {
	const r = resolveGesture(
		ctx({ hit: dummyHit("stage-empty"), activeTool: "add-peer" }),
	);
	assertEquals(r.tier, "tool-create");
	if (r.tier === "tool-create") assertEquals(r.verb.kind, "create-peer-at");
});

Deno.test("Add Peer on a peer (wrong surface) → falls through to default", () => {
	const r = resolveGesture(
		ctx({ hit: dummyHit("stage-peer"), activeTool: "add-peer" }),
	);
	assertEquals(r.tier, "default");
});

Deno.test("Open Session on peer picks that peer", () => {
	const r = resolveGesture(
		ctx({
			hit: dummyHit("stage-peer", { peerId: "bob" }),
			activeTool: "open-session",
		}),
	);
	assertEquals(r.tier, "tool-create");
	if (r.tier === "tool-create" && r.verb.kind === "two-click-pick") {
		assertEquals(r.verb.tool, "open-session");
		assertEquals(r.verb.nodeId, "bob");
	}
});

Deno.test("Send Message picks an end nothing has attributed", () => {
	// A message can name a loose end. That is what the wire looks like before
	// anything proves who answered, and a recording holds it. The tool has to
	// be able to author every shape a recording can hold.
	const r = resolveGesture(
		ctx({
			hit: dummyHit("stage-endpoint", { endpointId: "s1::b" }),
			activeTool: "send-message",
		}),
	);
	assertEquals(r.tier, "tool-create");
	if (r.tier === "tool-create" && r.verb.kind === "two-click-pick") {
		assertEquals(r.verb.tool, "send-message");
		assertEquals(r.verb.nodeId, "s1::b");
	}
});

Deno.test("Open Session does not arm on an end nothing has attributed", () => {
	// A new session mints its own two ends, so an end that already belongs to
	// one has nothing to be. Two sessions sharing an end would say the two
	// claims are the same party, and nothing has proved that; the node that is
	// shared between sessions is the peer, and attribution is how an end
	// becomes one.
	const r = resolveGesture(
		ctx({
			hit: dummyHit("stage-endpoint", { endpointId: "s1::b" }),
			activeTool: "open-session",
		}),
	);
	assert(
		r.tier !== "tool-create",
		"Open Session armed on a loose end",
	);
});

Deno.test("the resolver picks exactly the nodes the tool table takes", () => {
	// The one statement of what a tool does with a node is `toolAcceptsNode`,
	// and this is the resolver answering to it rather than repeating it. A
	// second copy drifted silently in the direction that matters least visibly:
	// a tool that took a kind of node in the table and not in the resolver
	// neither picked it nor refused it, so the click fell through to plain
	// selection and the tool quietly did something else.
	const nodeHit = (kind: NodeKind): Hit =>
		kind === "peer"
			? dummyHit("stage-peer", { peerId: "bob" })
			: dummyHit("stage-endpoint", { endpointId: "s1::b" });
	for (const tool of ALL_TOOLS) {
		for (const kind of ["peer", "endpoint"] as const) {
			const r = resolveGesture(
				ctx({ hit: nodeHit(kind), activeTool: tool }),
			);
			const picked = r.tier === "tool-create" &&
				r.verb.kind === "two-click-pick";
			assertEquals(
				picked,
				toolAcceptsNode(tool, kind) === "takes",
				`${tool} over a ${kind}: the table and the resolver disagree`,
			);
		}
	}
});

// ─────────────────────── Modifier overrides ──────────────────

Deno.test("Shift leaves a peer's semantic verb unchanged", () => {
	const r = resolveGesture(
		ctx({
			hit: dummyHit("stage-peer", { peerId: "carol" }),
			modifiers: { shift: true, cmd: false, alt: false },
		}),
	);
	assertEquals(r.tier, "default");
	if (r.tier === "default" && r.verb.kind === "select-or-drag-peer") {
		assertEquals(r.verb.entityRef, { kind: "peer", id: "carol" });
	}
});

Deno.test("Cmd leaves an event pill's semantic verb unchanged", () => {
	const r = resolveGesture(
		ctx({
			hit: {
				surface: "timeline-lane-event",
				eventId: "ev1",
				entityRef: { kind: "session", id: "s42" },
			},
			modifiers: { shift: false, cmd: true, alt: false },
		}),
	);
	assertEquals(r.tier, "default");
	if (r.tier === "default" && r.verb.kind === "select-or-drag-event") {
		assertEquals(r.verb.entityRef, { kind: "session", id: "s42" });
	}
});

Deno.test("Shift leaves the empty stage's marquee verb unchanged", () => {
	const r = resolveGesture(
		ctx({
			hit: dummyHit("stage-empty"),
			modifiers: { shift: true, cmd: false, alt: false },
		}),
	);
	assertEquals(r.tier, "default");
	if (r.tier === "default" && r.verb.kind === "rubber-band") {
		assertEquals(r.verb.mode, "replace");
	}
});

// An empty lane starts the same marquee as an empty stage. Selection
// modifiers are interpreted by the surface adapter when it commits.
Deno.test("Empty lane resolves to the marquee, as the Scrubber's press does", () => {
	const r = resolveGesture(
		ctx({ hit: { surface: "timeline-lane-empty", t: 5000 } }),
	);
	assertEquals(r.tier, "default");
	if (r.tier === "default" && r.verb.kind === "rubber-band") {
		assertEquals(r.verb.mode, "replace");
	} else {
		throw new Error(`expected rubber-band, got ${JSON.stringify(r)}`);
	}
});

Deno.test("Shift leaves an empty lane's marquee verb unchanged", () => {
	const r = resolveGesture(
		ctx({
			hit: { surface: "timeline-lane-empty", t: 5000 },
			modifiers: { shift: true, cmd: false, alt: false },
		}),
	);
	assertEquals(r.tier, "default");
	if (r.tier === "default" && r.verb.kind === "rubber-band") {
		assertEquals(r.verb.mode, "replace");
	} else {
		throw new Error(`expected rubber-band, got ${JSON.stringify(r)}`);
	}
});

// ─────────────────────── Click-up re-resolve (D) ──────────────────────
// (The re-resolve is the FSM's job; the resolver itself only needs to
// produce the right verb for both contexts. Modifiers veto creation,
// so the up-context can still materially differ from the down-context.)

Deno.test("D: a modifier held at pointer-up vetoes the creation verb", () => {
	const hit = dummyHit("stage-peer", { peerId: "down-mod" });
	const downR = resolveGesture(ctx({ hit, activeTool: "open-session" }));
	const upR = resolveGesture(
		ctx({
			hit,
			activeTool: "open-session",
			modifiers: { shift: true, cmd: false, alt: false },
		}),
	);
	assert(downR.tier === "tool-create");
	assert(upR.tier === "default");
	assert(downR.verb.kind === "two-click-pick");
	assert(upR.verb.kind === "select-or-drag-peer");
});

// ─────────────────────── Inert surfaces under all tools ───────────────

Deno.test("Timeline ruler always resolves to scrub (tool doesn't override)", () => {
	for (const tool of ALL_TOOLS) {
		if (tool === "hand") continue; // hand-tool wins tier 2
		const r = resolveGesture(
			ctx({
				hit: dummyHit("timeline-ruler", { t: 1000 }),
				activeTool: tool,
			}),
		);
		assertEquals(r.tier, "default", `tool=${tool}`);
		if (r.tier === "default") assertEquals(r.verb.kind, "scrub");
	}
});

// ─────────────────────── Exhaustiveness ───────────────────────────────

Deno.test("surfaceDefault is total on SurfaceId", () => {
	for (const surface of ALL_SURFACES) {
		const verb = surfaceDefault(dummyHit(surface));
		assert(verb.kind, `${surface} → no default verb`);
	}
});
