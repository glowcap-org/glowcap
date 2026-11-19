import Base
import ./LAWS.bend as L

def L.residual_is_exact(queued, budget):
  match queued budget:
    case 0n 0n: {==}
    case 0n 1n+room: {==}
    case 1n+rest 0n: {==}
    case 1n+rest 1n+room: L.residual_is_exact(rest, room)

def L.split_budget_keeps_the_same_residual(first, second, queued):
  match first queued:
    case 0n 0n: {==}
    case 0n 1n+rest: {==}
    case 1n+room 0n: {==}
    case 1n+room 1n+rest: L.split_budget_keeps_the_same_residual(room, second, rest)

def L.exhausted_retry_leaves_queue_untouched(limit, queued):
  match limit:
    case 0n:
      match queued:
        case 0n: {==}
        case 1n+rest: {==}
    case 1n+rest: L.exhausted_retry_leaves_queue_untouched(rest, queued)
