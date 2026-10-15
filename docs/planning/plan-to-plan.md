# Plan to plan

This page is permanent. It says how work goes from an idea to a plan to done.

## How work moves

1. **Idea.** Someone wants something. It becomes an item on the
   [roadmap](../roadmap.md) that says what is missing and links here.
2. **Plan to plan.** The item waits here until it is ready to plan. This page
   says when that is and how to write the plan.
3. **Plan.** The item gets its own plan in `docs/planning/`, and its roadmap
   link moves from here to that plan. The maintainer reviews the plan before
   work starts.
4. **Execute.** Agents work the plan's steps, up to three at once. Each step
   lands in `dev` and deletes itself from the plan.
5. **Done.** The last step deletes the plan and removes the roadmap item. What
   shipped is described where it lives, not here.

So every roadmap item links either its own plan or this page, and
`source-check` fails if one links neither. The roadmap is the only list of
work. Nothing else lists plans or their status.

## When an item is ready to plan

An item is ready once nothing outside this repository decides its shape. Its
roadmap text says what it waits on, which is usually one of these:

- a decision only the maintainer can make
- an upstream change in OCapN or Goblins
- hardware or accounts this repository doesn't have

Until then, the item keeps linking here. Don't write a plan that guesses the
answer.

Some items are a single maintainer action, like an account setting.
They never need a plan. They keep linking here, and their roadmap text says who
acts.

## Writing the plan

1. Read the item, the docs it links, and the ADRs it names.
2. Find out where the code stands: what exists, what's missing, and where it
   lives.
3. Find the one decision that shapes the work, and the other ways it could
   go. If the work needs a new contract, the first step is an ADR.
4. Write `docs/planning/<name>.md` with these sections, in this order:
   - A status line: `Status: active plan, waiting for maintainer review
     before work starts.`, and when to delete the plan.
   - **What this is for**, in a few plain sentences.
   - **Where things stand.**
   - **The decision**, when there is one.
   - **Steps**, where each step is one commit with its own test.
   - **Parallel work**, as described [below](#working-a-plan-in-parallel).
   - **Questions for you**, the ones only the maintainer can answer.
   - **Where the code is**, the file paths and names, last.
5. Write it so the maintainer can read it once and understand it. Explain a
   term the first time it's used, and keep code names in the last section.
6. In the same commit, point the roadmap item at the new plan instead of here.
7. The maintainer reviews the plan before any step starts. After that review,
   the status line drops "waiting for maintainer review".

## Adding an idea

Add the item to the roadmap section it belongs to. Say what is missing and
what it waits on, if anything, and link this page. Don't write a plan in the
same change unless the maintainer asked for one.

Planning one item doesn't depend on planning another, so up to three agents
can each plan a different item at once. Each owns its new plan file and its
roadmap item.

## Working a plan in parallel

Up to three agents can work at once, one per worktree (`tree1`, `tree2`,
`tree3`). Each active plan ends with a **Parallel work** section that lets
them split it without stepping on each other. That section:

- splits the steps into at most three lanes, and says which lanes start now
  and which wait for a step in another lane to land in `dev`
- names what each lane owns, the directories and files it edits, so two lanes
  never edit the same file at once
- names the shared files (the roadmap, the shipped inventory, generated files,
  the plan itself) and who edits each one
- says so when a plan can't be split, and why

Every step lands in `dev` on its own through the
[integration procedure](../../.agents/rules/cli.md#git-posture). A waiting lane
runs `glowcap-integrate --sync` once the step it waits for is in `dev`, then
starts. A generated file is regenerated after a sync, never merged by hand.
A lane deletes its finished steps from the plan in the same commit.

## When a step is done

A step is done when all of these are true:

1. It meets the plan's test for that step, including how it fails and what it
   costs.
2. The checks for what changed pass, and the evidence is recorded in a test or
   report next to the code.
3. Contracts, examples and the docs that describe the present match the
   result. The step is deleted from the plan.
4. The commit is in `dev`, and the worktree has nothing left uncommitted from
   the step.

A commit only on a worktree branch isn't done. A partial step says what it
covers and leaves the rest in the plan. Writing down a missing requirement
doesn't complete it.
