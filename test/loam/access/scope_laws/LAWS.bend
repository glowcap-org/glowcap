import Base

# At one validated resource revision, ancestry includes each resource itself.
# Numbers identify complete resource names, with owner and generation. A
# finite scope represents either a single object or an explicit selection.
type Scope is Data:
  Finite{selected: List<&2, Nat>}
  Subtree{root: Nat}

type AncestryPair is Data:
  AncestryPair{member: Nat, root: Nat}

def beneath(+ancestry: List<&2, AncestryPair>, +id: Nat, +root: Nat) -> Bool:
  match ancestry:
    case Nil{}: False{}
    case AncestryPair{member, ancestor} <> rest:
      Bool.or(Bool.and(Nat.is_eq(id, member), Nat.is_eq(root, ancestor)), beneath(rest, id, root))

def contains(ancestry: List<&2, AncestryPair>, scope: Scope, id: Nat) -> Bool:
  match scope:
    case Finite{selected}: List.contains(~Nat, ~Nat.is_eq, selected, id)
    case Subtree{root}: beneath(ancestry, id, root)

def root_fits(ancestry: List<&2, AncestryPair>, parent: Scope, root: Nat) -> Bool:
  match parent:
    case Finite{selected}: False{}
    case Subtree{ancestor}: beneath(ancestry, root, ancestor)

def selected_fits(+selected: List<&2, Nat>, +ancestry: List<&2, AncestryPair>, +parent: Scope) -> Bool:
  match selected:
    case Nil{}: True{}
    case id <> rest: Bool.and(contains(ancestry, parent, id), selected_fits(rest, ancestry, parent))

def narrows(ancestry: List<&2, AncestryPair>, child: Scope, parent: Scope) -> Bool:
  match child:
    case Finite{selected}: selected_fits(selected, ancestry, parent)
    case Subtree{root}: root_fits(ancestry, parent, root)

law finite_scope_survives_parent_changes:
  for +before: List<&2, AncestryPair>
  for +after: List<&2, AncestryPair>
  for +selected: List<&2, Nat>
  for +id: Nat
  {contains(before, Finite{selected}, id) == contains(after, Finite{selected}, id) : Bool}

law finite_scope_cannot_issue_subtree_authority:
  for +ancestry: List<&2, AncestryPair>
  for +selected: List<&2, Nat>
  for +root: Nat
  {narrows(ancestry, Subtree{root}, Finite{selected}) == False{} : Bool}

# A validated parent walk supplies transitivity at this revision. The same
# rule applies to two narrowing steps, or to a member of the narrower scope.
law subtree_narrowing_preserves_containment:
  for +ancestry: List<&2, AncestryPair>
  for transitive: @member: Nat -> @subroot: Nat -> @root: Nat ->
    {beneath(ancestry, member, subroot) == True{} : Bool} -> {beneath(ancestry, subroot, root) == True{} : Bool} ->
    {beneath(ancestry, member, root) == True{} : Bool}
  for +member: Nat
  for +subroot: Nat
  for +root: Nat
  for contained: {contains(ancestry, Subtree{subroot}, member) == True{} : Bool}
  for narrowed: {narrows(ancestry, Subtree{subroot}, Subtree{root}) == True{} : Bool}
  {contains(ancestry, Subtree{root}, member) == True{} : Bool}

law one_outside_member_blocks_selection:
  for +before: List<&2, Nat>
  for +after: List<&2, Nat>
  for +ancestry: List<&2, AncestryPair>
  for +parent: Scope
  for +outside: Nat
  for refused: {contains(ancestry, parent, outside) == False{} : Bool}
  {narrows(ancestry, Finite{List.append(&2, Nat, before, outside <> after)}, parent) == False{} : Bool}

law empty_selection_fits:
  for +ancestry: List<&2, AncestryPair>
  for +parent: Scope
  {narrows(ancestry, Finite{Nil{}}, parent) == True{} : Bool}

law a_covered_member_keeps_the_tail_decision:
  for +id: Nat
  for +rest: List<&2, Nat>
  for +ancestry: List<&2, AncestryPair>
  for +parent: Scope
  for covered: {contains(ancestry, parent, id) == True{} : Bool}
  {narrows(ancestry, Finite{id <> rest}, parent) == narrows(ancestry, Finite{rest}, parent) : Bool}
