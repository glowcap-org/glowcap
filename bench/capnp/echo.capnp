@0xac58e4987ebebd31;

# Two call shapes, the same on every side of the comparison in bench/README.md.
# `greet` is the smallest message that is still a call. `report` is one
# application batch: a source name, a few tags, and sixty-four readings, and
# the server reads every reading to answer.
interface Echo {
  greet @0 (name :Text) -> (greeting :Text);
  report @1 (source :Text, tags :List(Text), samples :List(Int64), at :Int64) -> (count :UInt32, sum :Int64);
}
