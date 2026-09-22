# Dawk

## A tiny stratified Datalog interpreter in portable AWK

**Status:** Draft engineering specification
**Implementation language:** POSIX AWK
**Primary interface:** command-line interpreter
**License target:** 2-clause BSD
**Target size:** approximately 700–1,200 lines of AWK
**External dependencies:** none beyond a POSIX `awk` implementation

---

# 1. Overview

Dawk is a small, portable implementation of Datalog written entirely in AWK.

It is intended to provide a genuinely useful declarative query and inference language while remaining small enough to understand in one sitting.

The implementation provides:

* ground facts;
* function-free rules;
* recursive predicates;
* safe variables;
* stratified negation;
* integer and string values;
* equality and comparison predicates;
* semi-naive evaluation;
* command-line queries;
* interactive queries;
* deterministic optional output sorting;
* no external dependencies.

Dawk intentionally does **not** implement Prolog.

The architecture is:

```text
source
  ↓
tiny lexer/parser
  ↓
facts + rules
  ↓
semantic validation
  ↓
predicate dependency graph
  ↓
stratification
  ↓
semi-naive bottom-up evaluation
  ↓
query results
```

The entire interpreter should run using:

```sh
awk -f dawk.awk program.dl
```

A small shell launcher named `dawk` may provide a friendlier CLI.

---

# 2. Design Goals

Dawk should be:

### Tiny

The entire implementation should ideally remain below approximately 1,000 lines of meaningful AWK code.

Readability takes priority over squeezing line count.

### Portable

The core interpreter must target POSIX AWK.

It must work with implementations including:

```text
BWK awk / one-true-awk
FreeBSD awk
OpenBSD awk
NetBSD awk
macOS awk
mawk
gawk in POSIX-compatible usage
```

No gawk-specific features may be required.

### Useful

Dawk should support enough Datalog to solve real problems such as:

```text
dependency analysis
task tracking
graph reachability
configuration checking
policy reasoning
package relationships
build graphs
small static-analysis datasets
network topology
access-control logic
```

### Predictable

Dawk uses declarative Datalog semantics.

Rule body order must not affect logical meaning.

There are no cuts, procedural side effects, or Prolog-style search semantics.

### Auditable

An experienced programmer should be able to understand the complete evaluation engine without requiring specialized logic-programming knowledge.

---

# 3. Non-Goals

Dawk does not implement:

* Prolog;
* compound function terms;
* lists;
* cut;
* dynamic predicates;
* mutable rules;
* arbitrary evaluation order;
* meta-calls;
* constraint logic programming;
* unstratified negation;
* well-founded semantics;
* answer-set programming;
* floats;
* aggregates;
* persistence;
* transactions;
* incremental update maintenance;
* Magic Sets;
* query planning beyond simple literal reordering;
* sophisticated indexes;
* parallel evaluation.

These features may be reconsidered later, but only if they preserve the simplicity of the implementation.

---

# 4. Basic Usage

Example program:

```prolog
edge(a, b).
edge(b, c).
edge(c, d).

path(X, Y) :-
    edge(X, Y).

path(X, Z) :-
    edge(X, Y),
    path(Y, Z).

path(a, X)?
```

Execution:

```sh
dawk graph.dl
```

Output:

```text
b
c
d
```

External query:

```sh
dawk -q 'path(a, X)?' graph.dl
```

---

# 5. Source Language

## 5.1 Facts

A fact is a ground relation:

```prolog
edge(a, b).
status(parser, todo).
priority(parser, 10).
title(parser, "Rewrite parser").
```

Facts must contain no variables.

Duplicate facts have no semantic effect.

---

# 6. Predicates

Predicates are identified by:

```text
name / arity
```

Therefore:

```prolog
foo(a).
foo(a, b).
```

are separate predicates:

```text
foo/1
foo/2
```

Predicate identifiers begin with a lowercase ASCII letter and may contain:

```text
a-z
A-Z
0-9
_
```

Recommended grammar:

```text
[a-z][A-Za-z0-9_]*
```

---

# 7. Values

Dawk supports three kinds of constants.

## 7.1 Symbols

```prolog
todo
parser
openbdb
foo_bar
```

Symbols are identifiers beginning with a lowercase letter.

## 7.2 Strings

```prolog
"Rewrite parser"
"hello world"
```

Supported escapes:

```text
\\
\"
\n
\t
\r
```

No Unicode escape syntax is required.

