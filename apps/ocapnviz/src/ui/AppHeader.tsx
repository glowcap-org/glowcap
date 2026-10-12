/**
 * The top bar: wordmark, mode, document commands, and chrome.
 *
 * AppView owns the handlers. This module owns the header those
 * handlers fill. Save/Open/New sit here in every mode because they
 * act on the buffer, not on the stage.
 */

import type { Engine } from "../engine/engine.ts";
import type { AppMode } from "../state/app-state.ts";
import { brand, breadcrumbCurrent, breadcrumbSep, headerSpacer, topBar, wordmark } from "./app-shell.ts";
import { Brandmark } from "./Brandmark.tsx";
import { ReferenceButton } from "./reference/Reference.tsx";
import { ThemeToggle } from "./ThemeToggle.tsx";
import { ModeToggle, SaveOpenControls, UndoRedoControls } from "./topbar.tsx";
import type { Theme } from "./tokens.ts";

export function AppHeader({
	title,
	mode,
	liveRecording,
	engine,
	onModeChange,
	onUndo,
	onRedo,
	onNew,
	onSave,
	onOpen,
	onResetLayout,
	theme,
	onToggleTheme,
	onOpenReference,
}: {
	title: string;
	mode: AppMode;
	liveRecording: boolean;
	engine: Engine;
	onModeChange: (mode: AppMode) => void;
	onUndo: () => void;
	onRedo: () => void;
	onNew: () => void;
	onSave: () => void;
	onOpen: () => void;
	onResetLayout: () => void;
	theme: Theme;
	onToggleTheme: () => void;
	onOpenReference: () => void;
}) {
	return (
		<header style={topBar}>
			<div style={brand}>
				<Brandmark size={20} />
				<span style={wordmark}>ocapnviz</span>
				<span style={breadcrumbSep} aria-hidden="true">/</span>
				<span style={breadcrumbCurrent}>{title}</span>
			</div>
			<span style={headerSpacer} />
			<ModeToggle
				mode={mode}
				recording={liveRecording}
				onChange={onModeChange}
			/>
			{mode === "build" && engine && (
				<UndoRedoControls
					engine={engine}
					onUndo={onUndo}
					onRedo={onRedo}
				/>
			)}
			{
				/* New/Save/Open available in all modes, Save persists the
          buffer (recording / fixture / file), and New and Open both
          replace it. */
			}
			<SaveOpenControls
				recording={liveRecording}
				onNew={onNew}
				onSave={onSave}
				onOpen={onOpen}
			/>
			<button
				type="button"
				className="ocv-btn is-ghost"
				onClick={onResetLayout}
				title="Reset panel sizes, layer visibility, and the timeline view"
			>
				Reset layout
			</button>
			<ThemeToggle theme={theme} onToggle={onToggleTheme} />
			<ReferenceButton onOpen={onOpenReference} />
		</header>
	);
}
