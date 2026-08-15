# A stream provider's refusal path unwraps a cancel callback it does not require

`zig build check` panics in `test/c_abi/driver_loop_test.zig`, in the test named
"an immediate-only stream listener rejects pending ownership without a fake
cancel callback":

```
thread panic: attempt to use null value
src/c_abi/driver/provider_registry.zig:945:62 in cancelListenHandle
        return self.callStreamCancel(self.table.cancel_listen.?, attempt, "stream cancel_listen");
src/c_abi/driver/provider_registry.zig:856:52 in listen
```

A provider whose `listen` answers immediately need not supply `cancel_listen`,
which is what that test's name says it is checking. When such a provider hands
back pending-operation fields anyway, `listen` refuses the contract and cleans
up, and the cleanup calls `cancelListenHandle` for the returned attempt. That
function unwraps `table.cancel_listen`, so the refusal path requires the very
callback the refused provider was allowed to omit, and the process aborts on the
path whose whole purpose is to fail closed.

The two call sites differ: `cancelListen` is reached through the vtable, which
the registry only installs for a table that has the callback, while the refusal
path above reaches it directly.

Arrived with commit `f143317c5` ("Return provider teardown failures to their
owners"), which added both the code and the test.

This is core C ABI work, so it is written down here rather than fixed from the
rooms tree. It is owned by whoever is working on the provider registry.