AWK strings may contain arbitrary bytes supported by the host AWK implementation.

## 7.3 Integers

Signed decimal integers:

```text
0
10
-42
922337203685477580
```

Because POSIX AWK numbers are normally IEEE-754 doubles, Dawk cannot reliably provide true 64-bit integer precision on every implementation.

Therefore the language specification distinguishes:

```text
lexical integer
numeric comparison domain
```

For v1, numeric operations follow the host AWK numeric range and precision.

Dawk should document this explicitly.

If exact large integers matter, they may be represented as symbols or strings.

---

# 8. Variables

Variables begin with an uppercase ASCII letter:

```prolog
X
Node
Dependency
Status
```

Grammar:

```text
[A-Z][A-Za-z0-9_]*
```

Variables are local to one rule or query.

---

# 9. Anonymous Variable

`_` denotes an anonymous variable.

Example:

```prolog
edge(X, _).
```

Every occurrence of `_` represents a different logical variable.

For example:

```prolog
pair(_, _).
```

does not require both values to be equal.

Internally, the parser should rewrite anonymous variables to unique hidden variable IDs.

---

# 10. Rules

Syntax:

```prolog
head :-
    body.
```

Example:

```prolog
unfinished(X) :-
    status(X, todo).
```

Conjunction is represented by commas:

```prolog
blocked(X) :-
    depends(X, Y),
    unfinished(Y).
```

Rules may be recursive:

```prolog
path(X, Z) :-
    edge(X, Y),
    path(Y, Z).
```

Mutual recursion is permitted:

```prolog
a(X) :- b(X).
b(X) :- a(X).
```

provided the recursion is positive.

---

# 11. Negation

Dawk supports stratified negation:

```prolog
ready(X) :-
    todo(X),
    not blocked(X).
```

Negation means absence from a relation whose value is already complete.

Dawk does not implement negation-as-failure in the general Prolog sense.

---

# 12. Stratified Negation

The program must be stratifiable.

Example:

```prolog
blocked(X) :-
    depends(X, Y),
    unfinished(Y).

ready(X) :-
    todo(X),
    not blocked(X).
```

can be arranged as:

```text
stratum 0:
    depends
    unfinished
    todo

stratum 1:
    blocked

stratum 2:
    ready
```

This is valid.

The following is invalid:

```prolog
a(X) :-
    not b(X).

b(X) :-
    not a(X).
```

Dawk must reject it before evaluation.

---

# 13. Comparisons

Built-in operators:

```text
=
!=
<
<=
>
>=
```

Examples:

```prolog
large(X) :-
    size(X, N),
    N >= 100.
```

```prolog
different(X, Y) :-
    edge(X, Y),
    X != Y.
```

Equality may compare symbols, strings, integers, or variables.

Ordering comparisons should require numeric operands in v1.

That means:

```prolog
X < Y
```

is legal only when both resolve to numeric values.

String ordering is deliberately omitted.

---

# 14. Queries

Queries terminate in `?`.

Examples:

```prolog
ready(X)?
```

```prolog
path(a, X)?
```

```prolog
depends(X, Y), status(Y, todo)?
```

A query is logically equivalent to a temporary rule:

```prolog
__query(X, Y) :-
    depends(X, Y),
    status(Y, todo).
```

The output columns correspond to named variables in order of first appearance.

---

# 15. Ground Queries

Ground queries are valid:

```prolog
path(a, c)?
```

Result:

```text
true
```

or:

```text
false
```

This behavior should be standardized.

---

# 16. Comments

A percent sign starts a line comment:

```prolog
% This is a comment

edge(a, b). % Inline comments are allowed
```

The comment extends to the end of the physical line unless `%` appears inside a quoted string.

---

# 17. Grammar

Approximate grammar:

```text
program
    := statement*

statement
    := fact "."
     | rule "."
     | query "?"

fact
    := atom

rule
    := atom ":-" body

query
    := body

body
    := literal ("," literal)*

literal
    := atom
     | "not" atom
     | comparison

atom
    := identifier
     | identifier "(" [term ("," term)*] ")"

term
    := variable
     | anonymous
     | symbol
     | string
     | integer

comparison
    := term comparator term

comparator
    := "="
     | "!="
     | "<"
     | "<="
     | ">"
     | ">="
```

Zero-arity predicates are supported:

```prolog
initialized.
```

---

# 18. Parser Architecture

Dawk should contain an actual lexer.

Do not attempt to parse complete statements using large regular expressions.

