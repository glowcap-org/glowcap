import type { TraceEvent } from "@glowcap/runtime";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import type { VizPublisher } from "../../lib/viz_publish.ts";
import { roomsReconciliationNeedsRetry } from "../../session/reconnect.ts";
import { DurableRoomsViz } from "../../session/viz.ts";
import { assertEquals } from "../assert.ts";

Deno.test("a durable session owns exactly one visualizer publisher for its saved capability", () => {
	const starts: {
		url: string;
		cap: string;
		hooks: {
			onError: (error: unknown) => void;
			onRefused: (reason: string) => void;
			onStatus: (connected: boolean) => void;
		};
		stopped: boolean;
	}[] = [];
	let installs = 0;
	let uninstalls = 0;
	const issues = new Map<string, unknown>();
	const invalidated: string[] = [];
	const viz = new DurableRoomsViz(
		(subject, error) => {
			if (error == null) issues.delete(subject);
			else issues.set(subject, error);
			return true;
		},
		(scope) => invalidated.push(scope),
		(url, hooks) => {
			const started = { url, cap: hooks.cap, hooks, stopped: false };
			starts.push(started);
			return {
				sink: (_event: TraceEvent) => {},
				stop: () => started.stopped = true,
			} satisfies VizPublisher;
		},
		(_sink) => {
			installs += 1;
			return () => uninstalls += 1;
		},
	);
	const base = emptyRoomsSessionState();
	const saved = {
		...base,
		capabilities: {
			...base.capabilities,
			operations: [{ capability: "viz" as const, scope: "ws://timeline.test/viz", swiss: "first" }],
		},
	};

	viz.reconcile(saved);
	assertEquals(starts.map(({ url, cap }) => ({ url, cap })), [
		{ url: "ws://timeline.test/viz", cap: "first" },
	]);
	assertEquals(installs, 1);
	viz.reconcile(saved);
	assertEquals(starts.length, 1);
	starts[0].hooks.onStatus(true);
	assertEquals(viz.snapshot("ws://timeline.test/viz"), {
		capability: "viz",
		url: "ws://timeline.test/viz",
		connected: true,
		refusal: null,
	});

	viz.reconcile({
		...saved,
		capabilities: {
			...saved.capabilities,
			operations: [{ ...saved.capabilities.operations[0], swiss: "second" }],
		},
	});
	assertEquals(starts.length, 2);
	assertEquals(starts[0].stopped, true);
	assertEquals(uninstalls, 1);
	starts[1].hooks.onRefused("wrong capability");
	assertEquals(issues.get("capability:viz\u0000ws://timeline.test/viz") instanceof Error, true);
	assertEquals(
		(issues.get("capability:viz\u0000ws://timeline.test/viz") as Error).message,
		"wrong capability",
	);
	assertEquals(viz.snapshot("ws://timeline.test/viz"), {
		capability: "viz",
		url: "ws://timeline.test/viz",
		connected: false,
		refusal: "wrong capability",
	});
	assertEquals(uninstalls, 2);

	viz.reconcile(base);
	assertEquals(starts[1].stopped, true);
	assertEquals(uninstalls, 2);
	assertEquals(issues.size, 0);
	assertEquals(invalidated.length >= 4, true);
});

Deno.test("a visualizer publisher is stopped when its trace tap cannot install", () => {
	const base = emptyRoomsSessionState();
	let stopped = false;
	let issue: unknown = null;
	const viz = new DurableRoomsViz(
		(_subject, error) => {
			issue = error;
			return true;
		},
		() => {},
		() => ({ sink: () => {}, stop: () => stopped = true }),
		() => {
			throw new Error("trace unavailable");
		},
	);
	viz.reconcile({
		...base,
		capabilities: {
			...base.capabilities,
			operations: [{ capability: "viz", scope: "ws://timeline.test/viz", swiss: "cap" }],
		},
	});
	assertEquals(stopped, true);
	assertEquals(issue instanceof Error ? issue.message : issue, "trace unavailable");
	let refused = false;
	try {
		viz.snapshot("ws://timeline.test/viz");
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
});

Deno.test("visualizer retirement uninstalls tracing even when publisher stop refuses", () => {
	const base = emptyRoomsSessionState();
	let uninstalls = 0;
	let issue: unknown = null;
	const viz = new DurableRoomsViz(
		(_subject, error) => {
			issue = error;
			return true;
		},
		() => {},
		() => ({
			sink: () => {},
			stop: () => {
				throw new Error("publisher stop refused");
			},
		}),
		() => () => uninstalls += 1,
	);
	viz.reconcile({
		...base,
		capabilities: {
			...base.capabilities,
			operations: [{ capability: "viz", scope: "ws://timeline.test/viz", swiss: "cap" }],
		},
	});
	let refusal = "";
	try {
		viz.reconcile(base);
	} catch (error) {
		refusal = error instanceof Error ? error.message : String(error);
	}
	assertEquals(refusal, "publisher stop refused");
	assertEquals(uninstalls, 1);
	assertEquals(issue instanceof Error ? issue.message : issue, "publisher stop refused");
});

Deno.test("a visualizer issue does not schedule another directory reconciliation", () => {
	const checkpoint = emptyRoomsSessionState();
	assertEquals(
		roomsReconciliationNeedsRetry(checkpoint, new Set(), ["capability:viz\u0000ws://timeline.test/viz"], false),
		false,
	);
	assertEquals(
		roomsReconciliationNeedsRetry(checkpoint, new Set(), ["capability:operator\u0000home"], false),
		true,
	);
});
