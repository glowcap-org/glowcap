/**
 * The Inspector rail, Details and Connections for what is shown.
 *
 * What the pane shows is not always what is selected: Live keeps a
 * selection so returning to Play restores it, and that selection can
 * name entities the live stream has never mentioned. AppView derives
 * `shown` once. This rail reads it for titles and bodies alike.
 */

import type { Engine } from "../engine/engine.ts";
import type { EntityRefKey } from "../interactions/types.ts";
import type { LayoutSizes } from "../state/app-state.ts";
import type { StageSelection } from "../render/types.ts";
import { rightPane } from "./app-shell.ts";
import type { EditorBindings } from "./inspector/bindings.ts";
import { ResizeHandle } from "./ResizeHandle.tsx";
import { Section } from "./Section.tsx";
import { connectionsSectionTitle, EntityConnections, EntityDetails } from "./Sidebar.tsx";

export function InspectorRail({
	engine,
	shown,
	inspectorKey,
	onSelect,
	editor,
	onNarrowSelection,
	onResize,
}: {
	engine: Engine;
	shown: {
		anchor: StageSelection;
		selection: ReadonlySet<EntityRefKey> | undefined;
	};
	inspectorKey: string;
	onSelect: (sel: StageSelection) => void;
	editor: EditorBindings | undefined;
	onNarrowSelection: (entities: ReadonlySet<EntityRefKey>) => void;
	onResize: (
		updater: Partial<LayoutSizes> | ((s: LayoutSizes) => LayoutSizes),
	) => void;
}) {
	return (
		<aside style={rightPane} className="ocv-pane">
			<ResizeHandle
				axis="x"
				edge="left"
				label="Right panel width"
				title="Drag or use the left and right arrow keys to resize"
				onDelta={(d) =>
					onResize((s) => ({
						...s,
						rightPaneWidth: s.rightPaneWidth - d,
					}))}
			/>
			{
				/* Section title swaps: "DETAILS" when nothing is
          selected (consistent with sibling sections, the pane
          reads as a labeled empty placeholder), then *replaced*
          by the entity's own heading (name + pill, rendered
          inside the body) once a selection lands. The two
          never coexist, when a heading is present it IS the
          label, so a "DETAILS" header above it would only
          duplicate the FieldGroup "Details" rectangle title
          further down.

          Decided from `shown`, not from the selection: in Live the
          selection is kept so returning to Play restores it, and
          it names entities the live stream has never heard of.
          Every part of the pane reads `shown` for that reason,
          `inspectorView` is where the two are told apart, and a
          part that asked for itself is how a titleless empty pane
          got in. */
			}
			<Section {...(shown.anchor ? {} : { title: "Details" })}>
				<div
					className="ocv-inspector-swap"
					key={`details-${inspectorKey}`}
				>
					<EntityDetails
						engine={engine}
						anchor={shown.anchor}
						onSelect={onSelect}
						editor={editor}
						entitySelection={shown.selection}
						onNarrowSelection={onNarrowSelection}
					/>
				</div>
			</Section>
			<Section title={connectionsSectionTitle(engine, shown.anchor)}>
				<div
					className="ocv-inspector-swap"
					key={`connections-${inspectorKey}`}
				>
					<EntityConnections
						engine={engine}
						anchor={shown.anchor}
						onSelect={onSelect}
						entitySelection={shown.selection}
					/>
				</div>
			</Section>
		</aside>
	);
}