Recommended interface:

```awk
function lex_next(...)
function parse_program(...)
function parse_statement(...)
function parse_atom(...)
function parse_term(...)
function parse_body(...)
```

Tokens include:

```text
IDENT
VARIABLE
INTEGER
STRING
LPAREN
RPAREN
COMMA
DOT
QUERY
RULE
NOT
EQ
NE
LT
LE
GT
GE
EOF
```

---

# 19. Input Handling

The lexer should read the entire logical input stream into a source string or line buffer.

Because Datalog statements may span lines:

```prolog
blocked(X) :-
    depends(X, Y),
    unfinished(Y).
```

line-oriented parsing alone is insufficient.

The simplest implementation is:

1. read all input lines;
2. concatenate into one source buffer;
3. lex from a numeric source offset.

This is acceptable for Dawk's intended workload.

---

# 20. Source Locations

The lexer should track:

```text
filename
line
column
```

Diagnostics should resemble:

```text
project.dl:18:7: syntax error: expected ')'
```

Exact byte offsets need not be exposed.

---

# 21. Internal Representation

The interpreter should avoid complicated object structures.

Parsed objects receive integer IDs.

For example:

```text
rule 1
rule 2
rule 3
```

Arrays store their properties:

```awk
rule_head_pred[r]
rule_head_arity[r]

rule_body_count[r]
rule_body_kind[r, i]
rule_body_pred[r, i]
```

Terms similarly use indexed arrays.

This is preferable to encoding whole ASTs as strings.

---

# 22. Variable Compilation

During rule parsing, each variable receives a small integer slot:

```text
X -> 1
Y -> 2
Z -> 3
```

Store:

```awk
term_kind[r, literal, arg]
term_value[r, literal, arg]
```

where variable values are slot IDs.

Example:

```prolog
path(X, Z) :-
    edge(X, Y),
    path(Y, Z).
```

becomes approximately:

```text
X = v1
Z = v2
Y = v3
```

This eliminates variable-name lookup during evaluation.

---

# 23. Predicate Table

Predicates also receive integer IDs:

```text
edge/2   -> predicate 1
path/2   -> predicate 2
status/2 -> predicate 3
```

Arrays:

```awk
pred_name[p]
pred_arity[p]
```

Predicate lookup key:

```awk
pred_id[name SUBSEP arity]
```

---

# 24. Tuple Storage

Every ground tuple receives an integer tuple ID.

Example:

```text
tuple 1:
    edge(a,b)

tuple 2:
    edge(b,c)
```

Representation:

```awk
tuple_pred[t]
tuple_arg[t, 1]
tuple_arg[t, 2]
```

Predicate membership list:

```awk
pred_tuple[p, n] = t
pred_tuple_count[p]
```

---

# 25. Tuple Deduplication

Maintain a canonical membership hash.

Example key:

```text
predicate-id SUBSEP encoded-arg1 SUBSEP encoded-arg2
```

Array:

```awk
tuple_exists[key] = tuple_id
```

Insertion:

```awk
function fact_add(p, args,    key, t)
```

returns:

```text
1 if new
0 if already present
```

Set semantics therefore fall naturally out of AWK associative arrays.

---

# 26. Value Encoding

To prevent collisions between:

```text
symbol foo
string "foo"
number foo-like text
```

values should be encoded internally with a type prefix.

For example:

```text
s:foo
q:foo
n:42
```

where:

```text
s = symbol
q = quoted string
n = numeric
```

The evaluator compares encoded values for equality.

Output decoding occurs only when formatting query answers.

---

# 27. Relation Access

The simplest initial relation scan is:

```awk
for (i = 1; i <= pred_tuple_count[p]; i++) {
    t = pred_tuple[p, i]
    ...
}
```

This ensures a rule scans only the relevant predicate rather than all facts.

No secondary indexes are required in v1.

---

# 28. Binding Environments

A rule body is evaluated against bindings.

For one active binding:

```awk
bound[var] = 1
value[var] = encoded_value
```

Because POSIX AWK arrays cannot be passed by value and nested arrays are unavailable, bindings should not be represented as arrays-of-arrays.

Instead, use numeric binding IDs.

Example:

```awk
bind_set[b, var] = value
bind_has[b, var] = 1
```

and:

```awk
binding_count
```

---

# 29. Binding Sets

Rule evaluation progresses using two binding collections:

```text
current bindings
next bindings
```

Conceptually:

