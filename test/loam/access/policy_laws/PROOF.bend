import Base
import ./LAWS.bend as L
import ./bounds/PROOF.bend as Bounds

def L.delegation(grants, held):
  match grants held:
    case Nil{} False{}: {==}
    case Nil{} True{}: {==}
    case False{} <> rest False{}: L.delegation(rest, False{})
    case True{} <> rest False{}: L.delegation(rest, False{})
    case False{} <> rest True{}: L.delegation(rest, False{})
    case True{} <> rest True{}: L.delegation(rest, True{})

def L.intersection(child, a, b):
  match child:
    case False{}: {==}
    case True{}: {==}

def L.intersection_preserves_prerequisite(a, b, required_a, required_b, valid_a, valid_b):
  match a b:
    case False{} False{}: {==}
    case False{} True{}: {==}
    case True{} False{}: {==}
    case True{} True{}:
      %valid_a : {Bool.and(required_a, required_b) == Bool.and(_, True{}) : Bool}
      %valid_b : {Bool.and(required_a, required_b) == Bool.and(required_a, _) : Bool}
      {==}
