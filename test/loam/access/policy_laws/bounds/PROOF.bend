import Base
import ./LAWS.bend as Laws
import ./comparisons.bend as Zig

def and_true(b: Bool) -> {b == Bool.and(b, True{}) : Bool}:
  match b:
    case False{}: {==}
    case True{}: {==}

def and_false(b: Bool) -> {False{} == Bool.and(b, False{}) : Bool}:
  match b:
    case False{}: {==}
    case True{}: {==}

# Successor preserves both the comparison and the operand it selects.
def next(limit: Laws.Limit) -> Laws.Limit:
  match limit:
    case Laws.Open{}: Laws.Open{}
    case Laws.At{x}: Laws.At{1n+x}

def choose_successor(keep: Bool, a: Nat, b: Nat) -> {
  Bool.pick(Laws.Limit, keep, Laws.At{1n+a}, Laws.At{1n+b}) ==
  next(Bool.pick(Laws.Limit, keep, Laws.At{a}, Laws.At{b})) : Laws.Limit}:
  match keep:
    case False{}: {==}
    case True{}: {==}

def Laws.floor_comparison(c):
  match c:
    case Zig.UnrestrictedParent{}: {==}
    case Zig.UnrestrictedChild{}: {==}
    case Zig.Ordered{order}:
      match order:
        case LT{}: {==}
        case EQ{}: {==}
        case GT{}: {==}

def Laws.floor_selects_max(a, b):
  match a b:
    case 0n 0n: {==}
    case 0n 1n+y: {==}
    case 1n+x 0n: {==}
    case 1n+x 1n+y:
      %Laws.floor_selects_max(x, y) : {
        Laws.meet(~Zig.lower_bound, Laws.At{1n+x}, Laws.At{1n+y}) == next(_) : Laws.Limit}
      choose_successor(Zig.lower_bound(Zig.Ordered{Nat.cmp(x, y)}), x, y)

def floor_on_max(fact: Nat, a: Nat, b: Nat) -> {
  Laws.floor_fits(Laws.At{fact}, Laws.At{Nat.max(a, b)}) ==
  Bool.and(Laws.floor_fits(Laws.At{fact}, Laws.At{a}), Laws.floor_fits(Laws.At{fact}, Laws.At{b})) : Bool}:
  match fact a b:
    case 0n 0n 0n: {==}
    case 0n 0n 1n+y: {==}
    case 0n 1n+x 0n: {==}
    case 0n 1n+x 1n+y: {==}
    case 1n+f 0n 0n: {==}
    case 1n+f 0n 1n+y: {==}
    case 1n+f 1n+x 0n: and_true(Laws.floor_fits(Laws.At{f}, Laws.At{x}))
    case 1n+f 1n+x 1n+y: floor_on_max(f, x, y)

def floor_on_child(child: Laws.Limit, a: Nat, b: Nat) -> {
  Laws.floor_fits(child, Laws.At{Nat.max(a, b)}) ==
  Bool.and(Laws.floor_fits(child, Laws.At{a}), Laws.floor_fits(child, Laws.At{b})) : Bool}:
  match child:
    case Laws.Open{}: {==}
    case Laws.At{fact}: floor_on_max(fact, a, b)

def Laws.floor_intersection(child, a, b):
  match a b:
    case Laws.Open{} Laws.Open{}: {==}
    case Laws.Open{} Laws.At{y}: {==}
    case Laws.At{x} Laws.Open{}: and_true(Laws.floor_fits(child, Laws.At{x}))
    case Laws.At{x} Laws.At{y}:
      %Equal.sym(Laws.Limit, Laws.meet(~Zig.lower_bound, a, b),
                 Laws.At{Nat.max(x, y)}, Laws.floor_selects_max(x, y)) : {
        Laws.floor_fits(child, _) == Bool.and(Laws.floor_fits(child, a), Laws.floor_fits(child, b)) : Bool}
      floor_on_child(child, x, y)

def Laws.ceiling_comparison(c):
  match c:
    case Zig.UnrestrictedParent{}: {==}
    case Zig.UnrestrictedChild{}: {==}
    case Zig.Ordered{order}:
      match order:
        case LT{}: {==}
        case EQ{}: {==}
        case GT{}: {==}

