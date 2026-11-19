import Base
import ./LAWS.bend as L

law sum_associates:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  {Nat.add(Nat.add(a, b), c) == Nat.add(a, Nat.add(b, c)) : Nat}

def sum_associates(a, b, c):
  match a:
    case 0n: {==}
    case 1n+rest:
      %sum_associates(rest, b, c) : {1n+Nat.add(Nat.add(rest, b), c) == 1n+_ : Nat}
      {==}

def L.payload_pays_for_every_request(chunks):
  match chunks:
    case Nil{}: {==}
    case extra <> rest:
      +used = L.slots(rest)
      +slack = L.surplus(rest)
      %Equal.sym(Nat, L.payload(rest), Nat.add(used, slack), L.payload_pays_for_every_request(rest)) : {
        1n+Nat.add(_, extra) == 1n+Nat.add(used, Nat.add(slack, extra)) : Nat}
      Equal.cong(Nat, Nat, n => 1n+n, Nat.add(Nat.add(used, slack), extra), Nat.add(used, Nat.add(slack, extra)),
        sum_associates(used, slack, extra))

law zero_is_a_lower_bound:
  for +n: Nat
  {Nat.is_le(0n, n) == True{} : Bool}

def zero_is_a_lower_bound(n):
  match n:
    case 0n: {==}
    case 1n+rest: {==}

law a_common_prefix_survives_min:
  for +n: Nat
  for +a: Nat
  for +b: Nat
  {Nat.is_le(n, Nat.min(Nat.add(n, a), Nat.add(n, b))) == True{} : Bool}

def a_common_prefix_survives_min(n, a, b):
  match n:
    case 0n: zero_is_a_lower_bound(Nat.min(a, b))
    case 1n+rest: a_common_prefix_survives_min(rest, a, b)

def L.aggregate_reserves_every_slot_in_a_partition(chunks, unused_slots, unused_bytes):
  +used = L.slots(chunks)
  +spare = L.surplus(chunks)
  +room = Nat.add(spare, unused_bytes)
  %Equal.sym(Nat, L.payload(chunks), Nat.add(used, spare), L.payload_pays_for_every_request(chunks)) : {
    Nat.is_le(used, L.aggregate_slots(Nat.add(_, unused_bytes), Nat.add(used, unused_slots))) == True{} : Bool}
  %Equal.sym(Nat, Nat.add(Nat.add(used, spare), unused_bytes), Nat.add(used, room), sum_associates(used, spare, unused_bytes)) : {
    Nat.is_le(used, L.aggregate_slots(_, Nat.add(used, unused_slots))) == True{} : Bool}
  a_common_prefix_survives_min(used, room, unused_slots)

def L.excess_request_slots_cost_no_padding(bytes, spare):
  match bytes spare:
    case 0n 0n: {==}
    case 0n 1n+more: {==}
    case 1n+rest more:
      %L.excess_request_slots_cost_no_padding(rest, more) : {
        1n+L.aggregate_slots(rest, Nat.add(rest, more)) == 1n+_ : Nat}
      {==}

law minimum_fits_last_operand:
  for +count: Nat
  for +spare: Nat
  {L.aggregate_slots(Nat.add(count, spare), count) == count : Nat}

def minimum_fits_last_operand(count, spare):
  match count spare:
    case 0n 0n: {==}
    case 0n 1n+more: {==}
    case 1n+rest more:
      %minimum_fits_last_operand(rest, more) : {
        1n+L.aggregate_slots(Nat.add(rest, more), rest) == 1n+_ : Nat}
      {==}

law slots_at_exact_limit:
  for +chunks: List<&2, Nat>
  {L.aggregate_slots(L.payload(chunks), L.slots(chunks)) == L.slots(chunks) : Nat}

def slots_at_exact_limit(chunks):
  +count = L.slots(chunks)
  %Equal.sym(Nat, L.payload(chunks), Nat.add(count, L.surplus(chunks)), L.payload_pays_for_every_request(chunks)) : {
    L.aggregate_slots(_, count) == count : Nat}
  minimum_fits_last_operand(count, L.surplus(chunks))

def L.no_requests_charge_no_bytes(bytes, padding):
  {==}

def L.exact_request_limit_charges_payload_once(chunks, padding):
  match chunks:
    case Nil{}: {==}
    case extra <> rest:
      +batch : List<&2, Nat> = extra <> rest
      %slots_at_exact_limit(batch) : {
        L.aggregate_bytes(L.payload(batch), L.slots(batch), padding) ==
        Nat.add(L.payload(batch), Nat.mul(_, padding)) : Nat}
      {==}
