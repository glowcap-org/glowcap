import Base

# Descriptor roles are checked before table authority. Other includes routed,
# sturdy, and broken references. Neither position accepts those forms.
type Perspective is Data:
  Sent{}
  Received{}

type Descriptor is Data:
  Near{}
  Far{}
  Answer{}
  Other{}

type Roles is Data:
  Roles{target: Bool, listener: Bool}

def flip(descriptor: Descriptor) -> Descriptor:
  match descriptor:
    case Near{}: Far{}
    case Far{}: Near{}
    case Answer{}: Answer{}
    case Other{}: Other{}

def roles(perspective: Perspective, descriptor: Descriptor) -> Roles:
  match perspective descriptor:
    case Sent{} Far{}: Roles{True{}, False{}}
    case Sent{} Near{}: Roles{False{}, True{}}
    case Received{} Far{}: Roles{False{}, True{}}
    case Received{} Near{}: Roles{True{}, False{}}
    case _ Answer{}: Roles{True{}, False{}}
    case _ Other{}: Roles{False{}, False{}}

def overlaps(allowed: Roles) -> Bool:
  match allowed:
    case Roles{target, listener}: Bool.and(target, listener)

law perspective_flip_preserves_roles:
  for +descriptor: Descriptor
  {roles(Sent{}, descriptor) == roles(Received{}, flip(descriptor)) : Roles}

law target_and_listener_roles_are_disjoint:
  for +perspective: Perspective
  for +descriptor: Descriptor
  {overlaps(roles(perspective, descriptor)) == False{} : Bool}

law sender_targets_the_partners_export:
  {roles(Sent{}, Far{}) == Roles{True{}, False{}} : Roles}

law sender_names_its_own_export_as_listener:
  {roles(Sent{}, Near{}) == Roles{False{}, True{}} : Roles}

law unsupported_descriptors_have_no_role:
  for +perspective: Perspective
  {roles(perspective, Other{}) == Roles{False{}, False{}} : Roles}

# The asker’s table supplies the classification. A local listen record can
# receive a notification, but cannot be named as a partner-facing question.
type Row is Data:
  PendingQuestion{}
  SettledQuestion{}
  LocalListen{}
  Absent{}

def question_target(row: Row) -> Bool:
  match row:
    case PendingQuestion{}: True{}
    case SettledQuestion{}: True{}
    case LocalListen{}: False{}
    case Absent{}: False{}

def is_target(role: Roles) -> Bool:
  match role:
    case Roles{target, listener}: target

def may_target_question(perspective: Perspective, row: Row) -> Bool:
  Bool.and(is_target(roles(perspective, Answer{})), question_target(row))

law settlement_keeps_the_question_addressable:
  for +perspective: Perspective
  {Bool.and(may_target_question(perspective, PendingQuestion{}),
            may_target_question(perspective, SettledQuestion{})) == True{} : Bool}

law only_a_live_question_is_a_wire_target:
  for +perspective: Perspective
  {Bool.or(may_target_question(perspective, LocalListen{}),
           may_target_question(perspective, Absent{})) == False{} : Bool}
