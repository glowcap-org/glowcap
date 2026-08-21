/**
 * The left catalog rail — Tools, the buffer's source, and the Legend.
 *
 * AppView owns the handlers; this module owns the pane those handlers
 * fill. Live names the middle section Connection because there is no
 * document to describe; Play and Build name it Document.
 */

import type { Engine } from "../engine/engine.ts";
import type { SelectionAction } from "../interactions/types.ts";
import type { AppMode, BufferSourceInfo, BuilderTool, LayoutSizes } from "../state/app-state.ts";
import { leftPane, toolsPanel } from "./app-shell.ts";
import type { EditorBindings } from "./inspector/bindings.ts";
import { LegendBody, LegendReferenceButton } from "./Legend.tsx";
import { ResizeHandle } from "./ResizeHandle.tsx";
import { Section } from "./Section.tsx";
import { SourcePicker } from "./SourcePicker.tsx";
import { DiscardAllButton, ToolCommandRow, UndoAllButton, UnpinAllButton } from "./ToolCommands.tsx";
import { ToolPalette } from "./ToolPalette.tsx";

export function LeftRail({
  mode,
  tool,
  onPickTool,
  scenarioId,
  source,
  engine,
  liveSturdyref,
  liveConnected,
  liveObserved,
  liveRecording,
  onScenarioChange,
  onLiveSturdyrefChange,
  editor,
  dispatchSelection,
  onOpenReference,
  onResize,
}: {
  mode: AppMode;
  tool: BuilderTool;
  onPickTool: (tool: BuilderTool) => void;
  scenarioId: string;
  source: BufferSourceInfo | null;
  engine: Engine;
  liveSturdyref: string;
  liveConnected: boolean;
  liveObserved: boolean;
  liveRecording: boolean;
  onScenarioChange: (event: React.ChangeEvent<HTMLSelectElement>) => void;
  onLiveSturdyrefChange: (sturdyref: string) => void;
  editor: EditorBindings | undefined;
  dispatchSelection: React.Dispatch<SelectionAction>;
  onOpenReference: () => void;
  onResize: (
    updater: Partial<LayoutSizes> | ((s: LayoutSizes) => LayoutSizes),
  ) => void;
}) {
  return (
    <aside style={leftPane} className="ocv-pane">
      <Section title="Tools">
        <div style={toolsPanel} className="ocv-tools-panel">
          <ToolPalette mode={mode} tool={tool} onPick={onPickTool} />
          {
            /* Commands, not tools, so they sit under the strip with text
              labels rather than inside the radiogroup. They belong in
              this section because Tools is where the left pane keeps what
              acts on the composition; Source and Legend describe it. In
              rising order of what they take away. */
          }
          <ToolCommandRow mode={mode}>
            <UnpinAllButton engine={engine} mode={mode} />
            <UndoAllButton
              engine={engine}
              mode={mode}
              dispatchSelection={dispatchSelection}
            />
            <DiscardAllButton
              engine={engine}
              mode={mode}
              dispatchSelection={dispatchSelection}
            />
          </ToolCommandRow>
        </div>
      </Section>
      {
        /* Live has no document — it has a connection and a stream — so the
          panel says what there is to say in each case, and its own title
          names which. `DocumentFields` carries the description in Play and
          Build, so there is no second copy of it here. */
      }
      <Section title={mode === "live" ? "Connection" : "Document"}>
        <SourcePicker
          mode={mode}
          scenarioId={scenarioId}
          source={source}
          engine={engine}
          liveSturdyref={liveSturdyref}
          liveConnected={liveConnected}
          liveObserved={liveObserved}
          liveRecording={liveRecording}
          onScenarioChange={onScenarioChange}
          onLiveSturdyrefChange={onLiveSturdyrefChange}
          editor={mode === "build" ? editor : undefined}
        />
      </Section>
      <Section
        title="Legend"
        action={<LegendReferenceButton onOpen={onOpenReference} />}
      >
        <LegendBody />
      </Section>
      <ResizeHandle
        axis="x"
        edge="right"
        label="Left panel width"
        title="Drag or use the left and right arrow keys to resize"
        onDelta={(d) => onResize((s) => ({ ...s, leftPaneWidth: s.leftPaneWidth + d }))}
      />
    </aside>
  );
}
