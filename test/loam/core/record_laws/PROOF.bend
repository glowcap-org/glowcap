import Base
import ./LAWS.bend as Record

def successor_ge(+a: Nat, +b: Nat, order: {Nat.is_ge(a, b) == True{} : Bool}) ->
  {Nat.is_ge(1n+a, b) == True{} : Bool}:
  match a b:
    case 0n 0n: {==}
    case 0n 1n: {==}
    case 0n 2n+p: order
    case 1n+a 0n: {==}
    case 1n+a 1n+b: successor_ge(a, b, order)

def prepend_ge(+extra: Nat, +a: Nat, +b: Nat, order: {Nat.is_ge(a, b) == True{} : Bool}) ->
  {Nat.is_ge(Nat.add(extra, a), b) == True{} : Bool}:
  match extra:
    case 0n: order
    case 1n+p: successor_ge(Nat.add(p, a), b, prepend_ge(p, a, b, order))

def threshold(+cut: Nat, +length: Nat, +extra: Nat, +a: Nat, +b: Nat,
              order: {Nat.is_ge(a, b) == True{} : Bool}) ->
  {Nat.is_ge(Nat.add(Record.crossing(cut, Nat.add(length, extra)), a),
             Nat.add(Record.crossing(cut, length), b)) == True{} : Bool}:
  match cut length:
    case 0n _: order
    case 1n+c 0n: prepend_ge(Record.crossing(1n+c, extra), a, b, order)
    case 1n+c 1n+n: threshold(c, n, extra, a, b, order)

def Record.decimal_width_monotone(cuts, length, extra):
  match cuts:
    case Nil{}: {==}
    case cut <> rest:
      threshold(cut, length, extra, Record.digits(rest, Nat.add(length, extra)), Record.digits(rest, length),
                Record.decimal_width_monotone(rest, length, extra))

def resize(+length: Nat, +extra: Nat, +a: Nat, +b: Nat,
           order: {Nat.is_ge(a, b) == True{} : Bool}) ->
  {Nat.is_ge(Nat.add(Nat.add(length, extra), a), Nat.add(length, b)) == True{} : Bool}:
  match length:
    case 0n: prepend_ge(extra, a, b, order)
    case 1n+n: resize(n, extra, a, b, order)

def Record.payload_size_monotone(cuts, length, extra):
  resize(length, extra, 1n+Record.digits(cuts, Nat.add(length, extra)), 1n+Record.digits(cuts, length),
         Record.decimal_width_monotone(cuts, length, extra))

def Record.threshold_transition(before):
  match before:
    case 0n: ({==}, {==})
    case 1n+p: Record.threshold_transition(p)

def truth(b: Bool) -> Type:
  match b:
    case False{}: Empty
    case True{}: Unit

def impossible(e: {False{} == True{} : Bool}) -> Empty:
  %e : truth(Bool.not(_))
  Unit{}

def sum_ge(+larger: Nat, +smaller: Nat, +a: Nat, +b: Nat,
           order: {Nat.is_ge(larger, smaller) == True{} : Bool},
           other: {Nat.is_ge(a, b) == True{} : Bool}) ->
  {Nat.is_ge(Nat.add(larger, a), Nat.add(smaller, b)) == True{} : Bool}:
  match larger smaller:
    case 0n 0n: other
    case 1n+l 0n: prepend_ge(1n+l, a, b, other)
    case 0n 1n+s: Empty.absurd({Nat.is_ge(a, 1n+Nat.add(s, b)) == True{} : Bool}, impossible(order))
    case 1n+l 1n+s: sum_ge(l, s, a, b, order, other)

def zero(n: Nat) -> {Nat.is_ge(n, 0n) == True{} : Bool}:
  match n:
    case 0n: {==}
    case 1n+p: {==}

def overhead_ge(+overhead: Nat, +extra: Nat) ->
  {Nat.is_ge(Nat.add(overhead, extra), overhead) == True{} : Bool}:
  match overhead:
    case 0n: zero(extra)
    case 1n+p: overhead_ge(p, extra)

def edges_ge(+edges: Nat, +extra: Nat, +width: Nat) ->
  {Nat.is_ge(Nat.mul(Nat.add(edges, extra), width), Nat.mul(edges, width)) == True{} : Bool}:
  match edges:
    case 0n: zero(Nat.mul(extra, width))
    case 1n+r:
      sum_ge(width, width, Nat.mul(Nat.add(r, extra), width), Nat.mul(r, width),
             Nat.ge_refl(width), edges_ge(r, extra, width))

def Record.envelope_ceiling(cuts, length, more_payload, edges, more_edges, edge_width, overhead, more_overhead):
  layout = sum_ge(Nat.mul(Nat.add(edges, more_edges), edge_width), Nat.mul(edges, edge_width),
                  Nat.add(overhead, more_overhead), overhead, edges_ge(edges, more_edges, edge_width),
                  overhead_ge(overhead, more_overhead))
  sum_ge(Record.payload_size(Nat.add(length, more_payload), cuts), Record.payload_size(length, cuts),
         Nat.add(Nat.mul(Nat.add(edges, more_edges), edge_width), Nat.add(overhead, more_overhead)),
         Nat.add(Nat.mul(edges, edge_width), overhead),
         Record.payload_size_monotone(cuts, length, more_payload), layout)
