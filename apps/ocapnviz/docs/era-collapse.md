# An era is what is standing at its moment

Status: living record of a decision three committed surfaces cite — `keyframe-layout-system.ts`'s module header,
`layout-eras.ts`, and `era-reuse.test.ts` all point here for why the era count is left unbounded. The work below has
landed except where it says otherwise. Supersede it with an ADR if the bound is ever found, rather than deleting it.

## What the first plan got wrong

It proposed collapsing topology moments that fall within one frame of each other, so a session that opens and closes 2
ms apart would net out before any solve. Two things were wrong, both checked against the code and one against a direct
experiment.

**The collapse would not have netted out.** A batch was stamped with the first change's `t`, and `containsTime` is
half-open. A batch stamped at the open still reports the session on stage, so the merged era keeps the flicker's link
and holds it until the next change six seconds later. It would have appeared to work on the measured feed only because
every flicker links the same pair, and `runForce` never reads a link's id — so two consecutive solves happened to be
identical. A room whose churn touched different pairs would still swing.

**The real cause was not eras at all.** The fold this replaced, `applyChange`, added both endpoint node ids to an
accumulating `peers` set on `session-in` and nothing ever removed them: `peer-out` only reached ids a `peer-joined` or a
declared peer named, and a loose end's stage id is neither. Measured over six churn cycles with a loose far end:

```
before churn:      2 nodes,  3 keyframes
after 6 churns:    8 nodes, 15 keyframes
node ids: alice rooms live-s0::b live-s1::b … live-s5::b
```

Every closed session leaves a permanent invisible body in every later era. In those eras it is not a claim, so
`planClaimPlacements` gives it no segment and it falls through to `nodes` as a free body with `chargeStrength: -3600`
and a default-region seed at the origin. At the observed counter of 258 that is on the order of 258 bodies piled at the
centre of the picture, pushing every real peer outward, with one more every six seconds perturbing the equilibrium of
every era. That is the drift, and it is unbounded in both cost and displacement.

It also explains why warm-starting the solver did not help: warm-starting cannot save a problem that gained a body.

## The fix, in the order the pieces depend on each other

**1. An era's node set is what is standing at its moment.** Derive it from the same effective ranges `sessionsOnStageAt`
in `stage-topology.ts` already reads, which that module's header names as the authority for what is standing there, and
delete the accumulating fold. This changes what an era _is_, so it comes first and everything else is fixed into its
shape. The set is also currently called `peers` while holding peers and endpoint stage ids together, which is the
misnaming that let the leak hide.

**2. Two eras presenting the same problem are one era.** Skip emitting an era whose solver inputs equal the last emitted
era's. The key is everything `runForce` reads for that era: the nodes, each node's pin, claim and footprint, and the
wires as pair-plus-id.

Two things about that key were got wrong first and are worth keeping written down. It began without pins or claims, on
the reasoning that they are constant within one computation — true, but the key is compared _across_ computations by the
reuse in step 3, and a cleared pin then reused a layout that still held it; three existing tests caught that. And it
began without session ids, on the reasoning that the solver reads an id only to count lanes. `bundleIndices` sorts the
ids sharing a pair and indexes by position, so which lane a session rides depends on which ids are on that pair: two
eras with the same pairs under different ids are different problems, and collapsing them left a claim leaning on a lane
its arc was not drawn along.

**3. Re-measure, and correct the header.** The header claimed "N force runs upfront (N ≤ ~10 in practice, ~50 ms
total)", which was already untrue on a live feed. Replace it with the measured cost, stating keyframe count and
convergences per recompute before and after.

**3b. An era reuses the arrangement it already holds** when its problem is unchanged, which is what stops an append
re-annealing a timeline it already solved. Sixty reconnects cost 4.7 s of solving without it and 194 ms with it.

**4. The ease starts from where the picture actually was.** With the accumulated bodies gone, a reconnect still threw
the room and pulled it back: 283.8 world units on the first frame after the flicker, then an ease home over the
transition window. That is the whole of what "it re-animates into place every few seconds" was.

`update` eased from the previous keyframe's arrangement, which is right whenever that era lasted a full window and wrong
when it did not. An era replaced two milliseconds after it arrived was never approached, so starting there put every
node somewhere it had never been, in one frame. Each era now carries the arrangement the picture actually held when it
began, so an era that had two milliseconds contributes two milliseconds' worth. The excursion is under 6 units, a tenth
of a node's own width.

A first attempt rebuilt that chain inside `update`, walking back over eras too short to have finished. It was correct
and too slow: the walk is O(eras) per node per frame, and on a document whose eras sit closer together than the
transition window that is every era, every frame. It measured 4.43 microseconds per update against 1.55 for deriving
each era's start once, so the arrangement is derived per recompute in `sealEras` instead. That function is the only
producer of a keyframe, because what an era eases from is a property of its position in the list rather than of the era
itself: a placement edit that swapped a reused arrangement into an era and set the era's own start alongside it made
that era snap, which `era-reuse.test.ts` now holds at 125 world units.

No threshold decides anything, which matters because two were tried and measured wrong before this:

- **One frame (16 ms).** Not a fixed number of simulated milliseconds: `tick` advances sim time by `wallDt * speed` and
  speed reaches 4×, so the same era is 16 ms at one speed and 67 at another.
- **The transition window (600 ms).** Deletes eras a document legitimately states 100 ms apart; thirteen tests failed on
  the bundled fixtures.

Every era still gets its keyframe, so a `seekTo` landing inside a short one finds the topology the document states
there, and the result stays a pure function of `t`.

## Evidence

`era-reuse.test.ts` holds these, each shown red against an injection of the defect it names.

- The widest era does not grow with the number of reconnects. Not "does not change": while a reconnect's session stands,
  its loose end really is a node and the era covering that moment holds it. What must not grow is the count.
- Every peer sits where it sat once a reconnect has settled.
- A moment presenting the solver a problem it has already been asked is not an era.
- A recompute hands back the _same layout object_ for an era whose problem is unchanged, so no solve ran.
- A second wire on a pair that already has one is its own era, and so is a moment where the same pairs are carried by
  different session ids.

- A placement edit leaves a reused era easing from where the picture was. Dragging a loose end reaches the case: the pin
  names a node the earlier era does not hold, so that era reuses unconditionally while the later one reuses on the pin,
  and the two arrangements differ because one draws a session the other does not.

- A reconnect does not throw the room and pull it back: sampled every frame across the flicker rather than after it
  settles, which is the one place the excursion was ever visible. The six cases above all passed while it was still
  happening, because each of them settles before it looks.

## What this does not fix

The room opening a session every six seconds is upstream, and it will keep accumulating session entities in any
recording of that room whatever the layout does. The leak above is the viewer's own; the churn only exposed it.
