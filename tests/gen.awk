# gen.awk -- random safe, stratified Datalog programs for differential testing
# (spec §77, PLAN.md section 12).
#
#	awk -v seed=N -f tests/gen.awk > prog.dl
#
# The program is a function of the seed alone, under any awk: awk's own
# rand() is seeded and sequenced differently by every implementation, so the
# generator carries its own Park-Miller generator, whose products stay below
# 2^46 and are therefore exact in a double.  A failing seed reported under
# mawk reproduces under BWK awk.
#
# What it emits, and why each program is legal by construction:
#
#	- a few base predicates holding only facts, possibly duplicated;
#	- derived predicates, each given a level.  A rule for a predicate of
#	  level L reads positively any base predicate or any derived one of
#	  level <= L -- itself included, which is where recursion, mutual
#	  recursion and rules with two recursive literals come from -- and
#	  negates only base predicates or derived ones of level < L.  Every
#	  cycle therefore stays within one level and is positive, so the
#	  program is stratifiable (spec §37);
#	- sometimes facts for a derived predicate as well, the shape that
#	  seeding deltas with whole relations exists for (spec §43);
#	- a head, negated literals and comparisons drawn only from variables
#	  some positive literal binds, or from constants, so every rule is
#	  safe (spec §32-34);
#	- body literals in shuffled order, so a negation or a comparison is
#	  often written before the literal that binds it (spec §33, §35);
#	- ordering comparisons only in programs whose every constant is a
#	  number, since elsewhere a variable may be bound to a symbol and the
#	  program would stop on a run-time type error, which both engines
#	  would reach alike and so prove nothing.  Mixed programs use = and !=,
#	  which is where foo, "foo" and 42 have to stay distinct (spec §26).
#
# The first line is a comment summarising what the program contains, which
# tests/fuzz.sh tallies so that a run can show it exercised something.

BEGIN {
	if (seed == "")
		seed = 1
	# Any integer seed, negative included, lands on a state in
	# [1, 2^31 - 2]; zero would be a fixed point of the generator.
	rng = ((int(seed) % 2147483646) + 2147483646) % 2147483646 + 1
	# Nearby seeds start nearby; a few steps spread them apart.
	for (i = 0; i < 8; i++)
		rnd(2)

	numeric = rnd(2)
	if (numeric) {
		ndom = 3 + rnd(4)
		for (i = 1; i <= ndom; i++)
			dom[i] = i - 2
	} else {
		# Symbols, numbers and strings that spell alike across types, plus
		# strings that need quoting and escapes in the dump.  Separated by
		# "|" because the values themselves hold spaces.  A program draws
		# four to six of them, since a wide domain makes joins miss and
		# leaves the derived relations empty.
		npool = split("a|b|c|1|2|-3|\"a\"|\"1\"|\"x y\"|\"q\\\"t\\tz\"|\"\"",
			pool, "|")
		ndom = 4 + rnd(3)
		for (i = 1; i <= ndom; i++) {
			j = i + rnd(npool - i + 1)
			dom[i] = pool[j]
			pool[j] = pool[i]
		}
	}

	npred = 0
	nbase = 1 + rnd(3)
	for (i = 1; i <= nbase; i++)
		pred_new("e" i, arity_pick(), -1)
	nderived = 2 + rnd(5)
	for (i = 1; i <= nderived; i++)
		pred_new("p" i, arity_pick(), rnd(3))

	out_n = 0
	for (p = 1; p <= nbase; p++) {
		n = 4 + rnd(12)
		for (i = 1; i <= n; i++)
			emit_fact(p)
	}
	for (p = nbase + 1; p <= npred; p++) {
		if (rnd(5) == 0)
			emit_fact(p)
		n = 1 + rnd(3)
		for (i = 1; i <= n; i++)
			emit_rule(p, i == 1)
	}
	n = 1 + rnd(2)
	for (i = 1; i <= n; i++)
		emit_query()

	printf "%% gen seed=%d numeric=%d facts=%d rules=%d recursive=%d " \
		"negations=%d comparisons=%d\n", seed, numeric, stat_facts,
		stat_rules, stat_recursive, stat_negations, stat_comparisons
	for (i = 1; i <= out_n; i++)
		print out[i]
}

# Uniform in [0, n).
function rnd(n) {
	rng = (rng * 16807) % 2147483647
	return int(rng / 2147483647 * n)
}

# Arity 0 is rare but present: it is the ground-query and "true/false" path.
# Arity 2 is the commonest, being what joins are made of.
function arity_pick(   d) {
	d = rnd(10)
	return d < 1 ? 0 : d < 4 ? 1 : d < 8 ? 2 : 3
}

