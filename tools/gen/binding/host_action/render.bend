import Base

# Base's List.map takes affine lists. Renderers share these Data lists.

def map(~A: Data, ~B: Data, ~f: A -> B, xs: List<&2, A>) -> List<&2, B>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      f(h) <> map(~A, ~B, ~f, t)

def each(~A: Data, ~f: A -> String, xs: List<&2, A>) -> String:
  String.concat(map(~A, ~String, ~f, xs))

def joined(~A: Data, ~f: A -> String, +sep: String, xs: List<&2, A>) -> String:
  String.join(map(~A, ~String, ~f, xs), sep)
