import Base

# The ingress checks space before counting one more charge.
def admits(+limit: Nat, +held: Nat, charge: Nat) -> Bool:
  Bool.and(Nat.is_le(held, limit), Nat.is_le(charge, Nat.sub(limit, held)))

law admission_matches_total:
  for +limit: Nat
  for +held: Nat
  for +charge: Nat
  {admits(limit, held, charge) == Nat.is_le(Nat.add(held, charge), limit) : Bool}

def total(deltas: List<&2, Nat>) -> Nat:
  match deltas:
    case Nil{}: 0n
    case +delta <> rest: Nat.add(delta, total(rest))

def can_replay(deltas: List<&2, Nat>, +held: Nat) -> Bool:
  match deltas:
    case Nil{}: True{}
    case +delta <> rest:
      Bool.and(Nat.is_le(delta, held), can_replay(rest, Nat.sub(held, delta)))

law preflight_allows_every_step:
  for +deltas: List<&2, Nat>
  for +held: Nat
  {can_replay(deltas, held) == Nat.is_le(total(deltas), held) : Bool}

def remainder(deltas: List<&2, Nat>, held: Nat) -> Nat:
  match deltas:
    case Nil{}: held
    case delta <> rest: remainder(rest, Nat.sub(held, delta))

law remainder_matches_total:
  for +deltas: List<&2, Nat>
  for +held: Nat
  {remainder(deltas, held) == Nat.sub(held, total(deltas)) : Nat}
