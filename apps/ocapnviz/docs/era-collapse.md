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

## What the first plan got wrong

The first plan collapsed topology moments that fall within one frame of each other, so a session that opens and closes 2
ms apart would net out before any solve. Two things were wrong.

**The collapse would not have netted out.** A batch was stamped with the first change's `t`, and `containsTime` is
half-open. A batch stamped at the open still reports the session on stage, so the merged era keeps the flicker's link
and holds it until the next change six seconds later. It looked right on the measured feed only because every flicker
links the same pair, and `runForce` never reads a link's id. A room whose churn touched different pairs would still
swing.

**The real cause was not eras at all.** The fold this replaced, `applyChange`, added both endpoint node ids to an
accumulating `peers` set on `session-in`, and nothing ever removed them. `peer-out` only reached ids that a `peer-joined`
or a declared peer named, and a loose end's stage id is neither. Measured over six churn cycles with a loose far end:

```
before churn:      2 nodes,  3 keyframes
after 6 churns:    8 nodes, 15 keyframes
node ids: alice rooms live-s0::b live-s1::b … live-s5::b
```

Every closed session left a permanent, invisible body in every later era. There it is not a claim, so
`planClaimPlacements` gives it no segment, and it falls through to `nodes` as a free body with `chargeStrength: -3600`,
seeded in the default region at the origin. With the observed counter at 258, roughly 258 bodies piled at the center of
the picture and pushed every real peer outward. One more arrived every six seconds and disturbed the equilibrium of
every era, so the drift grew without bound in both cost and displacement. Warm-starting the solver could not help,
because the problem itself had gained a body.

## The fix, in dependency order

**1. An era's node set is what is standing at its moment.** Derive it from the same effective ranges `sessionsOnStageAt`
in `stage-topology.ts` already reads (that module's header names them as the authority for what is standing), and
delete the accumulating fold. This changes what an era _is_, so it comes first, and everything else follows its shape.
The set was also named `peers` while it held both peers and endpoint stage ids, and that misleading name is what let
the leak hide.

**2. Two eras presenting the same problem are one era.** Skip emitting an era whose solver inputs equal the last emitted
era's. The key is everything `runForce` reads for that era: the nodes, each node's pin, claim and footprint, and the
wires as pair-plus-id.

The key must include two things that look omittable:

- Pins and claims. They are constant within one computation, but step 3 compares the key _across_ computations, so a
  key without them reused a layout that still had a cleared pin.
- Session ids. The solver reads an id only to count lanes, but `bundleIndices` sorts the ids that share a pair and
  indexes them by position, so which lane a session takes depends on which ids are on that pair. Two eras with the same
  pairs under different ids are different problems. Collapsing them left a claim leaning on a lane its arc was not drawn
  along.

**3. An era reuses the arrangement it already holds** when its problem is unchanged. This stops an append from
re-annealing a timeline that was already solved. Sixty reconnects cost 4.7 s of solving without it and 194 ms with it.

**4. The ease starts from where the picture was.** With the accumulated bodies gone, a reconnect still threw
the room and pulled it back: 283.8 world units on the first frame after the flicker, then an ease home over the
transition window.

`update` eased from the previous keyframe's arrangement, which is right whenever that era lasted a full window and wrong
when it did not. An era replaced two milliseconds after it arrived was never approached, so starting there put every
node somewhere it had never been, in one frame. Each era now carries the arrangement the picture held when it
began, so an era that lasted two milliseconds contributes two milliseconds' worth. The excursion is under 6 units, a
tenth of a node's own width.

Walking back over eras too short to have finished, inside `update`, is O(eras) per node per frame. It measured 4.43
microseconds per update, against 1.55 for working out each era's start once. So `sealEras` computes the starting
arrangement once per recompute.

`sealEras` is the only producer of keyframes, because where an era eases from depends on its position in the list, not
on the era itself. Swapping a reused arrangement into an era while setting the era's own start made that era snap.
`era-reuse.test.ts` holds that case at 125 world units.

No threshold decides anything, because two were tried and measured wrong:

- **One frame (16 ms).** Not a fixed number of simulated milliseconds: `tick` advances sim time by `wallDt * speed` and
  speed reaches 4×, so the same era is 16 ms at one speed and 67 at another.
- **The transition window (600 ms).** Deletes eras a document legitimately states 100 ms apart. Thirteen tests failed on
  the bundled fixtures.

Every era still gets its keyframe, so a `seekTo` landing inside a short one finds the topology the document states
there, and the result stays a pure function of `t`.

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
  excursion is visible only during it. The cases above wait for the layout to settle, so they passed while the bug was
  present.

## The recorded connection churn

The recording behind this investigation opened a room session every six
seconds. `zig build rooms-web-trace-lifecycle` holds Rooms to the opposite: it
observes two joined browser members for thirteen idle seconds and refuses any
session opening, closing, or loss of observation, including transient
replacements. That proof does not cover every deployment, so the layout must
handle recordings that contain churn, whatever their producer or cause.
