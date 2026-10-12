/**
 * The two-click tools, over the two kinds of stage node.
 *
 * A message can name an end nothing has attributed: that is what the wire
 * looks like before anything proves who answered, and a recording holds it,
 * so Build has to be able to author it. What an end cannot do is join a
 * SECOND session, two ends claiming one address may be one host twice or an
 * impostor beside a real one, and nothing has proved which, so a node
 * shared between sessions would be this app asserting they are the same
 * party. The node that IS shared across sessions is the peer, and attributing
 * an end is how it becomes one.
 *
 * These drive `advanceTwoClick` the way the Stage does, through the arm step
 * and then the commit, because the arm is where the picked node is parked and
 * the commit is where the session is resolved.
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../../engine/engine.ts";
import { advanceTwoClick, twoClickAccepts } from "../two-click.ts";
import type { AppAction } from "../../state/app-state.ts";
import { type Hit, NO_MODIFIERS, type SelectionAction, type ToolState } from "../../interactions/types.ts";
import { cursorFor, type ToolWillPick } from "../../interactions/cursor.ts";
import { nodeKindOf } from "../../schema/session-end.ts";
import { engineTest, LOOSE_END, looseDoc } from "./harness.ts";

/** Drive both clicks of the tool, parking the first pick the way the app's
 *  reducer does, and report what the document holds afterwards. */
function twoClicks(
	e: Engine,
	tool: "open-session" | "send-message",
	first: string,
	second: string,
): void {
	let parked: string | null = null;
	const dispatch = ((action: AppAction) => {
		if (action.type === "set-first-pick") parked = action.nodeId;
	}) as React.Dispatch<AppAction>;
	const noSelection = (() => {}) as React.Dispatch<SelectionAction>;
	advanceTwoClick(e, tool, null, first, dispatch, noSelection);
	assertEquals(parked, first, "the first click did not arm the node");
	advanceTwoClick(e, tool, parked, second, dispatch, noSelection);
}

function messages(e: Engine) {
	return Object.values(e.doc.entities?.messages ?? {});
}

engineTest("a message can be sent to an end nothing has attributed", () => {
	const e = new Engine(looseDoc());
	twoClicks(e, "send-message", "carol", LOOSE_END);
	const sent = messages(e);
	assertEquals(sent.length, 1);
	assertEquals(sent[0]!.from, "carol");
	assertEquals(sent[0]!.to, LOOSE_END);
	// On the end's own session, which is the only one it is an end of.
	assertEquals(sent[0]!.sessionId, "s1");
});

engineTest("a loose end can receive and can send", () => {
	const e = new Engine(looseDoc());
	twoClicks(e, "send-message", LOOSE_END, "carol");
	const sent = messages(e);
	assertEquals(sent.length, 1);
	assertEquals(sent[0]!.from, LOOSE_END);
	assertEquals(sent[0]!.to, "carol");
});

engineTest("a loose end carries no message off its own session", () => {
	// Alice shares no session with this end, and one cannot be opened to it, so
	// there is nowhere for the message to ride. The refusal is the engine's:
	// the auto-open is what gets turned away.
	const e = new Engine(looseDoc());
	const said: string[] = [];
	e.onError((err) => said.push(err.detail));
	twoClicks(e, "send-message", "alice", LOOSE_END);
	assertEquals(messages(e).length, 0);
	assertEquals(Object.keys(e.doc.entities?.sessions ?? {}), ["s1"]);
	// Refusing in silence is the worst shape this can take: the gesture and
	// the document both look fine afterwards and the reader learns nothing.
	assert(said.length > 0, "the refusal said nothing");
});

engineTest("a session cannot be opened onto an end nothing attributed", () => {
	const e = new Engine(looseDoc());
	twoClicks(e, "open-session", "carol", LOOSE_END);
	assertEquals(
		Object.keys(e.doc.entities?.sessions ?? {}),
		["s1"],
		"a second session was opened onto an existing end",
	);
});

engineTest("two peers still open a session and send between them", () => {
	// The path everything above is an exception to: two peers with no session
	// between them get one, and the message rides it, in one undo step.
	const e = new Engine(looseDoc());
	twoClicks(e, "send-message", "carol", "alice");
	const sent = messages(e);
	assertEquals(sent.length, 1);
	const opened = Object.keys(e.doc.entities?.sessions ?? {});
	assertEquals(opened.length, 2, "no session was opened for the message");
	assert(
		opened.includes(sent[0]!.sessionId),
		"the message did not ride a session this document declares",
	);
});

// ─────────────────── what the second pick will take ───────────────────

