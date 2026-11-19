import Base
import ./LAWS.bend as L

def L.admission_matches_total(limit, held, charge):
  match limit held charge:
    case 0n 0n 0n: {==}
    case 0n 0n 1n+c: {==}
    case 0n 1n+h _: {==}
    case 1n+l 0n c: {==}
    case 1n+l 1n+h c: L.admission_matches_total(l, h, c)

law subtract_two:
  for +held: Nat
  for +first: Nat
  for +second: Nat
  {Nat.sub(Nat.sub(held, first), second) == Nat.sub(held, Nat.add(first, second)) : Nat}

def subtract_two(held, first, second):
  match held first second:
    case 0n _ _: {==}
    case 1n+h 0n _: {==}
    case 1n+h 1n+f s: subtract_two(h, f, s)

def L.preflight_allows_every_step(deltas, held):
  match deltas held:
    case Nil{} 0n: {==}
    case Nil{} 1n+h: {==}
    case delta <> rest h:
      %L.admission_matches_total(h, delta, L.total(rest)) : {
        Bool.and(Nat.is_le(delta, h), L.can_replay(rest, Nat.sub(h, delta))) == _ : Bool}
      %L.preflight_allows_every_step(rest, Nat.sub(h, delta)) : {
        Bool.and(Nat.is_le(delta, h), L.can_replay(rest, Nat.sub(h, delta))) ==
        Bool.and(Nat.is_le(delta, h), _) : Bool}
      {==}

def L.remainder_matches_total(deltas, held):
  match deltas held:
    case Nil{} 0n: {==}
    case Nil{} 1n+h: {==}
    case delta <> rest h:
      %subtract_two(h, delta, L.total(rest)) : {L.remainder(rest, Nat.sub(h, delta)) == _ : Nat}
      L.remainder_matches_total(rest, Nat.sub(h, delta))

law suffix_length:
  for +head: Nat
  for +live: Nat
  {Nat.sub(Nat.add(head, live), head) == live : Nat}

def suffix_length(head, live):
  match head live:
    case 0n 0n: {==}
    case 0n 1n+l: {==}
    case 1n+h l: suffix_length(h, l)

law positive_charge_uses_admission:
  for +limit: Nat
  for +kept: Nat
  for +charge: Nat
  {Nat.is_le(1n+charge, Nat.sub(limit, kept)) ==
    L.admits(limit, kept, 1n+charge) : Bool}

def positive_charge_uses_admission(limit, kept, charge):
  match limit kept:
    case 0n 0n: {==}
    case 0n 1n+l: {==}
    case 1n+b 0n: {==}
    case 1n+b 1n+l: positive_charge_uses_admission(b, l, charge)

def L.positive_charge_after_removal(limit, removed, kept, charge):
  %Equal.sym(Nat, Nat.sub(Nat.add(removed, kept), removed), kept, suffix_length(removed, kept)) : {
    Nat.is_le(1n+charge, Nat.sub(limit, _)) == Nat.is_le(Nat.add(kept, 1n+charge), limit) : Bool}
  %L.admission_matches_total(limit, kept, 1n+charge) : {
    Nat.is_le(1n+charge, Nat.sub(limit, kept)) == _ : Bool}
  positive_charge_uses_admission(limit, kept, charge)
