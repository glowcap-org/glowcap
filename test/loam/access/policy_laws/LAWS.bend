import Base

# Fix one right in the set represented by a policy. Its membership is one bit.
def fits(child: Bool, parent: Bool) -> Bool:
  Bool.or(Bool.not(child), parent)

# Each entry is the same right's membership in the next grant.
def attenuate(grants: List<Bool>, held: Bool) -> Bool:
  match grants:
    case Nil{}:
      held
    case grant <> rest:
      attenuate(rest, Bool.and(held, grant))

law idempotent:
  for a: Bool
  {Bool.and(a, a) == a : Bool}

law commutative:
  for a: Bool
  for b: Bool
  {Bool.and(a, b) == Bool.and(b, a) : Bool}

law associative:
  for a: Bool
  for b: Bool
  for c: Bool
  {Bool.and(Bool.and(a, b), c) == Bool.and(a, Bool.and(b, c)) : Bool}

# A right fits the intersection exactly when it fits both parents.
law greatest_lower_bound:
  for right: Bool
  for a: Bool
  for b: Bool
  {fits(right, Bool.and(a, b)) == Bool.and(fits(right, a), fits(right, b)) : Bool}

law lost_right_stays_lost:
  for grants: List<Bool>
  {attenuate(grants, False{}) == False{} : Bool}

# Intersecting the result with its starting grant leaves the result unchanged.
law delegation_never_widens:
  for grants: List<Bool>
  for held: Bool
  {Bool.and(held, attenuate(grants, held)) == attenuate(grants, held) : Bool}

law withheld_by_any_ancestor:
  for prefix: List<Bool>
  for suffix: List<Bool>
  for held: Bool
  {attenuate(List.append(&1, Bool, prefix, False{} <> suffix), held) == False{} : Bool}

# Fix any edge in the policy schema. Both parents carry the prerequisite
# whenever they carry the dependent permission.
law intersection_preserves_prerequisite:
  for a: Bool
  for b: Bool
  for required_a: Bool
  for required_b: Bool
  for valid_a: {fits(a, required_a) == True{} : Bool}
  for valid_b: {fits(b, required_b) == True{} : Bool}
  {fits(Bool.and(a, b), Bool.and(required_a, required_b)) == True{} : Bool}
