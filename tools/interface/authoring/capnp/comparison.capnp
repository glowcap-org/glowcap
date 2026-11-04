@0xf3f3de678a47c902;

annotation module(file) :Text;
annotation alias(struct) :Void;
annotation min(field) :Int64;
annotation max(field) :Int64;
annotation minBytes(field) :UInt64;
annotation maxBytes(field) :UInt64;
annotation optional(param) :Void;
annotation nullValue(param) :Void;
annotation pending(param) :Void;
annotation direct(method) :Void;
annotation wireName(method) :Text;
annotation delivery(method) :Text;

$module("comparison");

# `using` aliases disappear from CodeGeneratorRequest. Explicit wrappers keep
# the named alias and bounds available without reading source text again.
struct Name $alias { value @0 :Text $minBytes(1) $maxBytes(64); }
struct Count $alias { value @0 :Int64 $min(0) $max(16); }

interface Reader { read @0 () -> (value :Text); }
interface Factory {
  add @0 (name :Name) -> (value :Reader) $delivery("loam.receipt");
  accept @1 (reader :Reader, pending :Reader $pending) -> (value :Void);
}
interface Prepared {
  accept @0 (pending :AnyPointer $pending) -> (value :Void) $delivery("loam.receipt");
}
interface Direct {
  invoke @0 (value :Void $optional) -> (value :Void) $direct;
}
interface Named {
  empty @0 () -> (value :Text) $wireName("");
  then @1 () -> (value :Text);
  quoted @2 () -> (value :Text) $wireName("a-b");
  required @3 (value :Void) -> (value :Void);
  optional @4 (value :Void $optional) -> (value :Void);
  nullInput @5 (value :Void $nullValue) -> (value :Void) $wireName("null-input");
  nullResult @6 () -> (value :Void $nullValue) $wireName("null-result");
}
