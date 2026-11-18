import Base
import ./LAWS.bend as Laws
import ./bounds/PROOF.bend as Bounds

def Laws.idempotent(a):
  match a:
    case False{}: {==}
    case True{}: {==}

def Laws.commutative(a, b):
  match a b:
    case False{} False{}: {==}
    case False{} True{}: {==}
    case True{} False{}: {==}
    case True{} True{}: {==}

def Laws.associative(a, b, c):
  match a:
    case False{}: {==}
    case True{}: {==}

def Laws.greatest_lower_bound(right, a, b):
  match right:
    case False{}: {==}
    case True{}: {==}

def Laws.lost_right_stays_lost(grants):
  match grants:
    case Nil{}: {==}
    case grant <> rest: Laws.lost_right_stays_lost(rest)

def Laws.delegation_never_widens(grants, held):
  match held:
    case False{}:
      Equal.sym(Bool, Laws.attenuate(grants, False{}), False{}, Laws.lost_right_stays_lost(grants))
    case True{}: {==}

def Laws.withheld_by_any_ancestor(prefix, suffix, held):
  match prefix:
    case Nil{}:
      match held:
        case False{}: Laws.lost_right_stays_lost(suffix)
        case True{}: Laws.lost_right_stays_lost(suffix)
    case grant <> rest:
      Laws.withheld_by_any_ancestor(rest, suffix, Bool.and(held, grant))

def Laws.intersection_preserves_prerequisite(a, b, required_a, required_b, valid_a, valid_b):
  match a b:
    case False{} False{}: {==}
    case False{} True{}: {==}
    case True{} False{}: {==}
    case True{} True{}:
      %valid_a : {Bool.and(required_a, required_b) == Bool.and(_, True{}) : Bool}
      %valid_b : {Bool.and(required_a, required_b) == Bool.and(required_a, _) : Bool}
      {==}
