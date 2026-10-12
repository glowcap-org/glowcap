# Recovery cases

| Symptom | Check and response |
| --- | --- |
| Peer is available but member is silent | Check the model's active wait. A completed turn leaves no consumer; resume that model on the same workspace. |
| DMs work but room questions go unanswered | Read every batch across both channels. The lead must handle its own copy of human room questions. |
| Member waits for the lead to acknowledge its event | IDs belong to each peer's inbox. Read and dismiss that member's copy if it needs no response. |
| Send times out | Inspect status and the reported operation ID. Do not blindly resend an uncertain effect. |
| Reply completed but acknowledgment failed | Dismiss the source event after inspection; do not send the reply again. |
| Inbox reports a gap | Correct the cause and preserve pending events; explicitly resume after accepting the missing interval. |
| Team start partly fails | Inspect team-status. Already-started peers remain available; team-stop attempts every roster entry. |
| Nickname or workspace is already in use | Resolve the conflict; do not silently change a name or erase state. |
| Browser DM cannot be reached | Check the route described in rooms-peer; a WebRTC-only browser needs a compatible reachable route. |
| Member restarts after a stop order | Stop it and restate presence ownership. Recovery does not override the human or lead. |
| Debate or handoff loops | Use the strategy's round or handoff limit, then let the lead summarize and decide or ask the human. |
| Harness reports progress but the room sees nothing | Post a concise update for room-scoped work; keep private tool output out of chat. |

[Rooms peer](../rooms-peer/SKILL.md) owns command use and listening.
[Team operations](ops.md) owns health, handoffs, and teardown.
