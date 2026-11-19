import Base

# Follow one permission through a sequence of grants.
def attenuate(grants: List<&2, Bool>, held: Bool) -> Bool:
  List.foldl(~&2, ~Bool, ~Bool, ~Bool.and, grants, held)

def granted(permission: Bool) -> Bool:
  permission

law delegation:
  for +grants: List<&2, Bool>
  for +held: Bool
  {attenuate(grants, held) == Bool.and(held, List.all(~&2, ~Bool, ~granted, grants)) : Bool}

def fits(child: Bool, parent: Bool) -> Bool:
  Bool.or(Bool.not(child), parent)

law intersection:
  for +child: Bool
  for +a: Bool
  for +b: Bool
  {fits(child, Bool.and(a, b)) == Bool.and(fits(child, a), fits(child, b)) : Bool}

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

# The scalar laws give one pair of parental decisions per permission or fact.
type Admission is Data:
  Admission{left: Bool, right: Bool}

def left(check: Admission) -> Bool:
  match check:
    case Admission{allowed, other}: allowed

def right(check: Admission) -> Bool:
  match check:
    case Admission{other, allowed}: allowed

def through_intersection(check: Admission) -> Bool:
  match check:
    case Admission{a, b}: Bool.and(a, b)

law effect_intersection:
  for +checks: List<&2, Admission>
  {List.all(~&2, ~Admission, ~through_intersection, checks) ==
   Bool.and(List.all(~&2, ~Admission, ~left, checks),
            List.all(~&2, ~Admission, ~right, checks)) : Bool}
