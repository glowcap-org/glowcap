import Base

# A drop emits parked releases only when it removes the last stored mention’s hold.
def dropped(holds: Nat, parked: Nat) -> Nat:
  match holds:
    case 1n: parked
    case _: 0n

def drain(+holds: Nat, +parked: Nat) -> Nat:
  match holds:
    case 0n: 0n
    case 1n+rest: Nat.add(dropped(holds, parked), drain(rest, parked))

def before_drain(holds: Nat, parked: Nat, released: Nat) -> Nat:
  match holds:
    case 0n: released
    case 1n+rest: drain(1n+rest, Nat.add(parked, released))

law drain_releases_parked:
  for +other_holds: Nat
  for +parked: Nat
  {drain(1n+other_holds, parked) == parked : Nat}

law application_release_order:
  for +holds: Nat
  for +parked: Nat
  for +released: Nat
  {before_drain(holds, parked, released) == Nat.add(drain(holds, parked), released) : Nat}
