/**
 * A recording stand-in for the shortcut table's host callbacks.
 *
 * Test support, shared by the two keyboard test files so that "what
 * did this key actually do" is spelled one way. Every binding
 * pushes a label onto `calls`, so a test asserts on a list of what
 * ran instead of on a pile of spies.
 */

import type { KeyboardShortcutBindings } from "./keyboard-shortcuts.ts";
import type { AppMode } from "./app-state.ts";
import type { Engine } from "../engine/engine.ts";

export type RecordedBindings = {
	b: KeyboardShortcutBindings;
	/** What ran, in order. */
	calls: string[];
};

export function recordingBindings(opts?: {
	mode?: AppMode;
	/** Whether a Build nudge claims the arrow key. */
	nudgeConsumes?: boolean;
}): RecordedBindings {
	const calls: string[] = [];
	// The engine's own history verbs record under a different name from
	// the host callbacks below, so a row that reached past the host and
	// commanded the engine directly shows up as itself. Taking history
	// back also walks the selection back, and only the host does that.
	const engine = {
		clock: { t: 5_000, duration: 60_000 },
		enqueue: (cmd: { kind: string }) => calls.push(`enqueue:${cmd.kind}`),
		undo: () => calls.push("engine.undo"),
		redo: () => calls.push("engine.redo"),
	} as unknown as Engine;
	const b: KeyboardShortcutBindings = {
		engine,
		mode: opts?.mode ?? "play",
		onDeselect: () => calls.push("deselect"),
		onDelete: () => calls.push("delete"),
		onSelectAll: () => calls.push("select-all"),
		onSave: () => calls.push("save"),
		onOpen: () => calls.push("open"),
		onPickTool: (tool) => calls.push(`tool:${tool}`),
		onUndo: () => calls.push("undo"),
		onRedo: () => calls.push("redo"),
		onCopySelection: () => calls.push("copy"),
		onPasteClipboard: () => calls.push("paste"),
		onDuplicateSelection: () => calls.push("duplicate"),
		onNudgeSelection: () => {
			calls.push("nudge");
			return opts?.nudgeConsumes ?? false;
		},
	};
	return { b, calls };
}
