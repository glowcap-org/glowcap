# conformance/keri-conformance

Small KERI fixture verifier for the accountability worked example. It checks
committed KEL/Episode fixtures with a Python oracle; it does not define
pancake's wire protocol and it does not introduce KERI into the Zig core.

## Files

| Path                                           | Role                                   |
| ---------------------------------------------- | -------------------------------------- |
| [`fixtures/sample-kel/`](fixtures/sample-kel/) | Committed sample KEL and Episodes.     |
| `oracle/verify.py`                             | Python verifier for the fixture shape. |
| `run.sh`                                       | Thin launcher around the verifier.     |

## Running

```sh
bash conformance/keri-conformance/run.sh --fixture sample-kel
```

## Posture

- This scenario is external application-layer evidence.
- Fixtures are allowed because they are named and documented under `fixtures/`.
- Generated accountability demo output belongs under
  `conformance/accountability-on-goblins/.data/` and should not become a new
  fixture by accident.
