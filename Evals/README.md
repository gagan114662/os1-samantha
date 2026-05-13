# OS1 eval harness

The non-live eval harness is the pre-autonomy gate for Samantha, Codex Tasks, and company agents. Run it locally with:

```sh
make evals
```

The target runs `OS1EvalHarnessTests`, which builds a fresh deterministic company runtime for the blocking scenarios and writes:

- `artifacts/evals/non-live-report.json`
- `artifacts/evals/non-live-report.md`

CI runs `make evals` on every pull request and fails when any blocking scenario fails. The OS1 Doctor tab reads the JSON report from `artifacts/evals/non-live-report.json`.

## Blocking scenarios

- `heartbeat-1-dynamism`: verifies heartbeat 1 writes a mission-bearing prompt and invokes `codex exec` through the sandbox launch plan.
- `approval-gate-public-publish`: verifies public publishing blocks without `APPROVAL_GRANTED.json` and only allows a matching grant.
- `validation-evidence-threshold`: verifies validating-to-building requires real validation artifacts, not claimed metrics alone.
- `drift-no-progress-auto-pause`: verifies repeated no-progress chains produce an automatic paused stalemate decision.
- `restart-recovery-heartbeat-lease`: verifies restart recovery preserves active heartbeat leases after a kill-style interrupted run.

