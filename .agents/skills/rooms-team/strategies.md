# rooms-team — orchestration strategy catalog

The lead chooses the simplest pattern that fits the assignment's dependencies
and acceptance criteria, announces the chosen id (or hybrid) in the room, and
re-chooses when the mission shape changes.

Aliases in parentheses are the same pattern under another common name.

## Catalog

| id | Pattern | Shape | Prefer when | Avoid when |
| -- | ------- | ----- | ----------- | ---------- |
| `supervisor` | Supervisor / orchestrator-worker | Lead decomposes, assigns, synthesizes | Clear subtasks; one plan owner | Strong sequential coupling; workers need peer mesh |
| `hierarchical` | Hierarchical | Tree of lead → sub-leads → workers | Large scope; multiple abstraction levels | One level of decomposition is enough |
| `pipeline` | Sequential / pipeline / staged | Fixed stage order; each feeds next | Linear refinement; known stages | Embarrassingly parallel; needs backtracking |
| `concurrent` | Concurrent / parallel | Same input → many agents at once | Diverse independent views; latency | Order matters; shared mutable state |
| `fan_out_fan_in` | Fan-out / fan-in | Broadcast → collect → aggregate | Many independent inputs; mergeable results | Aggregation too hard; sequential deps |
| `map_reduce` | Map-reduce | Split homogeneous work → reduce | Large similar chunks | Items interdependent |
| `dag` | DAG execution | Dependency graph; max safe parallelism | Mixed serial/parallel known upfront | Deps discovered only at runtime |
| `dispatcher_moe` | Dispatcher / mixture-of-experts | Router picks best specialist per item | Heterogeneous tasks | Every item needs every expert |
| `specialist_decomp` | Specialist decomposition | Split by domain; narrow deep context | Clear domain boundaries | Domains deeply intertwined |
| `handoff` | Handoff / routing / triage | One active agent; explicit transfer | Right specialist emerges mid-task | Routing is static; handoff ping-pong risk |
| `dynamic_handoff` | Dynamic handoff | Same as handoff with runtime affinity | Unknown specialist until signals appear | Deterministic rules already suffice |
| `plan_then_execute` | Plan-then-execute | Plan fully, then execute (optional human gate) | Risky/irreversible actions | Plan goes stale immediately |
| `adaptive` | Magentic / adaptive planning / task ledger | Lead builds & revises a live plan/ledger | Open-ended; path unknown | Need speed or a fixed path |
| `react` | ReAct (reason+act) | Thought → tool → observe loop | Next step depends on tool results | Fully plannable; no tools |
| `reflection` | Reflection / retry-with-reflection | Critique own output or failure, then revise | Diagnosable failures; quality gains | Blind spots; external constraint failures |
| `iterative_refinement` | Iterative refinement | Revision cycles per quality dimension | Complex artifact; multi-pass needed | First draft already good enough |
| `critic` | Critic-validator / maker-checker | Maker produces; critic gates; loop | Clear acceptance criteria | No criteria; latency-critical |
| `constitutional` | Constitutional / guided generation | Generate → rule critique → revise | Formal rules must hold | Rules not checkable automatically |
| `debate` | Debate | Opposing sides + judge | Real tradeoffs; stress-test a choice | One objective answer; shared bias |
| `council` | Council / ensemble committee | Roles deliberate; chair synthesizes | High-stakes multi-expert decisions | Speed-critical; members always agree |
| `ensemble` | Ensemble / self-consistency / vote | Independent answers → vote or merge | Ambiguity; high single-agent variance | Agents would clone the same answer |
| `group_chat` | Group chat / roundtable | Shared thread; lead gates turns | Brainstorm; consensus; HITL visibility | Need pure parallelism; chat loops |
| `round_robin` | Round-robin | Lead rotates who speaks | Fair airtime; structured council | Urgent single-owner work |
| `collaborative` | Collaborative sequential improve | Each agent improves one shared artifact | Quality rises from successive lenses | Agents overwrite each other |
| `blackboard` | Blackboard | Shared store; agents advance entries | Emergent fill-in; order unknown | Strict order; write conflicts |
| `swarm` | Swarm | Local rules; light central control | Exploration; no single point of failure | Need auditability / strict order |
| `mesh` | Mesh | Peer-to-peer on one artifact | Small team iterating one design | Large team; no merge owner |
| `magnetic` | Magnetic / affinity self-assign | Agents claim tasks by fit | Dynamic task types; variable availability | Need deterministic routing |
| `speculative` | Speculative execution | Race paths; first success wins | Unknown best path; latency > cost | Side effects that cannot cancel |
| `tree_of_thought` | Tree-of-thought | Branch, score, prune, expand | Early choices dominate; searchable space | Expensive; greedy path enough |
| `storm` | STORM / outline-then-write | Research → outline → parallel sections → compile | Long docs past one context | Short interdependent prose |
| `subgoal` | Subgoal decomposition | Recursive goals with pre/postconditions | Natural hierarchy of goals | Shallow task; tangled subgoals |
| `supervisor_health` | Supervisor (health) | Monitor workers; restart/reassign/escalate | Long-running workers; recovery needed | Short tasks; human already watching |
| `hitl` | Human-in-the-loop | Pause for human approve/edit | Irreversible, compliance, low confidence | Always-on rubber stamps |
| `harness` | Harness / durable loop | Wake → work → improve across missions | Always-on team presence | One-shot tasks |
| `event_driven` | Event-driven | External events trigger agents | Reactive systems | Faster events than capacity |
| `actor` | Actor model | Private state + messages only | Isolation; high concurrency | Need shared mutable state |
| `memory` | Memory-augmented | Persist/retrieve across sessions | Cross-session continuity | One-shot; stale memory risk |
| `persona_roles` | Role-playing / persona | Constrain priorities & tone per role | Stakeholder diversity | Neutral assessment required |
| `swarm_then_merge` | Swarm-then-merge | Solo drafts → lead merge | Parallel drafts without early coupling | Need tight early alignment |

## Hybrids

Compose freely when the mission has phases. Name both parts, e.g.:

- `plan_then_execute` + `critic` — plan gate, then maker-checker on the patch
- `hierarchical` + `debate` — managers debate approach, then workers execute
- `supervisor` + `pipeline` — lead assigns; each assignment is a mini-pipeline
- `adaptive` + `hitl` — ledger evolves with human checkpoints
- `concurrent` + `ensemble` — parallel specialists, then vote/synthesize

## Choice checklist

Use a pipeline for dependent stages, independent assignments for separable
work, and a bounded maker-checker loop when the acceptance criteria need a
second reader. Add coordination only when the assignment requires it.
[SKILL.md](SKILL.md) owns presence, roster authority, and the member brief.
