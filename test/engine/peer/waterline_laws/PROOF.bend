import Base
import ./LAWS.bend as L

law at_or_above:
  for +limit: Nat
  for +extra: Nat
  {Nat.is_lt(Nat.add(limit, extra), limit) == False{} : Bool}

def at_or_above(limit, extra):
  match limit extra:
    case 0n 0n: {==}
    case 0n 1n+more: {==}
    case 1n+rest n: at_or_above(rest, n)

def L.new_work_cannot_start_at_or_above_the_waterline(limit, excess, charge):
  %at_or_above(limit, excess) : {L.admits_new(limit, Nat.add(limit, excess), charge) ==
    Bool.and(_, Nat.is_le(charge, limit)) : Bool}
  {==}

def L.new_work_can_use_the_single_item_ceiling(held):
  match held:
    case 0n: {==}
    case 1n+rest: L.new_work_can_use_the_single_item_ceiling(rest)

def L.any_fitting_replacement_is_allowed_at_any_occupancy(charge, headroom, held):
  match charge headroom:
    case 0n 0n: {==}
    case 0n 1n+room: {==}
    case 1n+rest room: L.any_fitting_replacement_is_allowed_at_any_occupancy(rest, room, held)

law excess_over_limit:
  for +limit: Nat
  for +excess: Nat
  {Nat.is_le(Nat.add(limit, 1n+excess), limit) == False{} : Bool}

def excess_over_limit(limit, excess):
  match limit:
    case 0n: {==}
    case 1n+rest: excess_over_limit(rest, excess)

law refuse_both:
  for +open: Bool
  {Bool.or(Bool.and(open, False{}), False{}) == False{} : Bool}

def refuse_both(open):
  match open:
    case True{}: {==}
    case False{}: {==}

def L.the_item_ceiling_applies_to_new_and_staged_work(limit, held, excess):
  Equal.trans(Bool,
    Bool.or(L.admits_new(limit, held, Nat.add(limit, 1n+excess)),
      L.admits_staged_replacement(limit, held, Nat.add(limit, 1n+excess))),
    Bool.or(Bool.and(Nat.is_lt(held, limit), False{}), False{}), False{},
    Equal.cong(Bool, Bool, within => Bool.or(Bool.and(Nat.is_lt(held, limit), within), within),
      Nat.is_le(Nat.add(limit, 1n+excess), limit), False{}, excess_over_limit(limit, excess)),
    refuse_both(Nat.is_lt(held, limit)))

def L.replacement_reprices_only_the_owned_charge(prior, unrelated, replacement):
  match prior unrelated:
    case 0n 0n: {==}
    case 0n 1n+rest: {==}
    case 1n+rest other: L.replacement_reprices_only_the_owned_charge(rest, other, replacement)

def L.storing_a_resolution_excludes_its_charge_from_the_waterline(resolution, unrelated):
  L.replacement_reprices_only_the_owned_charge(resolution, unrelated, 0n)
