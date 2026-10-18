---
type: static
description: Why the layout solver keeps one era per topology moment instead of collapsing moments that fall close together.
sources:
  - resource: /apps/ocapnviz/src/engine/systems/
---

# An era is what is standing at its moment

The layout solver keeps one era per topology moment and puts no bound on their number. The module headers of
`keyframe-layout-system.ts` and `layout-eras.ts`, and `era-reuse.test.ts`, cite this page for that decision. If a bound
is ever found, supersede this page with an ADR.

## What an era holds

An era's node set comes from the same effective ranges that `sessionsOnStageAt` in `stage-topology.ts` reads, and that
module's header names them as the authority for what is standing. The set is derived, never accumulated. An
accumulated set never drops a closed session's loose end. A loose end is not a claim, so `planClaimPlacements` gives it
no segment, and it falls through to `nodes` as a free body with `chargeStrength: -3600` at the origin. On a recording
that churns, hundreds of these invisible bodies pile at the center and push every real peer outward, and the drift
grows without bound.

## Two eras with the same problem are one era

An era whose solver inputs equal the last emitted era's is not emitted. The key is everything `runForce` reads for
that era: the nodes, each node's pin, claim and footprint, and the wires as pair-plus-id. Two parts of the key look
omittable and are not:

- **Pins and claims.** They are constant within one computation, but reuse compares the key across computations, so a
  key without them would reuse a layout that still holds a cleared pin.
- **Session ids.** The solver reads an id only to count lanes, but `bundleIndices` sorts the ids that share a pair and
  indexes them by position, so which lane a session takes depends on which ids are on that pair. Two eras with the same
  pairs under different ids are different problems, and merging them leaves a claim leaning on a lane its arc is
  not drawn along.

## An unchanged era keeps its arrangement

When an era's problem is unchanged, a recompute reuses the arrangement the era already holds, so an append does not
re-anneal a timeline that is already solved. Sixty reconnects cost 4.7 s of solving without reuse and 194 ms with it.

## An ease starts from where the picture was

Each era carries the arrangement the picture held when the era began. An era replaced two milliseconds after it
arrived was never approached, so easing from the previous keyframe would move every node somewhere it had never been,
in one frame. Measured on a reconnect, that throws the room 283.8 world units and pulls it back over the transition
window. Starting from where the picture was keeps the excursion under 6 units, a tenth of a node's own width.

`sealEras` works out each era's start once per recompute and is the only producer of keyframes, because where an era
eases from depends on its position in the list. Walking back over short eras inside `update` instead costs O(eras) per
node per frame: 4.43 microseconds per update, against 1.55 for the sealed start. Swapping a reused arrangement into an
era while setting the era's own start made that era snap, and `era-reuse.test.ts` holds that case at 125 world units.

## No time threshold merges eras

Collapsing moments that fall close together does not remove a flicker. A batch takes the first change's `t`, and
`containsTime` is half-open, so a batch stamped at a session's opening still reports the session on stage and keeps
its link until the next change. Each candidate threshold also fails on its own terms:

- **One frame (16 ms).** `tick` advances sim time by `wallDt * speed`, and speed reaches 4×, so the same era is 16 ms
  at one speed and 67 at another.
- **The transition window (600 ms).** It deletes eras a document states 100 ms apart, and thirteen tests on the
  bundled fixtures fail.

Every era gets its keyframe, so a `seekTo` landing inside a short one finds the topology the document states there,
and the result stays a pure function of `t`.

## Evidence

`era-reuse.test.ts` holds these cases. Each was shown red against an injection of the defect it names.

- The widest era does not grow with the number of reconnects. While a reconnect's session stands, its loose end really
  is a node and the era covering that moment holds it, so the count is what must not grow.
- Every peer sits where it sat once a reconnect has settled.
- A moment presenting the solver a problem it has already been asked is not an era.
- A recompute hands back the _same layout object_ for an era whose problem is unchanged, so no solve ran.
- A second wire on a pair that already has one is its own era, and so is a moment where the same pairs are carried by
  different session ids.
- A placement edit leaves a reused era easing from where the picture was. Dragging a loose end reaches the case: the pin
  names a node the earlier era does not hold, so that era reuses unconditionally while the later one reuses on the pin,
  and the two arrangements differ because one draws a session the other does not.
- A reconnect does not throw the room and pull it back. This case samples every frame across the flicker, because the
  excursion is visible only during it. The cases above wait for the layout to settle, so they cannot see it.

## Recordings with connection churn

`zig build rooms-web-trace-lifecycle` holds Rooms to no churn: it observes two joined browser members for thirteen idle
seconds and refuses any session opening, closing, or loss of observation, including transient replacements. That check
does not cover every producer, so the layout handles recordings that open and close sessions every few seconds.
