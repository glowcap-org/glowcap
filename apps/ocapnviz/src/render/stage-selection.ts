/**
 * What the Stage rings: the picked entity, the hovered one, and how strongly
 * each is ringed.
 *
 * Stage.tsx is a React host, so importing these from it pulls in Pixi + React
 * for any consumer that just wants a `StageSelection` shape. This module holds
 * them as pure data so the renderer, the timeline panels, the inspector, and
 * `app-state.ts` can depend on them without the host.
 */

import type { EntityRef } from "../interactions/entity-ref.ts";

/** How strongly a node, edge, or dot is ringed. "Anchor is a strict subset of
 *  selected". The two booleans collapse into one tier. "anchor" paints the
 *  selected outer ring plus a second inner ring, so under multi-select the
 *  user can see WHICH selected entity the Inspector follows. Single-select is
 *  "anchor" too. The inner ring reads fine when only one thing is selected. */
export type HaloTier = "none" | "selected" | "anchor";

/**
 * What one entity is picked, or nothing.
 *
 * An `EntityRef`, because the four kinds a reader can pick on the stage are the
 * four the rest of the app already names, and this file spelled them out a
 * second time, in a union that had to hold the same four and its own copy of the
 * note about what an endpoint is. `EntityKind` enumerates them, so the alias
 * refuses exactly what the union refused.
 *
 * The name stays, because "the stage's current selection" is worth saying in one
 * word and reads better than `EntityRef | null` at every use.
 */
export type StageSelection = EntityRef | null;

export type StageHover = StageSelection;
