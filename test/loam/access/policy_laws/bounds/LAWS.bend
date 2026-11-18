import Base
import ./comparisons.bend as Zig

# Nat.cmp models std.math.order on u64. Zig supplies the decisions for each order.

type Limit is Data:
  Open{}
  At{value: Nat}

def relative_to(parent: Limit, child: Limit) -> Zig.Comparison:
  match parent:
    case Open{}: Zig.UnrestrictedParent{}
    case At{limit}:
      match child:
        case Open{}: Zig.UnrestrictedChild{}
        case At{value}: Zig.Ordered{Nat.cmp(value, limit)}

def expected(~ordered: Cmp -> Bool, comparison: Zig.Comparison) -> Bool:
  match comparison:
    case Zig.UnrestrictedParent{}: True{}
    case Zig.UnrestrictedChild{}: False{}
    case Zig.Ordered{order}: ordered(order)

law floor_comparison:
  for c: Zig.Comparison
  {Zig.lower_bound(c) == expected(~Cmp.is_ge, c) : Bool}

law ceiling_comparison:
  for c: Zig.Comparison
  {Zig.upper_bound(c) == expected(~Cmp.is_le, c) : Bool}

# The left limit survives if it fits the right, just as in policy_bounds.zig.
def meet(~rule: Zig.Comparison -> Bool, +a: Limit, +b: Limit) -> Limit:
  Bool.pick(Limit, rule(relative_to(b, a)), a, b)

def floor_fits(child: Limit, parent: Limit) -> Bool:
  Zig.lower_bound(relative_to(parent, child))

def ceiling_fits(child: Limit, parent: Limit) -> Bool:
  Zig.upper_bound(relative_to(parent, child))

law floor_selects_max:
  for +a: Nat
  for +b: Nat
  {meet(~Zig.lower_bound, At{a}, At{b}) == At{Nat.max(a, b)} : Limit}

law ceiling_selects_min:
  for +a: Nat
  for +b: Nat
  {meet(~Zig.upper_bound, At{a}, At{b}) == At{Nat.min(a, b)} : Limit}

law floor_intersection:
  for +child: Limit
  for +a: Limit
  for +b: Limit
  {floor_fits(child, meet(~Zig.lower_bound, a, b)) ==
   Bool.and(floor_fits(child, a), floor_fits(child, b)) : Bool}

law ceiling_intersection:
  for +child: Limit
  for +a: Limit
  for +b: Limit
  {ceiling_fits(child, meet(~Zig.upper_bound, a, b)) ==
   Bool.and(ceiling_fits(child, a), ceiling_fits(child, b)) : Bool}

def chain(~rule: Zig.Comparison -> Bool, grants: List<&2, Limit>, held: Limit) -> Limit:
  match grants:
    case Nil{}: held
    case head <> rest: chain(~rule, rest, meet(~rule, held, head))

def every_parent(~rule: Zig.Comparison -> Bool, parents: List<&2, Limit>, +child: Limit, held: Bool) -> Bool:
  match parents:
    case Nil{}: held
    case head <> rest: every_parent(~rule, rest, child, Bool.and(held, rule(relative_to(head, child))))

law floor_chain:
  for +parents: List<&2, Limit>
  for +child: Limit
  for +held: Limit
  {floor_fits(child, chain(~Zig.lower_bound, parents, held)) ==
   every_parent(~Zig.lower_bound, parents, child, floor_fits(child, held)) : Bool}

law ceiling_chain:
  for +parents: List<&2, Limit>
  for +child: Limit
  for +held: Limit
  {ceiling_fits(child, chain(~Zig.upper_bound, parents, held)) ==
   every_parent(~Zig.upper_bound, parents, child, ceiling_fits(child, held)) : Bool}
