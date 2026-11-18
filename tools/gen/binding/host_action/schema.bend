import Base
import ./abi.bend as ABI

# Values a binding reads from GlowcapHostAction before the next queue pop.
type Field is Data:
  Ticket{}
  RouteIndex{}
  Session{}
  Value{}
  ResultCode{}
  Cause{}
  Message{}

def Arm() -> Data:
  ABI.Tag

def name(a: ABI.Tag) -> String:
  ABI.name(a)

def tag(a: ABI.Tag) -> String:
  U32.show(ABI.number(a))

def arms() -> List<&2, ABI.Tag>:
  ABI.all()

def fields(a: ABI.Tag) -> List<&2, Field>:
  match a:
    case ABI.DIAL{}:
      [Ticket{}, RouteIndex{}]
    case ABI.FLUSH{}:
      [Session{}]
    case ABI.NEED_GIFT_ID{}:
      [Ticket{}]
    case ABI.SETTLE{}:
      [Ticket{}, Value{}]
    case ABI.FAIL{}:
      [Ticket{}, ResultCode{}, Cause{}, Message{}]
    case ABI.CLOSE{}:
      [Session{}, ResultCode{}]
    case ABI.RESUME{}:
      []
    case ABI.CANCEL_DIAL{}:
      [Ticket{}, RouteIndex{}]

def snake(a: ABI.Tag) -> String:
  String.to_lower(name(a))

def dash(a: ABI.Tag) -> String:
  String.join(String.split(snake(a), '_'), "-")

def capitalize(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{h, t}:
      SCon{Char.to_upper(h), t}

def variant_words(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case w <> ws:
      capitalize(w) ++ variant_words(ws)

def variant(a: ABI.Tag) -> String:
  variant_words(String.split(snake(a), '_'))

def camel_words(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case w <> ws:
      w ++ variant_words(ws)

def camel(a: ABI.Tag) -> String:
  camel_words(String.split(snake(a), '_'))
