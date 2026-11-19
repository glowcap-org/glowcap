import Base

# Interned selector identities stand for byte strings. Direct invocation
# has no selector. The empty string is an ordinary selector identity.
type Invocation is Data:
  Direct{}
  Verb{selector: Nat}

type Proxy is Data:
  Caretaker{live: Bool}
  Attenuator{allowed: List<&2, Nat>}

def contains(+allowed: List<&2, Nat>, +selector: Nat) -> Bool:
  match allowed:
    case Nil{}: False{}
    case verb <> rest: Bool.or(Nat.is_eq(verb, selector), contains(rest, selector))

def passes_attenuator(invocation: Invocation, allowed: List<&2, Nat>) -> Bool:
  match invocation:
    case Direct{}: False{}
    case Verb{selector}: contains(allowed, selector)

def passes(proxy: Proxy, invocation: Invocation) -> Bool:
  match proxy:
    case Caretaker{live}: live
    case Attenuator{allowed}: passes_attenuator(invocation, allowed)

def reaches(+path: List<&2, Proxy>, +invocation: Invocation) -> Bool:
  match path:
    case Nil{}: True{}
    case proxy <> rest: Bool.and(passes(proxy, invocation), reaches(rest, invocation))

law composed_authority:
  for +outside: List<&2, Proxy>
  for +inside: List<&2, Proxy>
  for +invocation: Invocation
  {reaches(List.append(&2, Proxy, outside, inside), invocation) ==
   Bool.and(reaches(outside, invocation), reaches(inside, invocation)) : Bool}

law revocation_blocks_every_path:
  for +outside: List<&2, Proxy>
  for +inside: List<&2, Proxy>
  for +invocation: Invocation
  {reaches(List.append(&2, Proxy, outside, Caretaker{False{}} <> inside), invocation) == False{} : Bool}

law verb_grants_do_not_authorize_direct_calls:
  for +outside: List<&2, Proxy>
  for +inside: List<&2, Proxy>
  for +allowed: List<&2, Nat>
  {reaches(List.append(&2, Proxy, outside, Attenuator{allowed} <> inside), Direct{}) == False{} : Bool}

law any_listed_verb_passes:
  for +before: List<&2, Nat>
  for +selector: Nat
  for +after: List<&2, Nat>
  {passes(Attenuator{List.append(&2, Nat, before, selector <> after)}, Verb{selector}) == True{} : Bool}

# Check the negative case even when the list contains other verbs.
def excludes(+allowed: List<&2, Nat>, +selector: Nat) -> Bool:
  match allowed:
    case Nil{}: True{}
    case verb <> rest: Bool.and(Nat.is_ne(verb, selector), excludes(rest, selector))

law only_listed_verbs_pass:
  for +allowed: List<&2, Nat>
  for +selector: Nat
  {passes(Attenuator{allowed}, Verb{selector}) == Bool.not(excludes(allowed, selector)) : Bool}
