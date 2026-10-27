@0xd932ff3b52c9b6a1;

annotation max(param) :UInt64;
annotation minBytes(param) :UInt64;
annotation maxBytes(param, method) :UInt64;
annotation delivery(method) :Text;
annotation wireName(method) :Text;

interface Board {
  lists @0 () -> (value :UInt32 $max(256));
  addList @1 (name :Text $minBytes(1) $maxBytes(64))
      -> (value :TaskList) $wireName("add-list") $delivery("loam-receipt");
  list @2 (index :UInt32 $max(15)) -> (value :TaskList);
}

interface TaskList {
  name @0 () -> (value :Text $minBytes(1) $maxBytes(64));
  count @1 () -> (value :UInt32 $max(256));
  task @2 (index :UInt32 $max(255)) -> (value :Task);
  add @3 (text :Text $minBytes(1) $maxBytes(4096))
      -> (value :Task) $delivery("loam-receipt");
  move @4 (task :Task, destination :TaskList)
      -> (value :UInt32 $max(256)) $delivery("loam-receipt");
}

interface Task {
  text @0 () -> (value :Text $minBytes(1) $maxBytes(4096));
}
