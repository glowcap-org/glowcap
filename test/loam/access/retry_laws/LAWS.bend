import Base

# Positive sequences use one endpoint's persisted next ordinal. A receipt
# may leave the window without becoming eligible for execution again.
def may_start(+sequence: Nat, +next: Nat, ceiling: Nat) -> Bool:
  Bool.and(Nat.is_eq(sequence, next), Nat.is_lt(next, ceiling))

law old_sequences_never_become_fresh:
  for +sequence: Nat
  for +skipped: Nat
  for +ceiling: Nat
  {may_start(sequence, Nat.add(sequence, 1n+skipped), ceiling) == False{} : Bool}

law future_sequences_stay_ahead_of_the_frontier:
  for +next: Nat
  for +skipped: Nat
  for +ceiling: Nat
  {may_start(Nat.add(next, 1n+skipped), next, ceiling) == False{} : Bool}

law next_sequence_with_headroom_is_fresh:
  for +prior: Nat
  for +headroom: Nat
  {may_start(1n+prior, 1n+prior, Nat.add(1n+prior, 1n+headroom)) == True{} : Bool}

law exhausted_sequence_is_never_fresh:
  for +ceiling: Nat
  {may_start(ceiling, ceiling, ceiling) == False{} : Bool}

def first_retained(next: Nat, count: Nat) -> Nat:
  Nat.sub(next, count)

law appending_with_room_keeps_the_floor:
  for +count: Nat
  for +floor: Nat
  {first_retained(1n+Nat.add(count, floor), 1n+count) == floor : Nat}

law appending_when_full_advances_the_floor:
  for +count: Nat
  for +floor: Nat
  {first_retained(1n+Nat.add(count, floor), count) == 1n+floor : Nat}

def receipt_index(sequence: Nat, floor: Nat) -> Nat:
  Nat.sub(sequence, floor)

law survivor_moves_left_by_one_slot:
  for +floor: Nat
  for +index: Nat
  {receipt_index(1n+Nat.add(floor, index), floor) ==
   1n+receipt_index(1n+Nat.add(floor, index), 1n+floor) : Nat}
