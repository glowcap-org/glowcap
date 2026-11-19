import Base

# One turn spends one unit of a budget. This measures a fixed queue,
# so the turns in this model add no work.
def drain(+queued: Nat, +budget: Nat) -> Nat:
  match queued budget:
    case 0n b: 0n
    case 1n+rest 0n: 1n+rest
    case 1n+rest 1n+room: drain(rest, room)

law residual_is_exact:
  for +queued: Nat
  for +budget: Nat
  {drain(queued, budget) == Nat.sub(queued, budget) : Nat}

law split_budget_keeps_the_same_residual:
  for +first: Nat
  for +second: Nat
  for +queued: Nat
  {drain(queued, Nat.add(first, second)) == drain(drain(queued, first), second) : Nat}

# A retry of the same epoch inherits the turns it already spent.
def resume(queued: Nat, limit: Nat, used: Nat) -> Nat:
  drain(queued, Nat.sub(limit, used))

law exhausted_retry_leaves_queue_untouched:
  for +limit: Nat
  for +queued: Nat
  {resume(queued, limit, limit) == queued : Nat}
