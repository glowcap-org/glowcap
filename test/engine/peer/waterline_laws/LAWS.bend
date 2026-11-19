import Base

# The model assumes representable charges. Peer tests exercise the actual
# staging, queue reservation, and frame drain.
def admits_new(+limit: Nat, held: Nat, charge: Nat) -> Bool:
  Bool.and(Nat.is_lt(held, limit), Nat.is_le(charge, limit))

def admits_staged_replacement(limit: Nat, held: Nat, charge: Nat) -> Bool:
  Nat.is_le(charge, limit)

law new_work_cannot_start_at_or_above_the_waterline:
  for +limit: Nat
  for +excess: Nat
  for +charge: Nat
  {admits_new(limit, Nat.add(limit, excess), charge) == False{} : Bool}

# An item at the single-item ceiling is legal while the queue is still open,
# even when adding that item crosses the waterline.
law new_work_can_use_the_single_item_ceiling:
  for +held: Nat
  {admits_new(1n+held, held, 1n+held) == True{} : Bool}

law any_fitting_replacement_is_allowed_at_any_occupancy:
  for +charge: Nat
  for +headroom: Nat
  for +held: Nat
  {admits_staged_replacement(Nat.add(charge, headroom), held, charge) == True{} : Bool}

law the_item_ceiling_applies_to_new_and_staged_work:
  for +limit: Nat
  for +held: Nat
  for +excess: Nat
  {Bool.or(admits_new(limit, held, Nat.add(limit, 1n+excess)),
           admits_staged_replacement(limit, held, Nat.add(limit, 1n+excess))) == False{} : Bool}

def replace_charge(held: Nat, prior: Nat, replacement: Nat) -> Nat:
  Nat.add(replacement, Nat.sub(held, prior))

law replacement_reprices_only_the_owned_charge:
  for +prior: Nat
  for +unrelated: Nat
  for +replacement: Nat
  {replace_charge(Nat.add(prior, unrelated), prior, replacement) ==
   Nat.add(replacement, unrelated) : Nat}

# A stored resolution moves to a separate Session-retained budget.
law storing_a_resolution_excludes_its_charge_from_the_waterline:
  for +resolution: Nat
  for +unrelated: Nat
  {replace_charge(Nat.add(resolution, unrelated), resolution, 0n) == unrelated : Nat}