function pred_new(name, arity, level) {
	npred++
	pname[npred] = name
	parity[npred] = arity
	plevel[npred] = level
}

function const_pick() {
	return dom[1 + rnd(ndom)]
}

function emit(line) {
	out[++out_n] = line
}

function atom(p, args) {
	return parity[p] == 0 ? pname[p] : pname[p] "(" args ")"
}

function emit_fact(p,   k, args) {
	args = ""
	for (k = 1; k <= parity[p]; k++)
		args = args (k > 1 ? ", " : "") const_pick()
	emit(atom(p, args) ".")
	stat_facts++
}

# A body predicate for a rule whose head has level lv: a positive literal may
# read level <= lv, and a negated one -- or any literal of a predicate's first
# rule, which is its base case -- only level < lv.  Without a base case most
# recursive relations would come out empty and compare trivially equal.
function body_pred(lv, below,   p, tries) {
	for (tries = 0; tries < 20; tries++) {
		# Lean towards the rule's own level, so recursion is common.
		if (!below && rnd(3) == 0)
			p = same_level(lv)
		else
			p = 1 + rnd(npred)
		if (p == 0)
			continue
		if (below ? plevel[p] < lv : plevel[p] <= lv)
			return p
	}
	return 1 + rnd(nbase)
}

function same_level(lv,   p, c, cand) {
	c = 0
	for (p = nbase + 1; p <= npred; p++)
		if (plevel[p] == lv)
			cand[++c] = p
	return c ? cand[1 + rnd(c)] : 0
}

# A bound variable if there is one and the dice agree, else a constant.
function bound_term() {
	if (nbound > 0 && rnd(5) != 0)
		return bound[1 + rnd(nbound)]
	return const_pick()
}

function emit_rule(h, base_case,   lv, npos, nneg, ncmp, i, k, p, args, t,
    nlit, lit, j, tmp, head, rec, ops, nops) {
	lv = plevel[h]
	nvar = 0
	nbound = 0
	array_clear(isbound)
	nlit = 0
	rec = 0

	npos = 1 + rnd(3)
	for (i = 1; i <= npos; i++) {
		p = body_pred(lv, base_case)
		if (plevel[p] == lv)
			rec = 1
		args = ""
		for (k = 1; k <= parity[p]; k++) {
			j = rnd(20)
			if (j < 8 && nvar > 0)
				t = "V" (1 + rnd(nvar))
			else if (j < 17)
				t = "V" (++nvar)
			else if (j < 19)
				t = "_"
			else
				t = const_pick()
			if (t ~ /^V/ && !(t in isbound)) {
				isbound[t] = 1
				bound[++nbound] = t
			}
			args = args (k > 1 ? ", " : "") t
		}
		lit[++nlit] = atom(p, args)
	}

	nneg = rnd(3) == 0 ? 1 + rnd(2) : 0
	for (i = 1; i <= nneg; i++) {
		p = body_pred(lv, 1)
		args = ""
		for (k = 1; k <= parity[p]; k++)
			args = args (k > 1 ? ", " : "") bound_term()
		lit[++nlit] = "not " atom(p, args)
		stat_negations++
	}

	nops = numeric ? split("= != < <= > >=", ops, " ") : split("= !=", ops, " ")
	ncmp = (nbound > 0 && rnd(3) == 0) ? 1 + rnd(2) : 0
	for (i = 1; i <= ncmp; i++) {
		lit[++nlit] = bound[1 + rnd(nbound)] " " ops[1 + rnd(nops)] " " \
			bound_term()
		stat_comparisons++
	}

	# Fisher-Yates over the body.
	for (i = nlit; i > 1; i--) {
		j = 1 + rnd(i)
		tmp = lit[i]
		lit[i] = lit[j]
		lit[j] = tmp
	}

	args = ""
	for (k = 1; k <= parity[h]; k++)
		args = args (k > 1 ? ", " : "") bound_term()
	head = atom(h, args) " :- " lit[1]
	for (i = 2; i <= nlit; i++)
		head = head ", " lit[i]
	emit(head ".")
	stat_rules++
	stat_recursive += rec
}

# Queries do not reach the dump, but they still run, and a query that could
# not be evaluated would change the exit status the driver compares.
function emit_query(   p, k, args) {
	p = nbase + 1 + rnd(nderived)
	args = ""
	for (k = 1; k <= parity[p]; k++)
		args = args (k > 1 ? ", " : "") (rnd(3) == 0 ? const_pick() : "Q" k)
	emit(atom(p, args) "?")
}

function array_clear(a,   k) {
	for (k in a)
		delete a[k]
}