```text
{ {} }

edge(X,Y)
    ↓
{ X=a,Y=b }
{ X=b,Y=c }

path(Y,Z)
    ↓
...
```

Each body literal expands or filters bindings.

---

# 30. Positive Literal Matching

Given:

```prolog
edge(X, Y)
```

and tuple:

```prolog
edge(a, b)
```

matching performs:

```text
if X unbound:
    bind X = a
else:
    require X == a

if Y unbound:
    bind Y = b
else:
    require Y == b
```

No recursive general-purpose unification is required.

---

# 31. Literal Evaluation

Each literal is one of:

```text
positive relation
negative relation
comparison
```

Positive relation:

```text
expand bindings through relation tuples
```

Negative relation:

```text
reject binding if matching tuple exists
```

Comparison:

```text
test current binding
```

---

# 32. Rule Safety

Dawk must statically validate range restriction.

Every variable in a rule head must appear in at least one positive body relation.

Valid:

```prolog
foo(X) :-
    bar(X).
```

Invalid:

```prolog
foo(X) :-
    bar(Y).
```

---

# 33. Negative Literal Safety

All variables in a negated literal must be bindable by positive literals in the same rule.

Valid:

```prolog
ready(X) :-
    card(X),
    not blocked(X).
```

Invalid:

```prolog
ready(X) :-
    not blocked(X).
```

This validation should be independent of textual body order because the interpreter may reorder body literals.

---

# 34. Comparison Safety

Variables used in comparison filters must be bound by positive relational literals.

Valid:

```prolog
large(X) :-
    size(X, N),
    N > 100.
```

Invalid:

```prolog
large(X) :-
    N > 100.
```

---

# 35. Body Reordering

Positive relation literals may be reordered for efficiency.

A simple heuristic is sufficient.

At each step, choose the remaining positive literal with:

1. the largest number of already-bound variables;
2. then the smallest current relation;
3. then original source position.

After sufficient bindings exist, apply comparisons and negated literals as early as safely possible.

This optimization should remain small and deterministic.

---

# 36. Dependency Graph

For every rule:

```prolog
p(...) :-
    q(...),
    not r(...).
```

record:

```text
p -> q  positive
p -> r  negative
```

Arrays may use:

```awk
dep_pos[p, q] = 1
dep_neg[p, r] = 1
```

The number of predicates should normally be small enough that simple O(P²) graph algorithms are acceptable.

---

# 37. Stratification Algorithm

A compact iterative algorithm is preferred over implementing a complicated graph package.

Start:

```text
stratum[p] = 0
```

Repeatedly apply:

For positive dependency:

```text
stratum[p] >= stratum[q]
```

For negative dependency:

```text
stratum[p] > stratum[q]
```

Therefore:

```awk
if (dep_pos[p,q] && stratum[p] < stratum[q])
    stratum[p] = stratum[q]

if (dep_neg[p,q] && stratum[p] <= stratum[q])
    stratum[p] = stratum[q] + 1
```

Continue until stable.

If strata keep increasing beyond the number of predicates, a negative cycle exists.

Reject the program.

This avoids needing Tarjan's SCC algorithm in the AWK implementation.

---

# 38. Stratification Bound

For `P` predicates, no valid stratification requires a stratum greater than `P - 1`.

Therefore if an iterative update produces:

```text
stratum[p] >= P
```

the program is unstratifiable.

Diagnostic example:

```text
policy.dl: error: program contains recursion through negation
```

A more detailed dependency trace is optional.

---

# 39. Evaluation by Stratum

For:

```text
s = 0 ... maximum_stratum
```

evaluate all predicates belonging to stratum `s` to a fixed point before proceeding to `s+1`.

Lower-stratum relations are immutable while evaluating a higher stratum.

This makes negation straightforward.

---

# 40. Initial Naive Evaluator

A simple fixed-point evaluator should remain conceptually available:

```text
repeat
    changed = false

    for each rule in stratum
        evaluate rule against all facts
        insert resulting heads
        if anything inserted:
            changed = true
until !changed
```

This may be retained as:

```text
-D naive
```

or as test-only code.

It is extremely valuable as a correctness oracle.

---

# 41. Semi-Naive Evaluation

Production evaluation should use semi-naive deltas for recursive strata.

Maintain:

```text
all relation facts
delta relation facts
new relation facts
```

For recursive rules, only derivations involving at least one tuple added in the previous iteration need to be reconsidered.

