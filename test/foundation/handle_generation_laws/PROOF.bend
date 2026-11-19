import Base
import ./LAWS.bend as L

law add_shift:
  for +old: Nat
  for +gap: Nat
  {Nat.add(old, 1n+gap) == 1n+Nat.add(old, gap) : Nat}

def add_shift(old, gap):
  match old:
    case 0n: {==}
    case 1n+rest:
      %add_shift(rest, gap) : {1n+Nat.add(rest, 1n+gap) == 1n+_ : Nat}
      {==}

law add_zero:
  for +old: Nat
  {Nat.add(old, 0n) == old : Nat}

def add_zero(old):
  match old:
    case 0n: {==}
    case 1n+rest:
      %add_zero(rest) : {1n+Nat.add(rest, 0n) == 1n+_ : Nat}
      {==}

law gap_rejects:
  for +old: Nat
  for +gap: Nat
  {Nat.is_eq(old, Nat.add(old, 1n+gap)) == False{} : Bool}

def gap_rejects(old, gap):
  match old:
    case 0n: {==}
    case 1n+rest: gap_rejects(rest, gap)

law later_reuses_stay_stale:
  for +steps: Nat
  for +remaining: Nat
  for +old: Nat
  for +gap: Nat
  {L.recognizes(old, L.advances(steps, L.Live{Nat.add(old, 1n+gap), remaining})) == False{} : Bool}

def later_reuses_stay_stale(steps, remaining, old, gap):
  match steps remaining:
    case 0n _: gap_rejects(old, gap)
    case 1n+_ 0n: {==}
    case 1n+s 1n+r:
      %add_shift(old, 1n+gap) : {
        L.recognizes(old, L.advances(s, L.Live{_, r})) == False{} : Bool}
      later_reuses_stay_stale(s, r, old, 1n+gap)

def L.a_freed_generation_never_matches(old, remaining, steps):
  match remaining:
    case 0n: {==}
    case 1n+r:
      %add_zero(old) : {
        L.recognizes(old, L.advances(steps, L.Live{1n+_, r})) == False{} : Bool}
      %add_shift(old, 0n) : {
        L.recognizes(old, L.advances(steps, L.Live{_, r})) == False{} : Bool}
      later_reuses_stay_stale(steps, r, old, 0n)
