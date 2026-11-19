import Base
import ./LAWS.bend as L
import ../../../foundation/handle_generation_laws/PROOF.bend as Generations

def L.old_sequences_never_become_fresh(sequence, skipped, ceiling):
  %Generations.gap_rejects(sequence, skipped) : {
    L.may_start(sequence, Nat.add(sequence, 1n+skipped), ceiling) ==
    Bool.and(_, Nat.is_lt(Nat.add(sequence, 1n+skipped), ceiling)) : Bool}
  {==}

law later_is_distinct_from_current:
  for +now: Nat
  for +skipped: Nat
  {Nat.is_eq(Nat.add(now, 1n+skipped), now) == False{} : Bool}

def later_is_distinct_from_current(now, skipped):
  match now:
    case 0n: {==}
    case 1n+rest: later_is_distinct_from_current(rest, skipped)

def L.future_sequences_stay_ahead_of_the_frontier(next, skipped, ceiling):
  %later_is_distinct_from_current(next, skipped) : {
    L.may_start(Nat.add(next, 1n+skipped), next, ceiling) ==
    Bool.and(_, Nat.is_lt(next, ceiling)) : Bool}
  {==}

def L.next_sequence_with_headroom_is_fresh(prior, headroom):
  match prior:
    case 0n: {==}
    case 1n+rest: L.next_sequence_with_headroom_is_fresh(rest, headroom)

def L.exhausted_sequence_is_never_fresh(ceiling):
  match ceiling:
    case 0n: {==}
    case 1n+rest: L.exhausted_sequence_is_never_fresh(rest)

def L.appending_with_room_keeps_the_floor(count, floor):
  match count floor:
    case 0n 0n: {==}
    case 0n 1n+rest: {==}
    case 1n+rest f: L.appending_with_room_keeps_the_floor(rest, f)

def L.appending_when_full_advances_the_floor(count, floor):
  match count:
    case 0n: {==}
    case 1n+rest: L.appending_when_full_advances_the_floor(rest, floor)

def L.survivor_moves_left_by_one_slot(floor, index):
  match floor index:
    case 0n 0n: {==}
    case 0n 1n+rest: {==}
    case 1n+rest i: L.survivor_moves_left_by_one_slot(rest, i)