---

# 42. Delta Storage

For each predicate:

```awk
delta_tuple[p, n]
delta_count[p]

next_delta_tuple[p, n]
next_delta_count[p]
```

Tuples still live in the global tuple table.

Delta structures store tuple IDs only.

---

# 43. Initial Delta

At the start of a recursive stratum:

```text
delta = all facts currently known for relations in the recursive component
```

or, more precisely, facts newly available to that component before its first recursive round.

For simplicity, Dawk may seed deltas with the current contents of recursive predicates.

---

# 44. Recursive Rule Variants

Consider:

```prolog
path(X, Z) :-
    path(X, Y),
    edge(Y, Z).
```

The recursive relation is `path`.

The semi-naive variant uses:

```text
Δpath × edge
```

rather than:

```text
path × edge
```

on every iteration.

---

# 45. Multiple Recursive Literals

For:

```prolog
p(X, Z) :-
    p(X, Y),
    p(Y, Z).
```

generate variants conceptually equivalent to:

```text
Δp × p
p × Δp
```

Every recursive derivation in an iteration must use at least one delta input.

Duplicate results are eliminated by normal tuple insertion.

---

# 46. Simpler Implementation Option

Because Dawk prioritizes small code over extreme performance, it may implement semi-naive evaluation by:

1. identifying recursive body literals;
2. running the rule once for each recursive body position designated as the delta relation;
3. using normal relation scanning for all other literals.

No separate compiled rule representation is required.

---

# 47. Non-Recursive Rules

Rules whose head predicate is not recursively dependent on itself need only be evaluated once after their dependencies are complete.

Example:

```prolog
unfinished(X) :-
    status(X, todo).
```

No fixed-point loop is required if `unfinished` is outside a recursive SCC.

However, to keep Dawk small, evaluating all rules in a stratum to fixed point is acceptable initially.

Semi-naive optimization matters primarily for recursion.

---

# 48. Recursive Component Detection

For the first implementation, Dawk may conservatively treat a whole stratum as recursive.

This simplifies implementation.

Later, a simple reachability test can determine whether:

```text
p -> ... -> p
```

exists.

Because rule sets are expected to be small, O(P³) transitive-closure detection is acceptable.

No sophisticated SCC algorithm is required.

---

# 49. Negated Literal Evaluation

Example:

```prolog
ready(X) :-
    todo(X),
    not blocked(X).
```

Once `X` is bound, construct the candidate tuple:

```text
blocked(X)
```

and check:

```awk
if (!(key in tuple_exists))
    succeed
```

Negation therefore requires no relation scan when all arguments are bound.

---

# 50. Partially Bound Negation

Safe Datalog usually permits variables in a negated literal only if they are already bound.

Dawk adopts this requirement.

Thus:

```prolog
foo(X) :-
    bar(X),
    not baz(X, Y).
```

is rejected unless `Y` is bound elsewhere positively before the negation.

This allows negation to reduce to tuple membership.

---

# 51. Equality

Equality may bind a variable only if the other side is already bound or constant.

Examples:

```prolog
same(X) :-
    value(X),
    X = foo.
```

For simplicity, Dawk may initially treat `=` strictly as a filter and require both sides to already be bound.

This restriction is acceptable for v1 and keeps evaluation simple.

---

# 52. Query Execution

Queries are evaluated after the program reaches its fixed point.

This means:

```prolog
path(a, X)?
```

does **not** restrict recursive materialization.

Dawk intentionally does not implement Magic Sets.

For small and medium datasets this behavior is acceptable.

---

# 53. Embedded Queries

A file may contain:

```prolog
path(a, X)?
ready(X)?
```

Queries execute in source order after all program facts and rules have been evaluated.

Queries themselves do not alter the program.

---

# 54. External Query

The CLI supports:

```sh
dawk -q 'path(a, X)?' graph.dl
```

Multiple `-q` options are allowed:

```sh
dawk \
    -q 'ready(X)?' \
    -q 'blocked(X)?' \
    project.dl
```

---

# 55. Command-Line Interface

Preferred syntax:

```text
dawk [-cinsv] [-F format] [-q query] [file ...]
```

Options:

```text
-c        check syntax and semantics only
-i        interactive mode after evaluation
-n        suppress normal output
-q query  execute query after loading program
-s        sort query output
-v        verbose diagnostics; repeatable

-F fmt    output format
```

Supported formats:

```text
text
csv
tsv
```

