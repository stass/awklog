# awklog

A tiny stratified Datalog interpreter in portable AWK. Two runtime files, no build
step: `awklog` (POSIX sh wrapper, does all CLI parsing) and `awklog.awk` (the whole
engine). `Makefile`, `tests/`, and `examples/` are convenience only.

`spec.md` is the design spec (authoritative on language and semantics; it says
`Dawk`/`dawk` where this project says `awklog` — see the naming table at the top of
`PLAN.md`). `PLAN.md` is the implementation plan: architecture, data layout,
milestones M0–M8, portability rules, line budget. Read the relevant PLAN section
before changing a stage; cite spec sections in comments the way the existing code
does (`spec §32`, `PLAN.md section 13`).

## Workflow: one commit per stage

Work proceeds milestone by milestone (`PLAN.md` section 11). A stage is a milestone,
or a self-contained slice of one when a milestone is large. **Every stage ends in its
own commit**, and a stage is not done — and must not be committed — until all of:

1. The stage's exit criteria in `PLAN.md` section 11 are met.
2. New test cases covering the stage exist in `tests/cases/` (see the coverage
   checklist in `PLAN.md` section 12). A stage that adds behaviour adds cases.
3. `make test` is green, and `make lint` and `make count` pass.
4. A review has been run on the staged diff (`/code-review`) and its findings are
   either fixed or explicitly dismissed with a reason.

Report test and review results honestly in the commit message and in chat; never
commit with a red harness or an unreviewed diff. If a stage is blocked partway,
say what is left rather than committing a half-stage as if finished.

Commit messages: short imperative subject naming the milestone, then what the stage
covers and what was tested, e.g. `M2: predicate and tuple tables`.

## Commands

```sh
make test                 # tests/run.sh: every case x {semi, naive} x every awk found,
                          # then tests/fuzz.sh on 25 generated programs
make sweep                # the same, but exit 2 unless all four awks are found
make fuzz                 # tests/fuzz.sh: 500 generated programs, naive vs semi vs awks
sh tests/run.sh NAME      # one case; VERBOSE=1 to list passes
make lint                 # sh -n, awk parse check, forbidden-construct grep
make count                # line count (informational; see PLAN.md section 3)
./awklog -c -v file.dl    # check only, verbose diagnostics
```

`./awklog` runs uninstalled: it prefers the `awklog.awk` sitting beside it.
`AWK=mawk ./awklog ...` picks the interpreter. All four awks in the portability
matrix are installed here (BWK awk 20200816, mawk 1.3.4, gawk 5.4.1, `gawk --posix`),
and `tests/run.sh` runs every case under each of them, so the sweep is continuous.

## Constraints that bite

- **POSIX awk only.** No `gensub`, `asort`/`asorti`, `PROCINFO`, arrays of arrays,
  `switch`, `typeof`, indirect calls, `length(array)`, whole-array `delete`, or `\s`.
  Use `a[x, y]` with explicit `SUBSEP`, `(k in a)` for membership, `array_clear()` to
  empty an array. `make lint` greps for the forbidden set; keep it passing.
- **No autovivification.** `if (a[k])` creates `a[k]`; always test with `(k in a)`.
- **Encoding hazards.** `CONVFMT`/`OFMT` are pinned to `%.17g` and `SUBSEP` to `\034`
  in `init()`; integers go through `sprintf("%d", ...)` in tuple keys. Changing any of
  these silently corrupts tuple identity — `PLAN.md` section 15 lists the traps.
- **Options travel through `ENVIRON`**, not `awk -v`, because `-v` processes escapes
  and would corrupt a query containing `\n`. The wrapper owns option parsing and
  validation; `awklog.awk` re-validates and also accepts `-v awklog_*` for direct use.
- **Everything runs in `END`.** Only option decoding lives in `BEGIN`; `die()` is only
  safe from `END`, and the `dying` flag covers the `BEGIN` path.
- **Line budget** is a guide, not a gate: spec §88.11 says ~700–1,200 lines, the
  file is past that, and the decision at M8 was not to cut lines for their own
  sake — only to take a simplification where one is real (`PLAN.md` section 3).
  Readable code, no golf (spec §87).
- Tests and the wrapper are POSIX `sh`, no bashisms. `LC_ALL=C` for byte-deterministic
  ordering.

## Style

Hard tabs for indentation, K&R braces, BSD-ish comment banners between function
groups. Comments explain *why* (the portability trap, the spec rule), not what.
