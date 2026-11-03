/**
 * What the pointer and keyboard report at one instant (§ 2.2 of
 * `docs/interaction-model.md`). No React, no Pixi, no DOM, so trivially
 * fixturable.
 */

export type ModifierSet = {
	shift: boolean;
	cmd: boolean;
	alt: boolean;
};

export const NO_MODIFIERS: ModifierSet = {
	shift: false,
	cmd: false,
	alt: false,
};

export type PointerSnapshot = {
	clientX: number;
	clientY: number;
	/** Bitmask: 1 = primary, 2 = secondary, 4 = middle. */
	buttons: number;
	modifiers: ModifierSet;
	timestampMs: number;
};