JSON is deliberately omitted from the first implementation because correctly quoting JSON in portable AWK adds disproportionate complexity.

It may be added later.

---

# 56. BSD-Style CLI

The wrapper should use traditional short options only.

Examples:

```sh
dawk -c policy.dl
dawk -q 'path(a, X)?' graph.dl
dawk -s -F csv -q 'edge(X,Y)?' graph.dl
```

No mandatory GNU-style long options.

---

# 57. AWK Argument Handling

The shell wrapper is responsible for normal command-line parsing.

Preferred launcher:

```sh
#!/bin/sh
```

using POSIX `getopts`.

It translates options to AWK variables:

```sh
awk \
    -v DAWK_QUERY="$query" \
    -v DAWK_FORMAT="$format" \
    -f /usr/local/libexec/dawk.awk \
    "$@"
```

For multiple queries, the wrapper may concatenate them using a private separator.

Alternatively Dawk may inspect and modify `ARGV` itself.

The shell wrapper approach is cleaner.

---

# 58. Direct Invocation

The AWK implementation should still be usable directly:

```sh
awk -f dawk.awk graph.dl
```

Embedded queries in the file work normally.

The wrapper provides only convenience features.

---

# 59. Interactive Mode

Example:

```text
$ dawk -i graph.dl

dawk> path(a, X)?
b
c
d

dawk> edge(X, Y)?
a b
b c
c d

dawk> .quit
```

Minimal commands:

```text
.help
.stats
.quit
```

No readline dependency.

Host terminal line editing is whatever the shell/TTY naturally provides.

---

# 60. Output

Default text format is intentionally plain.

Single-column result:

```text
parser
planner
storage
```

Multiple columns:

```text
parser lexer
planner parser
storage freelist
```

Strings containing whitespace should be quoted when printed in text mode.

---

# 61. CSV Output

Example:

```sh
dawk -F csv -q 'depends(X,Y)?' project.dl
```

Output:

```text
parser,lexer
planner,parser
```

Correct CSV quoting must be implemented:

```text
"hello, world"
"quote ""inside"""
```

---

# 62. TSV Output

TSV escaping should handle:

```text
tab
newline
backslash
```

or quote complete values consistently.

A documented stable format is more important than matching an external convention.

---

# 63. Result Ordering

Datalog relations are mathematically unordered.

Default Dawk output order is unspecified.

For reproducible output:

```sh
dawk -s ...
```

sorting should happen externally if possible:

```text
generate rows
pipe internally or via wrapper to sort
```

Because POSIX AWK has no portable `asort()`, the wrapper may invoke POSIX `sort`.

Therefore:

```text
-s
```

may be implemented by the shell launcher rather than `dawk.awk`.

This keeps the AWK core portable.

---

# 64. Diagnostics

Examples:

```text
project.dl:14:3: syntax error: expected predicate
```

```text
project.dl:21:1: unsafe rule: variable Y is not positively bound
```

```text
policy.dl:8:1: program is not stratified
```

Errors go to stderr.

AWK supports:

```awk
print message > "/dev/stderr"
```

but `/dev/stderr` is not strictly POSIX.

For portability, the wrapper may pass:

```text
DAWK_STDERR=/dev/stderr
```

on BSD/Linux systems.

Alternatively use:

```awk
print message | "cat >&2"
```

but this is undesirable.

Target platforms all provide `/dev/stderr`, so Dawk may pragmatically require it.

---

# 65. Exit Status

Recommended:

```text
0 success
1 source/program error
2 usage error
```

The shell wrapper should preserve AWK's exit code.

---

# 66. Statistics

Interactive:

```text
.stats
```

or verbose mode may report:

```text
predicates: 12
facts:      683
rules:      17
strata:     3
iterations: 8
derived:    512
```

Statistics should not be printed by default.

---

# 67. Internal Counters

Useful counters:

```awk
stat_input_facts
stat_derived_facts
stat_rules
stat_predicates
stat_rule_runs
stat_tuple_scans
stat_iterations
```

These help compare naive and semi-naive evaluation.

---

# 68. Memory Model

Dawk relies entirely on AWK-managed memory.

No explicit allocation exists.

Implementation should nevertheless delete transient arrays aggressively:

```awk
delete current_bind
delete next_bind
```

where portable AWK supports whole-array `delete`.

Because POSIX historically does not require:

```awk
delete array
```

strict portability may instead use a helper:

```awk
function array_clear(a, k) {
    for (k in a)
        delete a[k]
}
```

Use this portable form in core code.

---

# 69. Avoiding Arrays of Arrays

The core must never require:

```awk
foo[x][y]
```

because this is a gawk extension.

Use:

```awk
foo[x, y]
```

which AWK internally converts using `SUBSEP`.

---

# 70. Avoiding gawk Extensions

Forbidden in core Dawk:

```text
asort()
asorti()
gensub()
PROCINFO
arrays of arrays
@namespace
typeof()
switch, unless verified as POSIX target assumption
indirect function calls
```

Use only facilities available in traditional/POSIX AWK.

---

# 71. Relation Size Limits

No artificial language-level tuple limit is required.

Practical limits are determined by:

```text
host AWK memory
numeric indexing precision
host process limits
```

Dawk should remain intended for small-to-medium data.

Recommended usage envelope:

```text
hundreds of rules
tens of thousands of facts
possibly hundreds of thousands on fast AWK implementations
```

Performance beyond this is implementation-dependent.

---

# 72. Complexity Expectations

Without secondary indexes:

```text
literal evaluation ≈ number of tuples in predicate
```

A rule such as:

```prolog
p(X,Z) :-
    a(X,Y),
    b(Y,Z).
```

may therefore be O(|a| × |b|) in the worst case.

This is acceptable for the reference implementation.

The important optimization is semi-naive recursion, not sophisticated join indexing.

---

# 73. Optional Single-Column Indexes

If the implementation remains simple enough, Dawk may later add indexes:

```text
predicate
argument position
argument value
→ tuple IDs
```

Conceptually:

```awk
idx[p, col, value, n] = tuple_id
idx_count[p, col, value] = n
```

Then:

```prolog
edge(a, X)
```

need not scan all `edge` tuples.

This is explicitly optional for v1.

---

# 74. Naive Reference Mode

Dawk should ideally support:

```sh
dawk -D naive ...
```

for development, even if not documented for end users.

This evaluates every rule against complete relations until fixed point.

The optimized semi-naive evaluator can then be continuously checked against it.

If a separate mode complicates the public CLI, retain the naive engine only in the test version.

---

# 75. Testing

Every test should consist of:

```text
input Datalog
query
expected rows
```

Important test categories:

```text
simple facts
single rule
multiple rules
recursive path
cyclic recursion
mutual recursion
duplicate facts
anonymous variables
strings
integers
comparison operators
safe negation
multiple strata
invalid negative recursion
unsafe variables
syntax errors
ground queries
multi-variable queries
semi-naive equivalence
```

---

# 76. Differential Testing

A particularly useful strategy:

Run the same program through:

```text
naive evaluator
semi-naive evaluator
```

and compare every relation.

Expected:

```text
naive(program) == semi_naive(program)
```

for every valid positive or stratified program.

---

# 77. Random Program Testing

A small generator may produce safe programs containing:

```text
facts
non-recursive rules
recursive rules
stratified negation
```

The generator can be written in Python, shell, C, or AWK and need not be part of runtime Dawk.

Generated programs are evaluated in both modes.

This provides excellent coverage for a tiny evaluator.

---

# 78. Example: Project Tracker

```prolog
card(parser).
card(planner).
card(storage).

status(parser, done).
status(planner, todo).
status(storage, todo).

depends(planner, parser).
depends(storage, planner).

unfinished(X) :-
    status(X, todo).

blocked(X) :-
    depends(X, Y),
    unfinished(Y).

ready(X) :-
    status(X, todo),
    not blocked(X).

ready(X)?
```

Output:

```text
planner
```

---

# 79. Example: Transitive Dependencies

```prolog
depends(a, b).
depends(b, c).
depends(c, d).

requires(X, Y) :-
    depends(X, Y).

requires(X, Z) :-
    depends(X, Y),
    requires(Y, Z).

requires(a, X)?
```

Output:

```text
b
c
d
```

---

# 80. Example: Stratified Negation

```prolog
bird(tweety).
bird(opus).

penguin(opus).

flies(X) :-
    bird(X),
    not penguin(X).

flies(X)?
```

Output:

```text
tweety
```

---

# 81. Example: Multiple Strata

```prolog
node(a).
node(b).
node(c).

edge(a, b).

connected(X) :-
    edge(X, _).

isolated(X) :-
    node(X),
    not connected(X).

interesting(X) :-
    isolated(X),
    not boring(X).

boring(c).

interesting(X)?
```

