import Base
import ./LAWS.bend as L

def L.finite_scope_survives_parent_changes(before, after, selected, id):
  {==}

def L.finite_scope_cannot_issue_subtree_authority(ancestry, selected, root):
  {==}

def L.subtree_narrowing_preserves_containment(ancestry, transitive, member, subroot, root, contained, narrowed):
  transitive(member, subroot, root, contained, narrowed)

law and_false:
  for +b: Bool
  {Bool.and(b, False{}) == False{} : Bool}

def and_false(b):
  match b:
    case False{}: {==}
    case True{}: {==}

def L.one_outside_member_blocks_selection(before, after, ancestry, parent, outside, refused):
  match before:
    case Nil{}:
      %refused : {L.selected_fits(outside <> after, ancestry, parent) ==
        Bool.and(_, L.selected_fits(after, ancestry, parent)) : Bool}
      {==}
    case id <> rest:
      +covered = L.contains(ancestry, parent, id)
      remaining = L.selected_fits(List.append(&2, Nat, rest, outside <> after), ancestry, parent)
      Equal.trans(Bool, Bool.and(covered, remaining), Bool.and(covered, False{}), False{},
        Equal.cong(Bool, Bool, accepted => Bool.and(covered, accepted), remaining, False{},
          L.one_outside_member_blocks_selection(rest, after, ancestry, parent, outside, refused)),
        and_false(covered))

def L.empty_selection_fits(ancestry, parent):
  {==}

def L.a_covered_member_keeps_the_tail_decision(id, rest, ancestry, parent, covered):
  %covered : {L.selected_fits(id <> rest, ancestry, parent) ==
    Bool.and(_, L.selected_fits(rest, ancestry, parent)) : Bool}
  {==}
