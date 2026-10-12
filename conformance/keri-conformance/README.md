# conformance/keri-conformance

Small KERI fixture verifier for the accountability worked example. It checks
committed KEL/Episode fixtures with a Python reference verifier. It does not
define glowcap's wire protocol or bring KERI into the Zig core.

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
- Fixtures live under `fixtures/`, each named and documented.
- Generated accountability demo output belongs under
  `conformance/accountability-on-goblins/.data/` and is not a fixture until
  someone copies it into `fixtures/`.
