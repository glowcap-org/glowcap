/**
 * The tools a surface can have active (§ 2.4 of `docs/interaction-model.md`).
 *
 * `AppMode` is NOT here, modes are a UI shortcut, not an architectural
 * concept (§ 1.1 of the doc). The resolver and FSM never read mode. They read
 * `activeTool`.
 */

/**
 * The tools that mean something on every surface, because both are about
 * getting around rather than about authoring: Select picks what is under the
 * pointer, and Hand moves the view.
 */
export type NavigationTool = "select" | "hand";

/**
 * The tools that build a document, all of which act on the Stage and only
 * there: `add-peer` on empty canvas, the two-click tools on a peer or a session
 * end. `STAGE_SURFACES` is the set they can reach.
 */
export type AuthoringTool = "add-peer" | "open-session" | "send-message";

export type BuilderTool = NavigationTool | AuthoringTool;

/**
 * The navigational half of a tool, which is all a surface outside the Stage can
 * act on.
 *
 * An authoring tool answers `select` rather than being refused, because that is
 * what those surfaces already do: the Timeline's hosts never read the active
 * tool on the way to a click, so a lane click selects whatever tool is chosen.
 * Naming that here makes the Timeline's cursor agree with the Timeline's click
 * in both directions. No build-tool cursor promising something a lane cannot
 * do, and no missing selection preview under a modifier the lane does honour.
 */
export function navigationToolOf(tool: BuilderTool): NavigationTool {
	return tool === "hand" ? "hand" : "select";
}

/**
 * A tool that picks two nodes in turn: one click arms a node, the next names
 * its partner. One list, so a third such tool is added in one place, and
 * `isTwoClickTool` is its runtime reading, for the surfaces that hold a
 * `BuilderTool` and need to know which kind they have.
 */
export type TwoClickTool = "open-session" | "send-message";

export function isTwoClickTool(tool: BuilderTool): tool is TwoClickTool {
	return tool === "open-session" || tool === "send-message";
}

/** Two-click tools maintain in-flight state: the node already picked and
 *  waiting for its partner. Null when no two-click sequence is mid-flight.
 *
 *  A node, not a peer, Send Message arms an end nothing has attributed
 *  exactly as it arms a peer, so `nodeId` may be an endpoint's stage id.
 *
 *  The host owns it: the Stage holds the armed pick in its `armedNode` prop
 *  and hands it to the cursor as `CursorContext.toolState`. The resolver is
 *  not told, because a pick resolves from the tool and the node alone. */
export type ToolState =
	| { tool: "open-session"; nodeId: string }
	| { tool: "send-message"; nodeId: string };
