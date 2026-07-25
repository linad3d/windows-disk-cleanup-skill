# Trigger evaluation

Does the skill fire when it should, and stay quiet when it should not?

## Result

| Metric | Score |
|---|---|
| Recall (should-trigger fired) | **10/10 — 100%** |
| Specificity (should-not-trigger held) | **9/9 — 100%** |
| Accuracy | **19/19 — 100%** |
| Median detection time | ~10 s |

Run against `claude-opus-5` on `trigger-eval.json` (10 positive, 10 near-miss negative
queries, mixed English and Chinese). One negative query hit the hard timeout without
producing a skill signal and is excluded from scoring; it was correctly classified as
non-triggering in two earlier runs.

An earlier revision of the description scored 80% recall. The two misses were phrasings
the description did not name — *"is it safe to delete this cache folder?"* and *moving
developer package caches off the system drive* — and both now fire. Naming the phrasing
mattered more than describing the capability.

## Why the bundled harness is not used

`skill-creator`'s `scripts/run_eval.py` calls `select.select()` on a subprocess pipe.
On Windows `select()` accepts only sockets, so every query raises `WinError 10038` and is
recorded as "did not trigger" — producing a confident-looking 0% recall and 100%
precision that is entirely an artifact. Feeding that into the description optimizer makes
the description worse on every iteration.

A first replacement used `subprocess.run` with a timeout, which introduced a subtler
bias in the same direction: queries that *do* trigger the skill go on to do real work and
blow the timeout, while queries that do *not* trigger answer immediately and record
cleanly. Recall collapses, specificity looks perfect — the same misleading shape as the
original bug, from a different cause.

The working approach reads the stream line by line (blocking `readline` is fine on
Windows; only `select()` is not) and kills the process the moment the `Skill` tool
appears. Detection lands in seconds, so there is no timeout bias and far fewer tokens are
spent.

**The general lesson:** when an automated metric comes back all-zero or all-perfect,
suspect the harness before the thing being measured.

## Reproducing

`trigger_test.py` is not bundled here — it is ~140 lines of Python and the approach is
what matters:

1. Create a temp directory containing `.claude/skills/<skill-name>/`.
2. For each query, run
   `claude -p "<query>" --output-format stream-json --verbose --include-partial-messages --permission-mode plan`
   with `cwd` set to that directory and `CLAUDECODE` removed from the environment so the
   nested session starts.
3. Read stdout line by line. Parse each line as JSON and look for a `tool_use` block
   named `Skill` whose input mentions the skill name.
4. Kill the process on the first match. Score against the expected label.

Use `--permission-mode plan` so a triggered skill cannot modify anything while under
test — relevant here, since this skill deletes files.