def Laws.ceiling_selects_min(a, b):
  match a b:
    case 0n 0n: {==}
    case 0n 1n+y: {==}
    case 1n+x 0n: {==}
    case 1n+x 1n+y:
      %Laws.ceiling_selects_min(x, y) : {
        Laws.meet(~Zig.upper_bound, Laws.At{1n+x}, Laws.At{1n+y}) == next(_) : Laws.Limit}
      choose_successor(Zig.upper_bound(Zig.Ordered{Nat.cmp(x, y)}), x, y)

def ceiling_on_min(fact: Nat, a: Nat, b: Nat) -> {
  Laws.ceiling_fits(Laws.At{fact}, Laws.At{Nat.min(a, b)}) ==
  Bool.and(Laws.ceiling_fits(Laws.At{fact}, Laws.At{a}), Laws.ceiling_fits(Laws.At{fact}, Laws.At{b})) : Bool}:
  match fact a b:
    case 0n 0n 0n: {==}
    case 0n 0n 1n+y: {==}
    case 0n 1n+x 0n: {==}
    case 0n 1n+x 1n+y: {==}
    case 1n+f 0n 0n: {==}
    case 1n+f 0n 1n+y: {==}
    case 1n+f 1n+x 0n: and_false(Laws.ceiling_fits(Laws.At{f}, Laws.At{x}))
    case 1n+f 1n+x 1n+y: ceiling_on_min(f, x, y)

def ceiling_on_child(child: Laws.Limit, a: Nat, b: Nat) -> {
  Laws.ceiling_fits(child, Laws.At{Nat.min(a, b)}) ==
  Bool.and(Laws.ceiling_fits(child, Laws.At{a}), Laws.ceiling_fits(child, Laws.At{b})) : Bool}:
  match child:
    case Laws.Open{}: {==}
    case Laws.At{fact}: ceiling_on_min(fact, a, b)

def Laws.ceiling_intersection(child, a, b):
  match a b:
    case Laws.Open{} Laws.Open{}: {==}
    case Laws.Open{} Laws.At{y}: {==}
    case Laws.At{x} Laws.Open{}: and_true(Laws.ceiling_fits(child, Laws.At{x}))
    case Laws.At{x} Laws.At{y}:
      %Equal.sym(Laws.Limit, Laws.meet(~Zig.upper_bound, a, b),
                 Laws.At{Nat.min(x, y)}, Laws.ceiling_selects_min(x, y)) : {
        Laws.ceiling_fits(child, _) == Bool.and(Laws.ceiling_fits(child, a), Laws.ceiling_fits(child, b)) : Bool}
      ceiling_on_child(child, x, y)

# A binary intersection law suffices at every link in the chain.
def extend(~rule: Zig.Comparison -> Bool,
           ~pair: @+child:Laws.Limit -> @+a:Laws.Limit -> @+b:Laws.Limit ->
             {rule(Laws.relative_to(Laws.meet(~rule, a, b), child)) ==
              Bool.and(rule(Laws.relative_to(a, child)), rule(Laws.relative_to(b, child))) : Bool},
           +parents: List<&2, Laws.Limit>, +child: Laws.Limit, +held: Laws.Limit) -> {
  rule(Laws.relative_to(Laws.chain(~rule, parents, held), child)) ==
  Laws.every_parent(~rule, parents, child, rule(Laws.relative_to(held, child))) : Bool}:
  match parents:
    case Nil{}: {==}
    case head <> rest:
      %pair(child, held, head) : {
        rule(Laws.relative_to(Laws.chain(~rule, rest, Laws.meet(~rule, held, head)), child)) ==
        Laws.every_parent(~rule, rest, child, _) : Bool}
      extend(~rule, ~pair, rest, child, Laws.meet(~rule, held, head))

def Laws.floor_chain(parents, child, held):
  extend(~Zig.lower_bound, ~Laws.floor_intersection, parents, child, held)

def Laws.ceiling_chain(parents, child, held):
  extend(~Zig.upper_bound, ~Laws.ceiling_intersection, parents, child, held)
