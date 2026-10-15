# conformance/keri-conformance

A Python reference verifier that checks the committed KEL and Episode fixtures
of the accountability worked example. It does not define glowcap's wire
protocol, and KERI stays out of the Zig core.

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
- Demo output stays in `conformance/accountability-on-goblins/.data/` until
  someone copies it into `fixtures/`.
