# Cursor

The interaction pipeline lives in [`interaction-model.md`](interaction-model.md).
This page is the one cursor rule `cursor.ts` implements.

`cursorFor` in `cursor.ts` is the app's one cursor authority. Sprites carry no
cursor of their own and no component spells the rule a second time.

Three elements can carry a cursor, because the timeline's two DOM hosts sit
above the canvas and take the pointer where they overlap it. Each has exactly
one writer and each writes this function's answer. The Stage asks once per frame
and hands the answer to `UnifiedCanvas.setCursor`, the only writer of the canvas
cursor. The Scrubber and the Overview ask on every pointer move through
`timeline-cursor.ts`, which turns a position on either host into a `Hit` and
calls the same function.

The cursor is the tool's promise about what the next click will do, so it is
derived from the same resolver that click goes through and the same machine
state that runs it. The ladder mirrors `interaction-model.md` § 4.2:

1. A gesture the machine holds is what is happening, and it outranks everything
   below. A pan reads `grabbing`, a marquee `crosshair`, a peer drag `move`.
   Only the machine can answer this, which is why releasing Space during a pan
   leaves a pan and releasing it during an interrupted marquee puts the marquee
   back.
2. Space held reads `grab`.
3. The Hand tool reads `grab`.
4. With no hover, `default`. Off every surface there is no next click to
   describe.
5. Over a hover, resolve the gesture for that hit and read the answer.

That last step has its own order. A `tool-refuses` reads `not-allowed`, and so
does a two-click pick that the host's `willPick` declines; the tool works on
nodes and will not take this one, and the cursor says so before the click rather
than an error saying so after it. Any other tool-create reads the tool's own
resting cursor, because the node it is about to act on is the last place to stop
saying which tool is active. Under the Select tool, a verb that commits into the
selection reads `copy` under Shift and `no-drop` under Shift-Option. The mode
comes from `selectModeFromModifiers`, so the preview and the commit read one
grammar, and a surface whose verb does not touch the selection keeps its own
cursor under a held modifier. A build tool's resting cursor stays on stage
surfaces only (`restingCursorOver` / `isStageSurface`); over the timeline the
lane's own answer wins, so the affordance does not advertise a click no timeline
surface performs.

Otherwise the resolved verb answers. Two glyphs carry the horizontal gestures
and they are not interchangeable. `ew-resize` means the drag moves something
along time: a scrub, a retimed event, the ends of the overview window.
`col-resize` means a handle that resizes an extent: an event pill's edge, the
gutter's seam. The rest are `pointer` for anything whose click acts on what is
under it, including the gutter's chevron, eyeballs, and row labels; `grab` for
the Overview's pan; and `crosshair` for a marquee.

A row label reads `pointer` rather than a vertical resize cursor, because its
click selects the row's entity and only its drag reorders the stack. The click
is what the cursor is describing, and the reorder is a discovered affordance.
While the row is moving, the in-flight step answers `grabbing`.

**`willPick` is the injected half.** Whether a two-click tool will take the node
under the pointer depends on the pick it already holds, and that is a fact about
the document. With a claim armed, the only legal partner is the node at the
other end of that claim's session, and no `GestureContext` can see it. The Stage
supplies `twoClickAccepts` from `builder/two-click.ts`, the same statement the
click path consults, so the pointer refuses exactly what the click refuses. Left
out, the cursor answers with the half the resolver can see, which is the whole
answer until a pick is armed. The armed pick travels in
`CursorContext.toolState`, filled from the Stage's `armedNode`, and it is the
cursor's context rather than the resolver's, because the resolver never asks.

**What the Stage feeds it.** The machine state, with one addition.
`makeStageHit` returns null over a sprite, so the machine's hover is empty in
exactly the places the pointer is over something; the Pixi hover is that same
fact arriving by the other door, and the Stage folds it in before asking.
Modifiers come from the app's one keyboard listener rather than a pointer event,
because a modifier pressed while the pointer sits still still changes what the
next click would do.

**What the timeline feeds it.** `timeline-cursor.ts` holds the geometry and none
of the rule. `scrubberHoverAt` walks the Scrubber's zones in the order the
pointer-down handler reads them, the gutter seam, then the gutter controls, then
the scrub zone, then the lanes, and `overviewHitAt` does the same for the strip.
Each returns the hit the pointer is over, or null where a press would do
nothing. In Live mode the scrub zone returns null rather than a ruler hit,
because the feed only goes forward and the press is refused; the cursor falls to
the no-hover step and reads `default`, because nothing will happen on click.

Both hosts pass the App's own `SurfaceGestureCtx`, the same value the Stage
gets, so a modifier held over a lane previews the same selection edit it
previews over the stage, and Space or Hand still carry their navigation cursor
across the panel edge. A build tool's resting cursor does not: the timeline hosts
narrow the tool through `navigationToolOf`, and `restingCursorOver` refuses any
surface outside the stage. The one thing the timeline adds is a null
`toolState`, because a two-click pick arms on a stage node and no timeline
surface is one.

The in-flight step is the one thing these hosts cannot read off a hit, because
they still run their own drag loops. Each names the verb it started with, in the
`interaction-model.md` § 4.5 vocabulary, and hands it back through
`TimelineGesture`, so a scrub that wanders into the gutter still reads as a
scrub and the answer comes out of the same table.

