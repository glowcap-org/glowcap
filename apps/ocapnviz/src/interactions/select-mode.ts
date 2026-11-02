// The modifier grammar of a selection gesture (§ 2.4 of `docs/interaction-model.md`).

/** Modifier-resolved intent of a selection gesture (click or
 * marquee), one grammar across every surface, stage sprites, stage
 * marquee, timeline pills, timeline marquee, so the same modifier
 * combo means the same thing wherever the user selects:
 *   plain          → replace   (selection becomes the hits)
 *   shift          → add       (already-in is a no-op)
 *   shift+option   → remove    (not-in is a no-op)
 *   option alone   → reserved  (a surface may bind it locally,
 *                    e.g. the timeline's pan)
 * The interpretation of a mode against the selection also has one
 * home: `selection-store.ts`'s `selectionActionFor`. */
export type SelectMode = "replace" | "add" | "remove";

/** Map a captured modifier snapshot to a {@link SelectMode}. */
export function selectModeFromModifiers(
	m: { shiftKey: boolean; altKey: boolean },
): SelectMode {
	if (m.shiftKey && m.altKey) return "remove";
	if (m.shiftKey) return "add";
	return "replace";
}
