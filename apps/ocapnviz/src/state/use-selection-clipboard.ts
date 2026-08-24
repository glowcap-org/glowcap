/**
 * App clipboard slot for copy / paste / duplicate.
 *
 * The engine does not carry clipboard state. This hook holds one
 * payload in a ref so it survives re-renders and mode changes
 * (Build → Play → Build) without forcing them. Closing or reloading
 * the tab clears it, same as a system clipboard on a session
 * boundary.
 */

import { useCallback, useRef } from "react";
import type { Engine } from "../engine/engine.ts";
import type { ClipboardPayload } from "../engine/schema/clipboard.ts";
import type { IdRemap } from "../engine/schema/paste.ts";
import { type EntityRefKey, parseEntityKey } from "../interactions/types.ts";

export type SelectionClipboard = {
	handleCopySelection: () => void;
	handlePasteClipboard: () => void;
	handleDuplicateSelection: () => void;
};

export function useSelectionClipboard(
	engine: Engine,
	selection: ReadonlySet<EntityRefKey>,
	onSetSelection: (entities: ReadonlySet<EntityRefKey>) => void,
): SelectionClipboard {
	const clipboardRef = useRef<ClipboardPayload | null>(null);

	const selectionToPayloadInput = useCallback(() => {
		const peers = new Set<string>();
		const sessions = new Set<string>();
		const messages = new Set<string>();
		for (const key of selection) {
			const { kind, id } = parseEntityKey(key);
			if (kind === "peer") peers.add(id);
			else if (kind === "session") sessions.add(id);
			else if (kind === "message") messages.add(id);
		}
		return { peers, sessions, messages };
	}, [selection]);

	const remapToSelectionKeys = useCallback(
		(remap: IdRemap): Set<EntityRefKey> => {
			const out = new Set<EntityRefKey>();
			for (const [, newId] of remap.peer) out.add(`peer:${newId}`);
			for (const [, newId] of remap.session) out.add(`session:${newId}`);
			for (const [, newId] of remap.message) out.add(`message:${newId}`);
			return out;
		},
		[],
	);

	const handleCopySelection = useCallback(() => {
		if (selection.size === 0) return;
		clipboardRef.current = engine.extractPayload(selectionToPayloadInput());
	}, [engine, selection, selectionToPayloadInput]);

	const handlePasteClipboard = useCallback(() => {
		if (!clipboardRef.current) return;
		const r = engine.paste(clipboardRef.current);
		if (r.ok) {
			const newKeys = remapToSelectionKeys(r.value.remap);
			if (newKeys.size > 0) onSetSelection(newKeys);
		}
	}, [engine, onSetSelection, remapToSelectionKeys]);

	const handleDuplicateSelection = useCallback(() => {
		if (selection.size === 0) return;
		const r = engine.duplicate(selectionToPayloadInput());
		if (r.ok) {
			const newKeys = remapToSelectionKeys(r.value.remap);
			if (newKeys.size > 0) onSetSelection(newKeys);
		}
	}, [
		engine,
		selection,
		selectionToPayloadInput,
		onSetSelection,
		remapToSelectionKeys,
	]);

	return {
		handleCopySelection,
		handlePasteClipboard,
		handleDuplicateSelection,
	};
}
