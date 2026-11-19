import Base
import ./LAWS.bend as L

law and_false:
  for +value: Bool
  {Bool.and(value, False{}) == False{} : Bool}

def and_false(value):
  match value:
    case True{}: {==}
    case False{}: {==}

law and_assoc:
  for +a: Bool
  for +b: Bool
  for +c: Bool
  {Bool.and(a, Bool.and(b, c)) == Bool.and(Bool.and(a, b), c) : Bool}

def and_assoc(a, b, c):
  match a:
    case True{}: {==}
    case False{}: {==}

def L.composed_authority(outside, inside, invocation):
  match outside:
    case Nil{}: {==}
    case layer <> rest:
      Equal.trans(Bool,
        L.reaches(List.append(&2, L.Proxy, layer <> rest, inside), invocation),
        Bool.and(L.passes(layer, invocation), Bool.and(L.reaches(rest, invocation), L.reaches(inside, invocation))),
        Bool.and(L.reaches(layer <> rest, invocation), L.reaches(inside, invocation)),
        Equal.cong(Bool, Bool, reached => Bool.and(L.passes(layer, invocation), reached),
          L.reaches(List.append(&2, L.Proxy, rest, inside), invocation),
          Bool.and(L.reaches(rest, invocation), L.reaches(inside, invocation)),
          L.composed_authority(rest, inside, invocation)),
        and_assoc(L.passes(layer, invocation), L.reaches(rest, invocation), L.reaches(inside, invocation)))

def L.revocation_blocks_every_path(outside, inside, invocation):
  Equal.trans(Bool, L.reaches(List.append(&2, L.Proxy, outside, L.Caretaker{False{}} <> inside), invocation),
    Bool.and(L.reaches(outside, invocation), False{}), False{},
    L.composed_authority(outside, L.Caretaker{False{}} <> inside, invocation),
    and_false(L.reaches(outside, invocation)))

def L.verb_grants_do_not_authorize_direct_calls(outside, inside, allowed):
  Equal.trans(Bool, L.reaches(List.append(&2, L.Proxy, outside, L.Attenuator{allowed} <> inside), L.Direct{}),
    Bool.and(L.reaches(outside, L.Direct{}), False{}), False{},
    L.composed_authority(outside, L.Attenuator{allowed} <> inside, L.Direct{}),
    and_false(L.reaches(outside, L.Direct{})))

law same_selector:
  for +selector: Nat
  {Nat.is_eq(selector, selector) == True{} : Bool}

def same_selector(selector):
  match selector:
    case 0n: {==}
    case 1n+rest: same_selector(rest)

law or_true:
  for +value: Bool
  {Bool.or(value, True{}) == True{} : Bool}

def or_true(value):
  match value:
    case True{}: {==}
    case False{}: {==}

def L.any_listed_verb_passes(before, selector, after):
  match before:
    case Nil{}:
      %same_selector(selector) : {L.contains(selector <> after, selector) ==
        Bool.or(_, L.contains(after, selector)) : Bool}
      {==}
    case verb <> rest:
      Equal.trans(Bool,
        L.contains(List.append(&2, Nat, verb <> rest, selector <> after), selector),
        Bool.or(Nat.is_eq(verb, selector), True{}), True{},
        Equal.cong(Bool, Bool, found => Bool.or(Nat.is_eq(verb, selector), found),
          L.contains(List.append(&2, Nat, rest, selector <> after), selector), True{},
          L.any_listed_verb_passes(rest, selector, after)),
        or_true(Nat.is_eq(verb, selector)))

law or_complement:
  for +head: Bool
  for +tail: Bool
  {Bool.or(head, Bool.not(tail)) == Bool.not(Bool.and(Bool.not(head), tail)) : Bool}

def or_complement(head, tail):
  match head:
    case True{}: {==}
    case False{}: {==}

def L.only_listed_verbs_pass(allowed, selector):
  match allowed:
    case Nil{}: {==}
    case verb <> rest:
      Equal.trans(Bool,
        L.contains(verb <> rest, selector),
        Bool.or(Nat.is_eq(verb, selector), Bool.not(L.excludes(rest, selector))),
        Bool.not(L.excludes(verb <> rest, selector)),
        Equal.cong(Bool, Bool, found => Bool.or(Nat.is_eq(verb, selector), found),
          L.contains(rest, selector), Bool.not(L.excludes(rest, selector)),
          L.only_listed_verbs_pass(rest, selector)),
        or_complement(Nat.is_eq(verb, selector), L.excludes(rest, selector)))
