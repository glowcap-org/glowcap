import Base

type Import is Data:
  Import{module: String, name: String, kind: String}

# Read the import section without instantiating the browser Host.
def Wasm.imports(path: String) -> IO(Result<&1, &1, String, List<&2, Import>>):
  import "./imports.js"

def Import.callback(i: Import, callback: String) -> Bool:
  Import{module, name, kind} = i
  String.eq(module, "env") && String.eq(name, callback) && String.eq(kind, "function")

def Import.matches(xs: List<&2, Import>, +behavior: String, +retire: String) -> Bool:
  match xs:
    case +a <> +b <> Nil{}:
      (Import.callback(a, behavior) && Import.callback(b, retire)) ||
        (Import.callback(b, behavior) && Import.callback(a, retire))
    case _:
      False{}

def Import.show(i: Import) -> String:
  Import{module, name, kind} = i
  module ++ "." ++ name ++ " (" ++ kind ++ ")"

def verdict(ok: Bool, found: List<&2, Import>, behavior: String, retire: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("wasm-import-check: hosted callback imports match")
    case False{}:
      IO.die(Unit, 1, "wasm-import-check: expected env functions " ++ behavior ++ " and " ++ retire ++ ", found " ++ List.show(&2, Import, Import.show, found))

def report(+found: List<&2, Import>, +behavior: String, +retire: String) -> IO(Unit):
  verdict(Import.matches(found, behavior, retire), found, behavior, retire)

def inspected(path: String, result: Result<&1, &1, String, List<&2, Import>>) -> IO(Unit):
  match result:
    case Done{found}:
      report(found, "glowcap_behavior_trampoline", "glowcap_hosted_free_trampoline")
    case Fail{message}:
      IO.die(Unit, 1, "wasm-import-check: " ++ path ++ ": " ++ message)

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> +path <> Nil{}:
      do IO<Unit>:
        result : Result<&1, &1, String, List<&2, Import>> <- Wasm.imports(path)
        inspected(path, result)
    case _:
      IO.die(Unit, 2, "usage: bend tools/wasm/import_check.bend <module.wasm>")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
