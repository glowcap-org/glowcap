import Base

# One list entry records a positive request. The entry stores its bytes
# above the first byte, so no request can consume a slot at zero cost.
def slots(+chunks: List<&2, Nat>) -> Nat:
  match chunks:
    case Nil{}: 0n
    case extra <> rest: 1n+slots(rest)

def payload(+chunks: List<&2, Nat>) -> Nat:
  match chunks:
    case Nil{}: 0n
    case extra <> rest: 1n+Nat.add(payload(rest), extra)

def surplus(+chunks: List<&2, Nat>) -> Nat:
  match chunks:
    case Nil{}: 0n
    case extra <> rest: Nat.add(surplus(rest), extra)

law payload_pays_for_every_request:
  for +chunks: List<&2, Nat>
  {payload(chunks) == Nat.add(slots(chunks), surplus(chunks)) : Nat}

def aggregate_slots(payload_bytes: Nat, request_limit: Nat) -> Nat:
  Nat.min(payload_bytes, request_limit)

law aggregate_reserves_every_slot_in_a_partition:
  for +chunks: List<&2, Nat>
  for +unused_slots: Nat
  for +unused_bytes: Nat
  {Nat.is_le(slots(chunks), aggregate_slots(Nat.add(payload(chunks), unused_bytes),
     Nat.add(slots(chunks), unused_slots))) == True{} : Bool}

law excess_request_slots_cost_no_padding:
  for +bytes: Nat
  for +spare: Nat
  {aggregate_slots(bytes, Nat.add(bytes, spare)) == bytes : Nat}

def aggregate_bytes(+payload_bytes: Nat, request_limit: Nat, padding: Nat) -> Nat:
  match request_limit:
    case 0n: 0n
    case 1n+rest: Nat.add(payload_bytes, Nat.mul(aggregate_slots(payload_bytes, 1n+rest), padding))

law no_requests_charge_no_bytes:
  for +bytes: Nat
  for +padding: Nat
  {aggregate_bytes(bytes, 0n, padding) == 0n : Nat}

law exact_request_limit_charges_payload_once:
  for +chunks: List<&2, Nat>
  for +padding: Nat
  {aggregate_bytes(payload(chunks), slots(chunks), padding) ==
   Nat.add(payload(chunks), Nat.mul(slots(chunks), padding)) : Nat}