Possible output:

```text
b
```

---

# 82. Source Layout

Minimal project:

```text
dawk/
    dawk
    dawk.awk
    README.md
    LICENSE
    tests/
        run.sh
        basic.dl
        recursion.dl
        negation.dl
        invalid-negation.dl
```

Optionally:

```text
examples/
    graph.dl
    project.dl
    policy.dl
```

No build system is required.

---

# 83. Installation

Suggested BSD-style install:

```sh
install -m 755 dawk /usr/local/bin/dawk
install -m 644 dawk.awk /usr/local/libexec/dawk.awk
```

The wrapper should resolve the installed AWK file path deterministically.

---

# 84. Wrapper

Conceptually:

```sh
#!/bin/sh

AWK=${AWK:-awk}
LIBEXEC=${DAWK_LIBEXEC:-/usr/local/libexec/dawk.awk}

exec "$AWK" \
    -v dawk_query="$query" \
    -v dawk_format="$format" \
    -f "$LIBEXEC" \
    "$@"
```

Actual wrapper must use `getopts`.

---

# 85. AWK Program Structure

Suggested top-level organization:

```awk
BEGIN {
    init()
}

{
    source_add_line(FILENAME, FNR, $0)
}

END {
    parse_all()
    check_program()
    stratify()
    evaluate()
    run_queries()
}
```

However, because multiple files must behave as one logical program, the source collector should preserve file boundaries for diagnostics.

---

# 86. Suggested Function Groups

Lexer:

```text
lex_next
lex_peek
lex_error
```

Parser:

```text
parse_program
parse_statement
parse_rule
parse_query
parse_body
parse_atom
parse_term
```

Symbols/predicates:

```text
predicate_get
predicate_name
value_encode
value_decode
```

Facts:

```text
tuple_key
tuple_add
tuple_match
```

Validation:

```text
check_rule
check_safety
check_stratification
```

Evaluation:

```text
eval_stratum
eval_rule
eval_literal
match_tuple
emit_head
```

Semi-naive:

```text
delta_seed
delta_rule_run
delta_rotate
```

Query:

```text
query_run
query_emit
```

Output:

```text
print_value
print_row
csv_quote
```

---

# 87. Implementation Philosophy

The implementation should favor obvious code such as:

```awk
for (i = 1; i <= pred_tuple_count[p]; i++) {
    t = pred_tuple[p, i]
    ...
}
```

over clever compressed AWK tricks.

Do not optimize for code golf.

The project is valuable precisely because a reader should be able to understand Datalog evaluation by reading the source.

---

# 88. Success Criteria

Dawk v1 is complete when:

1. It runs under at least:

   * FreeBSD awk;
   * macOS awk;
   * mawk;
   * gawk.
2. It requires no nonstandard AWK extensions.
3. It parses conventional Datalog syntax.
4. It supports recursion.
5. It evaluates recursion using semi-naive deltas.
6. It supports safe stratified negation.
7. It rejects recursion through negation.
8. It supports variables, symbols, strings, and ordinary numeric comparisons.
9. It supports embedded and command-line queries.
10. Positive and stratified test programs produce identical results under naive and semi-naive evaluators.
11. The implementation remains approximately 700–1,200 lines of readable AWK.
12. A normal Unix user can understand usage from:

```sh
dawk -h
```

and can run a program simply as:

```sh
dawk file.dl
```

---

# 89. Future Directions

Possible future additions, only if they remain small:

```text
single-column tuple indexes
CSV fact loading
CSV relation export
simple arithmetic
count/min/max aggregates
incremental fact insertion in REPL
explain/trace mode
relation statistics
```

Magic Sets should probably **not** be added to Dawk.

The optimized C implementation is the appropriate place for:

```text
Magic Sets
complex indexing
join planning
incremental database maintenance
large-scale execution
embedding API
```

That creates a useful split:

```text
Dawk
    tiny
    portable
    executable specification
    reference semantics

Rivet
    optimized C implementation
    semi-naive
    Magic Sets
    indexes
    library API
```

Dawk therefore serves both as a useful standalone Unix tool and as the canonical reference implementation against which a faster C engine can be tested.

---

# 90. One-Sentence Description

> **Dawk is a tiny stratified Datalog interpreter written in portable AWK.**

And the README opener could simply be:

> Dawk is Datalog in AWK: facts, rules, recursion, queries, and stratified negation in a single portable AWK program with no dependencies.