function accepts(e: Engine, armed: string | null, id: string) {
	return twoClickAccepts(e, "send-message", armed, {
		kind: nodeKindOf(id),
		id,
	});
}

engineTest("with a loose end armed, only its own session's far end", () => {
	// The pointer must not read as an invitation over a node the commit would
	// refuse. An end nothing has
	// attributed can only talk on the session it is an end of, so that is the
	// only partner it has.
	const e = new Engine(looseDoc());
	assertEquals(accepts(e, LOOSE_END, "carol"), "takes");
	assertEquals(accepts(e, LOOSE_END, "alice"), "refuses");
});

engineTest("the same rule read from the other side", () => {
	const e = new Engine(looseDoc());
	assertEquals(accepts(e, "carol", LOOSE_END), "takes");
	assertEquals(accepts(e, "alice", LOOSE_END), "refuses");
});

engineTest("two peers may still pick each other with no session yet", () => {
	// The path the rule above must not break: a message between peers opens a
	// session if they need one, so any peer is a legal partner.
	const e = new Engine(looseDoc());
	assertEquals(accepts(e, "carol", "alice"), "takes");
});

engineTest("a first pick is never refused for its partner", () => {
	// Nothing is armed, so there is no partner to be wrong for; and re-picking
	// the armed node is how the gesture is cancelled.
	const e = new Engine(looseDoc());
	assertEquals(accepts(e, null, LOOSE_END), "takes");
	assertEquals(accepts(e, null, "alice"), "takes");
	assertEquals(accepts(e, LOOSE_END, LOOSE_END), "takes");
});

engineTest("Open Session refuses a loose end whatever is armed", () => {
	const e = new Engine(looseDoc());
	for (const armed of [null, "carol", "alice"]) {
		assertEquals(
			twoClickAccepts(e, "open-session", armed, {
				kind: "endpoint",
				id: LOOSE_END,
			}),
			"refuses",
		);
	}
});

// ─────────────────── what the pointer says over a node ───────────────────

/**
 * The cursor over a node, asked the way the Stage asks it: the app's one
 * cursor authority, handed the same `twoClickAccepts` the click path consults.
 * Testing anything less than `cursorFor` here would test a second function
 * that merely looks like the one shipping.
 */
function cursorOver(
	e: Engine,
	tool: "open-session" | "send-message",
	armed: string | null,
	id: string,
) {
	const willPick: ToolWillPick = ({ tool, armedNodeId, nodeId }) =>
		twoClickAccepts(e, tool, armedNodeId, {
			kind: nodeKindOf(nodeId),
			id: nodeId,
		}) === "takes";
	const hit: Hit = nodeKindOf(id) === "endpoint"
		? { surface: "stage-endpoint", endpointId: id }
		: { surface: "stage-peer", peerId: id };
	const toolState: ToolState | null = armed === null ? null : { tool, nodeId: armed };
	return cursorFor(
		{
			modifiers: NO_MODIFIERS,
			spaceHeld: false,
			activeTool: tool,
			toolState,
		},
		{
			fsm: { kind: "idle" },
			hover: { surface: hit.surface, hit },
		},
		willPick,
	);
}

engineTest("the pointer refuses exactly what the click refuses", () => {
	// These drifted apart once: a node read as a target and the click then
	// declined it. Both answers come from `twoClickAccepts`, and this is
	// the pair that has to agree, asserted against the cursor the app
	// actually draws, not a second one that merely looks like it.
	const e = new Engine(looseDoc());
	const cases: [string | null, string, "takes" | "refuses"][] = [
		[null, "alice", "takes"],
		[null, LOOSE_END, "takes"],
		[LOOSE_END, "carol", "takes"],
		[LOOSE_END, "alice", "refuses"],
		["alice", LOOSE_END, "refuses"],
		["carol", "alice", "takes"],
	];
	for (const [armed, target, verdict] of cases) {
		const kind = nodeKindOf(target);
		assertEquals(
			twoClickAccepts(e, "send-message", armed, { kind, id: target }),
			verdict,
			`send-message ${armed} -> ${target}`,
		);
		assertEquals(
			cursorOver(e, "send-message", armed, target),
			// Accepted, the pointer keeps the tool's own cursor; only a refusal
			// overrides it.
			verdict === "refuses" ? "not-allowed" : "copy",
			`cursor for ${armed} -> ${target}`,
		);
	}
});

engineTest("Open Session's pointer refuses an end nothing attributed", () => {
	const e = new Engine(looseDoc());
	assertEquals(cursorOver(e, "open-session", null, LOOSE_END), "not-allowed");
	assertEquals(cursorOver(e, "open-session", null, "alice"), "cell");
});
