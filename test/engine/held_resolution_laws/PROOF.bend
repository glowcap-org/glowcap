import Base
import ./LAWS.bend as L

law add_zero:
  for +n: Nat
  {Nat.add(n, 0n) == n : Nat}

def add_zero(n):
  match n:
    case 0n: {==}
    case 1n+rest:
      %add_zero(rest) : {1n+Nat.add(rest, 0n) == 1n+_ : Nat}
      {==}

def L.drain_releases_parked(other_holds, parked):
  match other_holds:
    case 0n: add_zero(parked)
    case 1n+rest: L.drain_releases_parked(rest, parked)

def L.application_release_order(holds, parked, released):
  match holds:
    case 0n: {==}
    case 1n+rest:
      %Equal.sym(Nat, L.drain(1n+rest, parked), parked, L.drain_releases_parked(rest, parked)) : {
        L.drain(1n+rest, Nat.add(parked, released)) == Nat.add(_, released) : Nat}
      L.drain_releases_parked(rest, Nat.add(parked, released))
