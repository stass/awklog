# awklog -- a tiny stratified Datalog interpreter in portable AWK.
#
# The main rule only collects source lines; everything else runs in END, as a
# pipeline: parse, load facts, check safety, stratify, evaluate, run queries.
# README.md describes the language and the design.
#
# POSIX awk only.  No gensub, asort/asorti, PROCINFO, arrays of arrays,
# switch, typeof, indirect calls, length(array), delete of a whole array, or
# regex shorthands such as \s.  Two-dimensional access is always a[x, y] with
# an explicit SUBSEP.
#
# Settings arrive in the environment as AWKLOG_* (set by the awklog wrapper);
# an explicit -v awklog_* assignment wins, so direct
#
#	awk -v awklog_query='edge(X, Y)?' -f awklog.awk graph.dl
#
# stays ergonomic.

BEGIN {
	init()
}

FNR == 1 {
	stat_files++
}

{
	source_add_line(FILENAME, FNR, $0)
}

END {
	if (dying)
		exit exit_code
	parse_all()
	load_facts()
	check_program()
	stratify()
	if (!opt_check) {
		evaluate()
		run_queries()
		if (opt_dump)
			dump_relations()
	}
	if (opt_verbose)
		print_stats()
	exit exit_code
}

# ---------------------------------------------------------------- options ---

function init() {
	# Belt and braces only: POSIX converts an integral value with %d and
	# consults CONVFMT just for the rest, and the language has no
	# non-integral values to reach it.  Numbers that go into tuple keys are
	# spelled explicitly by number_text() in any case.
	CONVFMT = "%.17g"
	OFMT = "%.17g"
	SUBSEP = sprintf("%c", 28)

	# The lexer classifies bytes with index() into these sets rather than
	# scanning tokens with match(), which takes no start offset and so would
	# copy the rest of the line for every token -- quadratic on a long line.
	UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	LOWER = "abcdefghijklmnopqrstuvwxyz"
	DIGITS = "0123456789"
	WORDCH = UPPER LOWER DIGITS "_"

	STDERR = opt_str(awklog_stderr, "AWKLOG_STDERR", "/dev/stderr")

	opt_query = opt_str(awklog_query, "AWKLOG_QUERY", "")
	opt_format = opt_str(awklog_format, "AWKLOG_FORMAT", "text")
	opt_mode = opt_str(awklog_mode, "AWKLOG_MODE", "semi")
	opt_check = opt_flag(awklog_check, "check")
	opt_quiet = opt_flag(awklog_quiet, "quiet")
	opt_sort = opt_flag(awklog_sort, "sort")
	opt_werror = opt_flag(awklog_werror, "werror")
	opt_verbose = opt_num(awklog_verbose, "AWKLOG_VERBOSE", 0)
	# Undocumented, and deliberately absent from the wrapper: the test
	# harness sets it to have every relation printed after evaluation, so
	# that the two engines are compared over the whole model and not only
	# over what the queries happen to ask.
	# It also suppresses the queries' own rows -- see query_print() -- so
	# that what reaches stdout is the model and nothing else.
	opt_dump = opt_flag(awklog_dump, "dump")

	if (opt_format != "text" && opt_format != "csv" && opt_format != "tsv")
		usage_error("unknown output format: " opt_format)
	if (opt_mode != "semi" && opt_mode != "naive")
		usage_error("unknown evaluation mode: " opt_mode)

	# The column separator of each format; how a column itself is spelled
	# is format_field()'s business.
	if (opt_format == "csv")
		FIELDSEP = ","
	else if (opt_format == "tsv")
		FIELDSEP = "\t"
	else
		FIELDSEP = " "

	# -s sorts each query's rows on their way out through sort(1), the only
	# sort available without asort().  The dump uses the same command, and
	# both close it before the other can run.
	SORTCMD = "sort"

	src_n = 0
	stat_lines = 0
	pred_n = 0
	tuple_n = 0
	rule_n = 0
	query_n = 0
	stat_files = 0
	stat_input_facts = 0
	stat_dup_facts = 0
	stat_rules = 0
	stat_undefined = 0
	stat_unused = 0
	stat_derived_facts = 0
	stat_rule_runs = 0
	stat_tuple_scans = 0
	stat_iterations = 0
	max_stratum = 0
	join_stop = 0
	sort_open = 0
	sort_warned = 0
	delta_active = 0
	delta_lit = 0
	delta_pending = 0
	exit_code = 0
	dying = 0
}

# An unset awk variable is "", so a -v assignment takes precedence over the
# environment only when it actually carries a value.
function opt_str(v, name, dflt) {
	if (v != "")
		return v
	if (name in ENVIRON && ENVIRON[name] != "")
		return ENVIRON[name]
	return dflt
}

function opt_num(v, name, dflt) {
	return opt_str(v, name, dflt) + 0
}

# An on/off switch, awklog_NAME or AWKLOG_NAME, is 0 or 1 and nothing else.
# Read as a number, any other value would be 0, and a mistyped "yes" would
# quietly turn a switch off -- -W above all, whose job is to make a run fail.
# The result is a number, so "if (opt_x)" means what it says: the string "0"
# would test true.
function opt_flag(v, name,   s) {
	s = opt_str(v, "AWKLOG_" toupper(name), "0")
	if (s != "0" && s != "1")
		usage_error("awklog_" name " / AWKLOG_" toupper(name) \
			" must be 0 or 1, not '" s "'")
	return s == "1"
}

# ------------------------------------------------------------ diagnostics ---

# Messages carry their own classification ("syntax error: ...", "error:
# unsafe rule: ...") so that a located diagnostic reads
#
#	project.dl:14:3: syntax error: expected ')', found 'c'
#
# All stages run in END, so exit here terminates immediately; the dying flag
# covers the one caller in BEGIN, where exit would otherwise fall into END.
function die(where, msg) {
	if (where != "")
		print where ": " msg > STDERR
	else
		print "awklog: " msg > STDERR
	close(STDERR)
	exit_code = 1
	dying = 1
	exit 1
}

function usage_error(msg) {
	print "awklog: " msg > STDERR
	close(STDERR)
	exit_code = 2
	dying = 1
	exit 2
}

# Every warning comes through here, so -W is one test: the warning becomes
# an error, and like any error it ends the run at once.  The message keeps
# its text and changes only its classification.
function warn(where, msg) {
	if (opt_werror)
		die(where, "error: " msg)
	if (where != "")
		print where ": warning: " msg > STDERR
	else
		print "awklog: warning: " msg > STDERR
}

function note(msg) {
	print "awklog: " msg > STDERR
}

# How a token is named in a diagnostic.
# Punctuation carries no text and is named by its kind, which is its spelling.
function token_desc(kind, text) {
	if (kind == "EOF")
		return "end of input"
	if (kind == "STR")
		return "a string literal"
	return "'" (text != "" ? text : kind) "'"
}

# Whole-array delete is not POSIX, so every array is emptied through here.
function array_clear(a, k) {
	for (k in a)
		delete a[k]
}

# --------------------------------------------------------------- sources ---

# Input lines are kept with their origin so that the lexer's (line, column)
# cursor yields file:line:col diagnostics with no offset mapping table.
function source_add_line(file, fnr, text) {
	# Standard input reaches awk under three spellings: BWK awk leaves
	# FILENAME empty, mawk and gawk set it to "-", and an explicit
	# /dev/stdin operand names the same stream a third way.  All three get
	# one label, so a diagnostic reads the same whichever awk is running.
	if (file == "" || file == "-" || file == "/dev/stdin")
		file = "<stdin>"
	src_n++
	src_file[src_n] = file
	src_fnr[src_n] = fnr
	src_text[src_n] = text
}

function source_where(i, col) {
	if (i < 1 || i > src_n)
		return "awklog"
	if (col > 0)
		return src_file[i] ":" src_fnr[i] ":" col
	return src_file[i] ":" src_fnr[i]
}

# Query text from -q becomes ordinary source lines, so it lexes with the same
# cursor and reports the same file:line:col diagnostics.  Several -q queries
# arrive joined by newlines and so become several lines of "<query>".
function source_add_query(text,   parts, i, n, start) {
	start = src_n + 1
	n = split(text, parts, "\n")
	for (i = 1; i <= n; i++)
		source_add_line("<query>", i, parts[i])
	return start
}

# ----------------------------------------------------------------- lexer ---
#
# The cursor is (lex_i, lex_col): an index into src_text[] and a 1-based
# column.  Keeping the lines separate instead of concatenating them into one
# buffer gives every token a file:line:col for free; statements still span
# lines because the scanner walks through line ends transparently.
#
# Token kinds are IDENT, VAR, ANON, INT, STR, not, EOF and the punctuation
# spelled as itself ("(", ")", ",", ".", "?", ":-", "=", "!=", "<", "<=", ">",
# ">="), so a diagnostic can name a token without a translation table.

function lex_start(i) {
	lex_i = i
	lex_col = 1
	lex_end_ln = 0
	lex_end_col = 0
	have_peek = 0
	tok_kind = ""
	tok_text = ""
	tok_ln = i
	tok_col = 1
}

# The scanner always fills the lookahead slot pk_*, and lex_next() moves that
# slot into tok_*; one token of pushback is enough for the whole grammar, and
# keeping the two slots apart saves saving and restoring the current token
# around every peek.
function lex_next() {
	if (!have_peek)
		lex_scan()
	have_peek = 0
	tok_kind = pk_kind
	tok_text = pk_text
	tok_ln = pk_ln
	tok_col = pk_col
	return tok_kind
}

function lex_peek() {
	if (!have_peek) {
		lex_scan()
		have_peek = 1
	}
	return pk_kind
}

# Whitespace and %-comments are skipped between tokens, so a % inside a string
# literal is safe by construction.
function lex_skip_space(   c) {
	while (lex_i <= src_n) {
		# substr() past the end of a line returns "", which is how the
		# scanner detects end of line.
		c = substr(src_text[lex_i], lex_col, 1)
		if (c == "" || c == "%") {
			# Remember where the source ran out, so that the EOF token
			# still carries a location for "unexpected end of input".
			# A comment runs to the end of the line, so step over it
			# first: pointing the caret inside it would be misleading.
			if (c == "%")
				lex_col = length(src_text[lex_i]) + 1
			lex_end_ln = lex_i
			lex_end_col = lex_col
			lex_i++
			lex_col = 1
		} else if (c == " " || c == "\t" || c == "\r") {
			lex_col++
		} else {
			return
		}
	}
}

function lex_scan(   line, c, n, span, two) {
	lex_skip_space()
	pk_ln = lex_i
	pk_col = lex_col
	pk_text = ""
	if (lex_i > src_n) {
		pk_ln = lex_end_ln
		pk_col = lex_end_col
		return pk_kind = "EOF"
	}
	line = src_text[lex_i]
	c = substr(line, lex_col, 1)

	if (c == "\"")
		return lex_string(line)

	if (index(WORDCH, c) > 0 && index(DIGITS, c) == 0) {
		span = lex_span(line, lex_col, WORDCH)
		pk_text = substr(line, lex_col, span)
		lex_col += span
		return pk_kind = lex_word_kind(pk_text)
	}

	# "-" is a sign on a numeric literal, never an operator: there is no
	# arithmetic.
	if (c == "-" || index(DIGITS, c) > 0) {
		n = (c == "-") ? 1 : 0
		span = lex_span(line, lex_col + n, DIGITS)
		if (span == 0)
			lex_error(lex_i, lex_col, "expected a digit after '-'")
		pk_text = substr(line, lex_col, n + span)
		lex_col += n + span
		return pk_kind = "INT"
	}

	# Two-byte operators first, so that "<=" is not read as "<" then "=".
	two = substr(line, lex_col, 2)
	if (two == ":-" || two == "!=" || two == "<=" || two == ">=") {
		lex_col += 2
		return pk_kind = two
	}
	if (index("(),.?=<>", c) > 0) {
		lex_col++
		return pk_kind = c
	}
	if (c == ":" || c == "!")
		lex_error(lex_i, lex_col, "expected '" c (c == ":" ? "-" : "=") "'")
	lex_error(lex_i, lex_col, "unexpected character '" c "'")
}

# Number of consecutive bytes of set starting at col.
function lex_span(line, col, set,   n, c) {
	n = 0
	for (;;) {
		c = substr(line, col + n, 1)
		if (c == "" || index(set, c) == 0)
			break
		n++
	}
	return n
}

function lex_word_kind(w,   c) {
	if (w == "not")
		return "not"
	if (w == "_")
		return "ANON"
	c = substr(w, 1, 1)
	if (index(UPPER, c) > 0)
		return "VAR"
	if (index(LOWER, c) > 0)
		return "IDENT"
	lex_error(pk_ln, pk_col, "'" w "' is not a valid name: predicates and " \
		"symbols begin with a lowercase letter, variables with an uppercase one")
}

# String literals do not span lines; the escapes are \\ \" \n \t \r and no
# others.
function lex_string(line,   col, start, c, esc, out) {
	start = lex_col
	col = lex_col + 1
	out = ""
	for (;;) {
		c = substr(line, col, 1)
		if (c == "")
			lex_error(lex_i, start, "unterminated string literal")
		if (c == "\"") {
			col++
			break
		}
		if (c == "\\") {
			col++
			c = substr(line, col, 1)
			if (c == "")
				lex_error(lex_i, start, "unterminated string literal")
			# The two tables are parallel: \\ \" n t r -> \ " NL TAB CR.
			esc = index("\\\"ntr", c)
			if (esc == 0)
				# col is on the escaped character; point at the backslash.
				lex_error(lex_i, col - 1, "unknown escape '\\" c "' in string literal")
			out = out substr("\\\"\n\t\r", esc, 1)
			col++
			continue
		}
		out = out c
		col++
	}
	lex_col = col
	pk_text = out
	return pk_kind = "STR"
}

function lex_error(ln, col, msg) {
	die(source_where(ln, col), "syntax error: " msg)
}

# -------------------------------------------------------- symbols, values ---

function predicate_get(name, arity,   key) {
	key = name SUBSEP arity
	if (key in pred_id)
		return pred_id[key]
	pred_n++
	pred_id[key] = pred_n
	pred_name[pred_n] = name
	pred_arity[pred_n] = arity
	# Seeded because every relation scan reads it and reading an absent
	# element would create it anyway.  pred_has_fact and pred_has_rule are
	# deliberately left absent instead: seeding them would make
	# (p in pred_has_rule) true for every predicate, and that test is how
	# the checker and the delta loop ask whether a predicate is defined.
	pred_tuple_count[pred_n] = 0
	return pred_n
}

function predicate_label(p) {
	return pred_name[p] "/" pred_arity[p]
}

# Constants carry a type tag -- s: symbol, q: string, n: number -- so that
# foo, "foo" and 42 are three distinct values under equality and inside tuple
# keys.  The engine only ever compares and stores encoded values; decoding
# happens on output.
function value_encode(kind, text) {
	if (kind == "n")
		return "n:" number_text(text + 0)
	return kind ":" value_escape(text)
}

# Tuple keys join encoded values with SUBSEP, so a SUBSEP (or the escape
# character itself) inside a string constant could otherwise forge another
# tuple's key; escaping here makes key construction injective.
function value_escape(s,   out, c, i) {
	if (index(s, "\\") == 0 && index(s, SUBSEP) == 0)
		return s
	out = ""
	for (i = 1; ; i++) {
		c = substr(s, i, 1)
		if (c == "")
			break
		if (c == "\\")
			out = out "\\\\"
		else if (c == SUBSEP)
			out = out "\\S"
		else
			out = out c
	}
	return out
}

# The encoded spelling of a number is built explicitly rather than left to the
# host's number->string rule: below 2^53 %d is exact, and above it a host's %d
# may convert through an integer type too narrow to hold the value, so those go
# through %.17g, which round-trips a double.
function number_text(v) {
	if (v == int(v) && v < 9007199254740992 && v > -9007199254740992)
		return sprintf("%d", v)
	return sprintf("%.17g", v)
}

# ----------------------------------------------------------- tuple store ---
#
# A tuple is one ground row of a relation, with an integer id.  Rows are
# interned under
#
#	predicate-id SUBSEP encoded-arg-1 SUBSEP ... SUBSEP encoded-arg-n
#
# so re-deriving a row is one hash lookup and set semantics fall out of the
# array.  That key is injective only because value_encode() escapes
# SUBSEP and the backslash inside constants: otherwise the two rows
#
#	p("x" SUBSEP "q:y", "z")	p("x", "y" SUBSEP "q:z")
#
# would spell the same key and the second would vanish as a duplicate.
#
# Arguments arrive in an array rather than one packed string because a caller
# usually has them in separate places already (head terms here, bindings in the
# evaluator), and packing them twice would cost a scan per candidate row.

function tuple_key(p, n, argv,   key, k) {
	key = p
	for (k = 1; k <= n; k++)
		key = key SUBSEP argv[k]
	return key
}

# Interns argv[1..n] as a row of predicate p and returns its tuple id.  Whether
# the row was new is reported through the global tuple_added, since an awk
# function returns one scalar.
function tuple_add(p, n, argv,   key, t, k) {
	key = tuple_key(p, n, argv)
	if (key in tuple_exists) {
		tuple_added = 0
		return tuple_exists[key]
	}
	tuple_n++
	t = tuple_n
	tuple_exists[key] = t
	tuple_pred[t] = p
	for (k = 1; k <= n; k++)
		tuple_arg[t, k] = argv[k]
	pred_tuple_count[p]++
	pred_tuple[p, pred_tuple_count[p]] = t
	tuple_added = 1
	return t
}

# ---------------------------------------------------------------- parser ---
#
# Recursive descent with one token of lookahead.  Facts, rules and queries
# all become rules: a fact is a rule with an empty body, and a query is a rule
# whose synthetic head carries its named variables in order of first
# appearance.  Parsed objects are integer ids into flat arrays -- rule_*[r],
# rule_lit_*[r, i], term_*[r, i, k] -- rather than ASTs encoded as strings.
#
# The head of a fact or rule is parsed as body literal 1 and moved by
# rule_promote_head(), because no amount of lookahead at the first literal
# tells "head :- body" from "literal, literal?".

function parse_all(   start) {
	# Query text is appended to the same array below, so the input-file
	# line count has to be taken before that.
	stat_lines = src_n
	lex_start(1)
	parse_program(0)
	if (opt_query != "") {
		start = source_add_query(opt_query)
		lex_start(start)
		parse_program(1)
	}
}

function parse_program(query_only) {
	while (lex_peek() != "EOF")
		parse_statement(query_only)
}

function parse_statement(query_only,   r, k, n) {
	lex_peek()
	r = rule_new(pk_ln, pk_col)
	parse_literal(r, 1)
	k = lex_peek()
	if (k == ":-") {
		lex_next()
		if (rule_lit_kind[r, 1] != 1)
			die(source_where(rule_line[r], rule_col[r]),
				"syntax error: a rule head must be a positive atom")
		rule_promote_head(r)
		n = 0
		for (;;) {
			n++
			parse_literal(r, n)
			if (lex_peek() != ",")
				break
			lex_next()
		}
		rule_body_n[r] = n
		expect(".", "'.'")
	} else if (k == ".") {
		lex_next()
		if (rule_lit_kind[r, 1] != 1)
			die(source_where(rule_line[r], rule_col[r]),
				"syntax error: a fact must be a positive atom")
		rule_promote_head(r)
		rule_body_n[r] = 0
		rule_is_fact[r] = 1
	} else if (k == "," || k == "?") {
		n = 1
		while (lex_peek() == ",") {
			lex_next()
			n++
			parse_literal(r, n)
		}
		rule_body_n[r] = n
		expect("?", "'?'")
		rule_is_query[r] = 1
		rule_query_head(r)
		query_n++
		query_rule[query_n] = r
	} else {
		die(source_where(pk_ln, pk_col), "syntax error: expected ':-', '.' " \
			"or '?', found " token_desc(pk_kind, pk_text))
	}
	if (query_only && !rule_is_query[r])
		die(source_where(rule_line[r], rule_col[r]),
			"error: only queries may be given with -q")
	# What the statement defines is recorded once it is known to be one
	# this caller accepts: -q rejects a fact or a rule only after parsing
	# the whole thing, and marking its predicate as defined on the way
	# through would silence an undefined warning that belongs elsewhere.
	if (rule_is_query[r])
		return
	if (rule_is_fact[r])
		pred_has_fact[rule_head_pred[r]] = 1
	else {
		pred_has_rule[rule_head_pred[r]] = 1
		stat_rules++
	}
}

function rule_new(ln, col,   r) {
	rule_n++
	r = rule_n
	rule_line[r] = ln
	rule_col[r] = col
	rule_head_pred[r] = 0
	rule_head_arity[r] = 0
	rule_body_n[r] = 0
	rule_var_n[r] = 0
	rule_is_fact[r] = 0
	rule_is_query[r] = 0
	return r
}

function rule_promote_head(r,   k, n) {
	rule_head_pred[r] = rule_lit_pred[r, 1]
	n = rule_lit_arity[r, 1]
	rule_head_arity[r] = n
	for (k = 1; k <= n; k++) {
		rule_head_kind[r, k] = term_kind[r, 1, k]
		rule_head_val[r, k] = term_val[r, 1, k]
	}
}

# A query's columns are its named variables in order of first appearance;
# anonymous variables are never projected.  The head
# predicate stays 0: a query emits rows, it does not populate a relation.
function rule_query_head(r,   s, n) {
	n = 0
	for (s = 1; s <= rule_var_n[r]; s++) {
		if (rule_var_name[r, s] == "")
			continue
		n++
		rule_head_kind[r, n] = 1
		rule_head_val[r, n] = s
	}
	rule_head_arity[r] = n
}

# literal := atom | "not" atom | comparison
#
# An IDENT in literal position starts an atom unless a comparison operator
# follows it, in which case it is a bare symbol operand ("foo = X").
function parse_literal(r, i,   k, name, ln, col) {
	k = lex_peek()
	if (k == "not") {
		lex_next()
		expect("IDENT", "a predicate name")
		rule_lit_kind[r, i] = 2
		parse_atom(r, i, tok_text, tok_ln, tok_col)
		return
	}
	if (k == "IDENT") {
		lex_next()
		name = tok_text
		ln = tok_ln
		col = tok_col
		if (!comparator_p(lex_peek())) {
			rule_lit_kind[r, i] = 1
			parse_atom(r, i, name, ln, col)
			return
		}
		pt_kind = 2
		pt_val = value_encode("s", name)
		parse_comparison(r, i, ln, col)
		return
	}
	if (k == "VAR" || k == "ANON" || k == "INT" || k == "STR") {
		ln = pk_ln
		col = pk_col
		parse_term(r)
		parse_comparison(r, i, ln, col)
		return
	}
	die(source_where(pk_ln, pk_col),
		"syntax error: expected a literal, found " token_desc(pk_kind, pk_text))
}

# atom := IDENT [ "(" [term ("," term)*] ")" ]   -- the name is already read.
function parse_atom(r, i, name, ln, col,   argc) {
	argc = 0
	if (lex_peek() == "(") {
		lex_next()
		if (lex_peek() == ")") {
			lex_next()
		} else {
			for (;;) {
				argc++
				parse_term(r)
				term_kind[r, i, argc] = pt_kind
				term_val[r, i, argc] = pt_val
				if (lex_peek() != ",")
					break
				lex_next()
			}
			expect(")", "')'")
		}
	}
	rule_lit_pred[r, i] = predicate_get(name, argc)
	rule_lit_arity[r, i] = argc
	rule_lit_line[r, i] = ln
	rule_lit_col[r, i] = col
}

# comparison := term comparator term   -- the left operand is in pt_kind/pt_val.
function parse_comparison(r, i, ln, col,   op) {
	term_kind[r, i, 1] = pt_kind
	term_val[r, i, 1] = pt_val
	op = lex_next()
	if (!comparator_p(op))
		die(source_where(tok_ln, tok_col), "syntax error: expected a " \
			"comparison operator, found " token_desc(tok_kind, tok_text))
	parse_term(r)
	term_kind[r, i, 2] = pt_kind
	term_val[r, i, 2] = pt_val
	rule_lit_kind[r, i] = 3
	rule_lit_pred[r, i] = 0
	rule_lit_op[r, i] = op
	rule_lit_arity[r, i] = 2
	rule_lit_line[r, i] = ln
	rule_lit_col[r, i] = col
	# Where the right operand starts, so that a type error on it points at
	# the operand and not at the head of the whole comparison.  parse_term()
	# consumed exactly one token, so tok_* still names it.
	rule_lit_rhs_ln[r, i] = tok_ln
	rule_lit_rhs_col[r, i] = tok_col
}

# Terms return through pt_kind/pt_val: 1 variable slot, 2 symbol, 3 string,
# 4 number, with constants already encoded.
function parse_term(r,   k) {
	k = lex_next()
	if (k == "VAR") {
		pt_kind = 1
		pt_val = var_slot(r, tok_text)
	} else if (k == "ANON") {
		pt_kind = 1
		pt_val = var_slot(r, "")
	} else if (k == "IDENT") {
		pt_kind = 2
		pt_val = value_encode("s", tok_text)
	} else if (k == "STR") {
		pt_kind = 3
		pt_val = value_encode("q", tok_text)
	} else if (k == "INT") {
		pt_kind = 4
		pt_val = value_encode("n", tok_text)
	} else {
		die(source_where(tok_ln, tok_col),
			"syntax error: expected a term, found " token_desc(tok_kind, tok_text))
	}
}

# Each variable becomes a small integer slot, numbered in order of first
# appearance, so evaluation never looks a name up.  Every occurrence of _ gets
# a fresh nameless slot, so pair(_, _) does not force the two arguments to be
# equal.
function var_slot(r, name,   s) {
	if (name != "" && (r, name) in rule_var_slot)
		return rule_var_slot[r, name]
	rule_var_n[r]++
	s = rule_var_n[r]
	rule_var_name[r, s] = name
	if (name != "")
		rule_var_slot[r, name] = s
	return s
}

function comparator_p(k) {
	return k == "=" || k == "!=" || k == "<" || k == "<=" || k == ">" || k == ">="
}

function expect(kind, what) {
	if (lex_next() != kind)
		die(source_where(tok_ln, tok_col), "syntax error: expected " what \
			", found " token_desc(tok_kind, tok_text))
}

# ---------------------------------------------------------- fact loading ---

# A fact is a rule with an empty body and must be ground, so it is
# stored directly instead of being evaluated.  Loading runs before the semantic
# checks so that -c reports the relation sizes it would really evaluate over,
# and so that a missing-variable diagnostic names the fact that carries it.
function load_facts(   r, p, n, k, name, argv) {
	for (r = 1; r <= rule_n; r++) {
		if (!rule_is_fact[r])
			continue
		p = rule_head_pred[r]
		n = rule_head_arity[r]
		for (k = 1; k <= n; k++) {
			if (rule_head_kind[r, k] == 1) {
				name = rule_var_name[r, rule_head_val[r, k]]
				if (name == "")
					name = "_"
				die(source_where(rule_line[r], rule_col[r]),
					"error: a fact must be ground: " \
					predicate_label(p) " contains variable '" name "'")
			}
			argv[k] = rule_head_val[r, k]
		}
		# Stale argv entries past n are never read: the key stops at n.
		tuple_add(p, n, argv)
		if (tuple_added)
			stat_input_facts++
		else
			stat_dup_facts++
	}
}

# ---------------------------------------------------------------- checks ---
#
# Safety is decided statically and independently of the order the body is
# written in, because the evaluator reorders literals: the set of slots a
# positive body literal can bind is collected over the whole body first, and
# the head, every negation and every comparison are then measured against it.

function check_program(   r) {
	for (r = 1; r <= rule_n; r++)
		if (!rule_is_fact[r])
			check_rule_safety(r)
	check_undefined()
	check_unused()
}

function check_rule_safety(r,   bound, i, k, kind) {
	# Every slot bound by a positive body literal.
	for (i = 1; i <= rule_body_n[r]; i++) {
		if (rule_lit_kind[r, i] != 1)
			continue
		for (k = 1; k <= rule_lit_arity[r, i]; k++)
			if (term_kind[r, i, k] == 1)
				bound[term_val[r, i, k]] = 1
	}
	for (i = 1; i <= rule_body_n[r]; i++) {
		kind = rule_lit_kind[r, i]
		# Negation is membership on a ground tuple, so every argument
		# must already be bound; = is a filter and not a binder, so it
		# needs no special case.
		if (kind == 2)
			check_bound_terms(r, i, bound,
				"'not " predicate_label(rule_lit_pred[r, i]) "'")
		else if (kind == 3) {
			check_bound_terms(r, i, bound,
				"comparison '" rule_lit_op[r, i] "'")
			check_compare_types(r, i)
		}
	}
	check_head_safety(r, bound)
}

function check_bound_terms(r, i, bound, what,   k, s) {
	for (k = 1; k <= rule_lit_arity[r, i]; k++) {
		if (term_kind[r, i, k] != 1)
			continue
		s = term_val[r, i, k]
		if (s in bound)
			continue
		die(source_where(rule_lit_line[r, i], rule_lit_col[r, i]),
			"error: unsafe " rule_noun(r) ": variable '" var_display(r, s) \
			"' in " what " is not bound by a positive body literal")
	}
}

# Range restriction: every head variable is bound by the body.  A query's
# synthetic head carries its named variables, so queries get the same check.
function check_head_safety(r, bound,   k, s, where) {
	where = source_where(rule_line[r], rule_col[r])
	for (k = 1; k <= rule_head_arity[r]; k++) {
		if (rule_head_kind[r, k] != 1)
			continue
		s = rule_head_val[r, k]
		if (s in bound)
			continue
		if (rule_is_query[r])
			die(where, "error: unsafe query: variable '" var_display(r, s) \
				"' is not bound by a positive body literal")
		die(where, "error: unsafe rule: variable '" var_display(r, s) \
			"' in the head of " predicate_label(rule_head_pred[r]) \
			" is not bound by a positive body literal")
	}
}

# An ordering comparison is legal only where both operands resolve to
# numbers.  A symbol or string constant never will, so it is rejected here
# rather than at run time, where the same operand would abort a query midway.
function check_compare_types(r, i,   op, k, kind) {
	op = rule_lit_op[r, i]
	if (op == "=" || op == "!=")
		return
	for (k = 1; k <= 2; k++) {
		kind = term_kind[r, i, k]
		if (kind != 2 && kind != 3)
			continue
		die(operand_where(r, i, k),
			"error: ordering comparison '" op "' requires " \
			"numeric operands, found " \
			(kind == 2 ? "a symbol" : "a string literal"))
	}
}

# A predicate with neither facts nor rules is an empty relation rather than an
# error, so that a program whose fact file is absent still runs; the warning
# goes to stderr, leaving stdout clean for pipelines.
# The memo is per predicate, so a name stays reported once however many
# literals mention it.
function check_undefined(   r, i, p) {
	for (r = 1; r <= rule_n; r++)
		for (i = 1; i <= rule_body_n[r]; i++) {
			if (rule_lit_kind[r, i] == 3)
				continue
			p = rule_lit_pred[r, i]
			if ((p in pred_has_fact) || (p in pred_has_rule))
				continue
			if (p in pred_undefined)
				continue
			pred_undefined[p] = 1
			stat_undefined++
			warn(source_where(rule_lit_line[r, i], rule_lit_col[r, i]),
				"undefined predicate " predicate_label(p) \
				": no facts and no rules, treated as empty")
		}
}

# The mirror image of check_undefined(): a rule whose head nothing reads
# computes nothing observable, and the usual cause is a misspelt head --
# eror(M) :- p(M). quietly defines eror/1, and the check the rule was meant
# to be is gone.  "Read" means named in some body, negated or not, or in some
# query, -q included, since every query is parsed by now.  That makes a
# predicate read only by its own rules, directly or through mutual
# recursion, count as used.  Reachability from the queries would catch that
# too, but it would also flag every predicate that only feeds an unused one,
# and the misspelt head is the case that matters.
#
# Facts are exempt: a fact file commonly carries relations a given program
# has no use for, just as a missing one is tolerated above.  A predicate is
# reported once, at the head of its first rule, so the warnings come out in
# the source order of those rules.
function check_unused(   r, i, p, read, reported) {
	for (r = 1; r <= rule_n; r++)
		for (i = 1; i <= rule_body_n[r]; i++)
			if (rule_lit_kind[r, i] != 3)
				read[rule_lit_pred[r, i]] = 1
	for (r = 1; r <= rule_n; r++) {
		if (rule_is_fact[r] || rule_is_query[r])
			continue
		p = rule_head_pred[r]
		if ((p in read) || (p in reported))
			continue
		reported[p] = 1
		stat_unused++
		warn(source_where(rule_line[r], rule_col[r]),
			"predicate " predicate_label(p) " is derived but never used")
	}
}

# Where operand k of comparison i starts.  The literal's own location is its
# left operand; the right one was recorded separately at parse time, so that
# a type error's caret lands on the offender.
function operand_where(r, i, k) {
	if (k == 1)
		return source_where(rule_lit_line[r, i], rule_lit_col[r, i])
	return source_where(rule_lit_rhs_ln[r, i], rule_lit_rhs_col[r, i])
}

function rule_noun(r) {
	return rule_is_query[r] ? "query" : "rule"
}

function var_display(r, s) {
	return rule_var_name[r, s] == "" ? "_" : rule_var_name[r, s]
}

# ------------------------------------------------- dependencies and strata ---

# One edge per head/body-literal pair, positive or negative.  Facts have no
# body and a query has no head, so neither contributes.  path[] starts as the
# union of the two edge sets; stratify() closes it.
function build_deps(   r, i, p, q, kind) {
	for (r = 1; r <= rule_n; r++) {
		if (rule_is_fact[r] || rule_is_query[r])
			continue
		p = rule_head_pred[r]
		for (i = 1; i <= rule_body_n[r]; i++) {
			kind = rule_lit_kind[r, i]
			if (kind == 3)
				continue
			q = rule_lit_pred[r, i]
			path[p, q] = 1
			if (kind == 1)
				dep_pos[p, q] = 1
			else
				dep_neg[p, q] = 1
		}
	}
}

# Recursion through negation is looked for directly, before any stratum is
# assigned: a negative edge p -> q with q leading back to p is such a cycle by
# definition, and the lowest-numbered such p is a deterministic predicate to
# name that is really on it.  (Relaxing until some stratum exceeds the number
# of predicates would also detect the cycle, but would name whichever
# predicate crossed first, which is as often one standing above the cycle as
# one on it.)
#
# With that ruled out, a simple relaxation converges: raise stratum[p] until
# every positive edge satisfies stratum[p] >= stratum[q] and every negative
# one stratum[p] > stratum[q].  That yields the minimal strata, in O(P^3)
# worst case, which is fine for the number of predicates a program has and
# needs no SCC machinery.
function stratify(   p, q, s, changed) {
	build_deps()
	closure(path)
	for (p = 1; p <= pred_n; p++)
		for (q = 1; q <= pred_n; q++)
			if (((p, q) in dep_neg) && ((q, p) in path))
				die(pred_where(p), "error: program contains " \
					"recursion through negation: " predicate_label(p))
	for (p = 1; p <= pred_n; p++)
		stratum[p] = 0
	changed = 1
	while (changed) {
		changed = 0
		for (p = 1; p <= pred_n; p++)
			for (q = 1; q <= pred_n; q++) {
				s = stratum[p]
				if ((p, q) in dep_pos && s < stratum[q])
					s = stratum[q]
				if ((p, q) in dep_neg && s <= stratum[q])
					s = stratum[q] + 1
				if (s == stratum[p])
					continue
				stratum[p] = s
				changed = 1
			}
	}
	max_stratum = 0
	for (p = 1; p <= pred_n; p++)
		if (stratum[p] > max_stratum)
			max_stratum = stratum[p]
	# A recursive predicate is one that reaches itself.  Every cycle left
	# is positive and so lies within one stratum, which makes the closure
	# already taken the answer.
	#
	# This is reported by -v -v and is deliberately not what drives the
	# delta loop: a rule is re-run because it reads a relation this stratum
	# derives, recursively or not (see delta_next_pos), since
	# reach(X) :- path(X, _) beside a recursive path has to keep firing
	# too.  Gating on pred_recursive instead is the bug
	# tests/cases/eval-semi-consumer.dl exists to catch.
	for (p = 1; p <= pred_n; p++)
		if ((p, p) in path)
			pred_recursive[p] = 1
}

# Transitive closure in place, over a P x P edge set (Warshall).
function closure(edge,   k, p, q) {
	for (k = 1; k <= pred_n; k++)
		for (p = 1; p <= pred_n; p++) {
			if (!((p, k) in edge))
				continue
			for (q = 1; q <= pred_n; q++)
				if ((k, q) in edge)
					edge[p, q] = 1
		}
}

# Where a predicate is defined, so that a stratification error can point into
# the source instead of naming the file alone.
function pred_where(p,   r) {
	for (r = 1; r <= rule_n; r++)
		if (!rule_is_query[r] && rule_head_pred[r] == p)
			return source_where(rule_line[r], rule_col[r])
	return ""
}

# ------------------------------------------------------------ evaluation ---
#
# One stratum at a time, lowest first.  The two engines share eval_rule(),
# plan_rule(), join(), match_tuple() and emit_head(), and differ only in which
# rules they re-run and in which relation one designated body literal scans:
#
#	-D naive  re-runs every rule in the stratum against the full
#		  relations until a pass derives nothing.  Slow by
#		  construction and kept as the correctness oracle the test
#		  suite checks the fast engine against.
#	-D semi	  runs every rule once, then re-runs only the rules that read
#		  a predicate this stratum derives, once per such body
#		  position, with that position scanning the delta: the rows
#		  the previous round added.
#
# Sharing the join is what keeps the two from drifting apart: a divergence
# can only come from the rule and delta selection above, which is exactly
# what the differential dump compares.

function evaluate(   s) {
	for (s = 0; s <= max_stratum; s++)
		if (opt_mode == "naive")
			eval_naive(s)
		else
			eval_semi(s)
}

# Rules are selected by the stratum of their head, and that is what freezes
# the lower strata while this one runs: no rule evaluated here can
# insert into a relation belonging anywhere else, so a negated predicate is
# already complete by the time the stratum negating it is reached.
function stratum_rule(r, s) {
	return !rule_is_fact[r] && !rule_is_query[r] &&
		stratum[rule_head_pred[r]] == s
}

# Re-run the lot until a pass adds nothing.  delta_active stays 0 for the
# whole run, so emit_head records nothing.
function eval_naive(s,   r) {
	do {
		eval_added = 0
		stat_iterations++
		for (r = 1; r <= rule_n; r++)
			if (stratum_rule(r, s))
				eval_rule(r, 0)
	} while (eval_added)
}

# The seed pass runs every rule once against the full relations; after it,
# any derivation still missing must use a tuple that pass produced, so the
# fixpoint only has to re-run the rules that read a predicate this stratum
# derives -- once per such position, with that position scanning the delta.
#
# Seeding the delta with the whole relation rather than with what the seed
# pass added re-derives some rows in the first round, which dedup
# absorbs; in exchange it removes the class of bugs where a predicate holding
# both facts and rules loses the derivations that start from its facts.
#
# stat_iterations counts passes over the stratum's rules, seed pass included,
# so that the two engines' counts mean the same thing when -v compares them.
function eval_semi(s,   r, i) {
	delta_active = 0
	stat_iterations++
	for (r = 1; r <= rule_n; r++)
		if (stratum_rule(r, s))
			eval_rule(r, 0)
	# A stratum that reads nothing it derives is at its fixpoint after that
	# one pass, so it never enters the delta loop at all.
	if (delta_scanned(s) == 0)
		return
	delta_seed()
	delta_active = 1
	while (delta_pending > 0) {
		stat_iterations++
		for (r = 1; r <= rule_n; r++) {
			if (!stratum_rule(r, s))
				continue
			i = 0
			while ((i = delta_next_pos(r, s, i)) > 0)
				eval_rule(r, i)
		}
		delta_rotate()
	}
	delta_active = 0
}

# The predicates a delta is kept for in this stratum: exactly those read at
# some position the fixpoint will designate.  Anything else -- a relation
# from a lower stratum, or a fact-only predicate that happens to sit in this
# one -- cannot change while the stratum runs, so its delta would be scanned
# by nobody and would only buy an empty extra round.
function delta_scanned(s,   r, i, p, n) {
	array_clear(delta_scan)
	n = 0
	for (r = 1; r <= rule_n; r++) {
		if (!stratum_rule(r, s))
			continue
		i = 0
		while ((i = delta_next_pos(r, s, i)) > 0) {
			p = rule_lit_pred[r, i]
			if (p in delta_scan)
				continue
			delta_scan[p] = 1
			n++
		}
	}
	return n
}

# The next positive body position after "from" whose predicate this stratum
# derives, or 0.  A fact-only predicate is excluded even when it shares the
# stratum: it never grows, so no derivation can come to depend on it that did
# not already.  Note that this is a property of the rule, not of the head:
# a non-recursive rule reading a recursive relation -- reach(X) :- path(X, _)
# alongside a recursive path -- has to keep firing as that relation grows.
function delta_next_pos(r, s, from,   i, p) {
	for (i = from + 1; i <= rule_body_n[r]; i++) {
		if (rule_lit_kind[r, i] != 1)
			continue
		p = rule_lit_pred[r, i]
		if (stratum[p] == s && (p in pred_has_rule))
			return i
	}
	return 0
}

# The first round scans the whole of every relation delta_scanned() picked
# out, not just what the seed pass added -- so those relations are staged as
# if a round had just derived them, and rotated in.  A delta holds tuple ids
# only; the rows themselves stay in the one tuple table.
function delta_seed(   p, k) {
	# next_t is already empty: delta_rotate() leaves it so, and nothing
	# writes it outside a delta loop.
	for (p = 1; p <= pred_n; p++) {
		next_n[p] = 0
		if (!(p in delta_scan))
			continue
		for (k = 1; k <= pred_tuple_count[p]; k++)
			next_t[p, k] = pred_tuple[p, k]
		next_n[p] = pred_tuple_count[p]
	}
	delta_rotate()
}

# What a round derived becomes what the next round scans.  The rows are
# copied rather than the two arrays swapped: a swap wants a three-subscript
# delta_t[phase, p, k], which every read of a delta would then have to spell
# out, and what is copied is only the ids of what the round just derived.
function delta_rotate(   p, k) {
	array_clear(delta_t)
	delta_pending = 0
	for (p = 1; p <= pred_n; p++) {
		delta_n[p] = next_n[p]
		for (k = 1; k <= next_n[p]; k++)
			delta_t[p, k] = next_t[p, k]
		delta_pending += next_n[p]
		next_n[p] = 0
	}
	array_clear(next_t)
}

# One run of one rule.  d is the body position designated to scan the delta,
# or 0 for a pass over the full relations.
function eval_rule(r, d,   n) {
	stat_rule_runs++
	delta_lit = d
	n = plan_rule(r, d)
	join(r, n, 1)
}

# Body order is chosen per rule invocation rather than once at parse time, so
# the relation sizes it weighs are current.  Order is a correctness matter
# and not only a speed one: safety is decided over the whole body regardless
# of the order it is written in, so a source
# may legally write "not penguin(X), bird(X)" and the negation has to end up
# after the literal that binds X.
function plan_rule(r, d,   n, np, i, best, best_bound, best_size, nb, size) {
	n = rule_body_n[r]
	array_clear(plan_done)
	array_clear(plan_bound)
	np = 0
	# A designated delta literal goes first: every derivation this run is
	# allowed to make must use it, and its relation is the
	# smallest one in play, so placing it anywhere else would only scan
	# more rows to reach the same answers.
	if (d > 0) {
		np = 1
		plan[1] = d
		plan_done[d] = 1
		plan_mark(r, d)
	}
	while (np < n) {
		# A comparison or negation whose variables are all bound binds
		# nothing further and can only cut the search, so it is worth
		# more than any remaining relation scan.
		best = 0
		for (i = 1; i <= n; i++)
			if (!(i in plan_done) && rule_lit_kind[r, i] != 1 &&
			    plan_ready(r, i)) {
				best = i
				break
			}
		# Otherwise the positive literal with the most arguments
		# already bound, then the smallest relation, then the earliest
		# in the source: a total and deterministic rule, so one
		# program and dataset always evaluate in the same order.
		if (best == 0) {
			best_bound = -1
			best_size = 0
			for (i = 1; i <= n; i++) {
				if ((i in plan_done) || rule_lit_kind[r, i] != 1)
					continue
				nb = plan_bound_count(r, i)
				size = pred_tuple_count[rule_lit_pred[r, i]]
				if (nb > best_bound ||
				    (nb == best_bound && size < best_size)) {
					best = i
					best_bound = nb
					best_size = size
				}
			}
		}
		# Unreachable while check_rule_safety() has run, since it
		# leaves every comparison and negation bound by some positive
		# literal.  The fallback keeps the plan total rather than
		# silently dropping a filter should that ever stop holding.
		if (best == 0)
			for (i = 1; i <= n; i++)
				if (!(i in plan_done)) {
					best = i
					break
				}
		np++
		plan[np] = best
		plan_done[best] = 1
		plan_mark(r, best)
	}
	return n
}

# Only a positive literal binds, so only a positive literal marks; a
# comparison or negation reached through the fallback above must not be
# allowed to claim it bound anything.
function plan_mark(r, i,   k) {
	if (rule_lit_kind[r, i] != 1)
		return
	for (k = 1; k <= rule_lit_arity[r, i]; k++)
		if (term_kind[r, i, k] == 1)
			plan_bound[term_val[r, i, k]] = 1
}

function plan_ready(r, i,   k) {
	for (k = 1; k <= rule_lit_arity[r, i]; k++)
		if (term_kind[r, i, k] == 1 && !(term_val[r, i, k] in plan_bound))
			return 0
	return 1
}

function plan_bound_count(r, i,   k, n) {
	n = 0
	for (k = 1; k <= rule_lit_arity[r, i]; k++)
		if (term_kind[r, i, k] == 1 && (term_val[r, i, k] in plan_bound))
			n++
	return n
}

# Recursive nested-loop join over one binding environment: each level binds
# what its literal needs, recurses, then undoes exactly its own bindings.
# Nothing is materialised between literals, so there are no binding tables to
# allocate or copy.  Depth is the body length, so it stays small.
function join(r, n, pos,   i, kind, p, c, k, t, use_delta) {
	if (pos > n) {
		if (rule_is_query[r])
			query_emit(r)
		else
			emit_head(r)
		return
	}
	i = plan[pos]
	kind = rule_lit_kind[r, i]
	if (kind == 3) {
		if (eval_compare(r, i))
			join(r, n, pos + 1)
		return
	}
	if (kind == 2) {
		if (eval_negation(r, i))
			join(r, n, pos + 1)
		return
	}
	p = rule_lit_pred[r, i]
	# The designated position scans only what the previous round derived;
	# every other position scans the whole relation, so each derivation
	# this run makes uses at least one new tuple.
	#
	# A delta is fixed for the length of a round -- rows derived now go to
	# the next one -- but a full relation is not, so its size is read once
	# before the scan: a recursive rule inserts into the very relation it
	# is scanning, and rows added while the scan runs are left to the next
	# round, which is what bounds the loop.  Rows added earlier in the
	# same round, by another rule or by an outer level of this one, are in
	# and are scanned: a rule runs against the relations as they stand,
	# not against a frozen snapshot, so the iteration count depends on the
	# order the rules are written in, though the result does not.
	use_delta = (i == delta_lit)
	c = use_delta ? delta_n[p] : pred_tuple_count[p]
	for (k = 1; k <= c; k++) {
		t = use_delta ? delta_t[p, k] : pred_tuple[p, k]
		stat_tuple_scans++
		if (match_tuple(r, i, t, pos))
			join(r, n, pos + 1)
		unbind(pos)
		if (join_stop)
			return
	}
}

# An unbound argument takes the tuple's value, a bound one or a constant must
# equal it; no general unification is needed.  Which slots this level
# bound is recorded per depth so that unbind() can revert just those.
function match_tuple(r, i, t, pos,   k, s, v) {
	bound_n[pos] = 0
	for (k = 1; k <= rule_lit_arity[r, i]; k++) {
		v = tuple_arg[t, k]
		if (term_kind[r, i, k] != 1) {
			if (term_val[r, i, k] != v)
				return 0
			continue
		}
		s = term_val[r, i, k]
		if (s in bind_has) {
			if (bind_val[s] != v)
				return 0
			continue
		}
		bind_has[s] = 1
		bind_val[s] = v
		bound_n[pos]++
		bound_at[pos, bound_n[pos]] = s
	}
	return 1
}

# bind_val is left behind: bind_has is what every read tests first, so one
# delete per slot is enough.
function unbind(pos,   j) {
	for (j = 1; j <= bound_n[pos]; j++)
		delete bind_has[bound_at[pos, j]]
	bound_n[pos] = 0
}

# Every argument is bound -- the safety check guarantees it -- so negation is
# one membership test on the candidate key and never scans a relation.
function eval_negation(r, i,   k, n, argv) {
	n = rule_lit_arity[r, i]
	for (k = 1; k <= n; k++)
		argv[k] = lit_value(r, i, k)
	return !(tuple_key(rule_lit_pred[r, i], n, argv) in tuple_exists)
}

# = and != compare encoded values, so foo, "foo" and 42 are three distinct
# values.  Ordering is numeric only; a non-numeric operand here arrived
# through a variable, which the static check cannot see, so it is a located
# run-time error rather than a silent failure that would be
# indistinguishable from "no such fact".
function eval_compare(r, i,   op, a, b) {
	a = lit_value(r, i, 1)
	b = lit_value(r, i, 2)
	op = rule_lit_op[r, i]
	if (op == "=")
		return a == b
	if (op == "!=")
		return a != b
	if (substr(a, 1, 2) != "n:")
		compare_type_error(r, i, 1, a)
	if (substr(b, 1, 2) != "n:")
		compare_type_error(r, i, 2, b)
	a = substr(a, 3) + 0
	b = substr(b, 3) + 0
	if (op == "<")
		return a < b
	if (op == "<=")
		return a <= b
	if (op == ">")
		return a > b
	return a >= b
}

function compare_type_error(r, i, k, v) {
	die(operand_where(r, i, k),
		"error: ordering comparison '" rule_lit_op[r, i] \
		"' requires numeric operands, found " \
		(substr(v, 1, 1) == "s" ? "the symbol " : "the string ") \
		format_value(v))
}

# A literal argument as the evaluator sees it: an encoded constant, or the
# encoded value currently bound to its slot.
function lit_value(r, i, k) {
	if (term_kind[r, i, k] == 1)
		return bind_val[term_val[r, i, k]]
	return term_val[r, i, k]
}

function head_value(r, k) {
	if (rule_head_kind[r, k] == 1)
		return bind_val[rule_head_val[r, k]]
	return rule_head_val[r, k]
}

# The head of a rule whose body succeeded.  Deduplication is the tuple
# store's, so a re-derived row costs one hash lookup and does not
# count as progress.
function emit_head(r,   p, n, k, t, argv) {
	p = rule_head_pred[r]
	n = rule_head_arity[r]
	for (k = 1; k <= n; k++)
		argv[k] = head_value(r, k)
	t = tuple_add(p, n, argv)
	if (!tuple_added)
		return
	eval_added++
	stat_derived_facts++
	# The row joins the next round's delta, but only where some rule in
	# this stratum scans that predicate's delta: recording it anywhere
	# else would keep the fixpoint alive for a round that reads it nowhere.
	if (delta_active && (p in delta_scan)) {
		next_n[p]++
		next_t[p, next_n[p]] = t
	}
}

# --------------------------------------------------------------- queries ---
#
# Queries run after the fixpoint, in source order with any -q queries last.
# A query never restricts what is computed -- every relation is materialised
# in full first, with no magic-sets rewriting.  A query joins exactly like a
# rule; only the leaf differs, in emitting a row instead of inserting a tuple.

function run_queries(   q) {
	for (q = 1; q <= query_n; q++) {
		# A blank line between blocks, so several results stay
		# distinguishable.
		if (q > 1)
			query_print("")
		query_run(query_rule[q])
	}
}

# Everything a query prints goes through one of these two, because -n and a
# dump run have to suppress the lot.  Rows come out in the order the
# evaluator reached them, which is unspecified and which the two engines
# genuinely differ on -- so letting them into a dump would make two
# engines that agree on the whole model look as though they disagreed.  The
# queries still run under AWKLOG_DUMP: they cannot change a relation, but a
# comparison against a non-numeric operand still has to fail where it would
# fail without it.
#
# query_print() is for the blank line between blocks, row_print() for the
# rows themselves, which -s diverts through sort(1).
function query_print(line) {
	if (!opt_dump && !opt_quiet)
		print line
}

function row_print(line) {
	if (opt_dump || opt_quiet)
		return
	if (!opt_sort) {
		print line
		return
	}
	# An RFC 4180 field holding a newline spans lines, and sort(1) sorts
	# lines, so this row is about to be pulled apart.  Refusing -s for csv
	# outright would cost every result that holds no newline, which is
	# nearly all of them, so the combination is allowed and diagnosed --
	# once, on the first row it actually damages.
	if (opt_format == "csv" && !sort_warned && index(line, "\n")) {
		sort_warned = 1
		warn("", "-s cannot sort a csv row containing a newline: "\
			"RFC 4180 spells such a value across lines and "\
			"sort(1) will separate them")
	}
	if (!sort_open) {
		# The rows reach the terminal through sort's stdout and not
		# through awk's, so anything already printed -- the blank line
		# that separates this block from the last one, above all -- has
		# to be pushed out first or it could land after them.  fflush()
		# is the one function here that POSIX adopted only in its 2024
		# edition; every awk in practical use has long had it.
		fflush()
		sort_open = 1
	}
	print line | SORTCMD
}

# Each query is sorted on its own rather than the whole output at once, so
# closing the pipe here is what keeps one block's rows from mixing with the
# next one's.
function rows_flush() {
	if (sort_open) {
		sort_open = 0
		sort_close(SORTCMD, "the query's rows")
	}
}

# Rows leave through sort's stdout, so a sort that could not run takes them
# with it and awklog would otherwise exit 0 having printed nothing, which a
# pipeline reads as "no rows matched".  Only two of the four tested awks
# report it -- mawk and gawk return 127 from close() on a failed pipe,
# BWK awk and gawk --posix return 0 -- but all four return 0 on success, so
# the check never fires wrongly and catches the failure where it can.
#
# Only ever called on a pipe that has been written to: close() of a command
# that was never opened returns -1 on all four, which would read here as a
# failure that never happened.
function sort_close(cmd, what,   status) {
	status = close(cmd)
	if (status == 0)
		return
	# SIGPIPE is not a failure, it is the reader leaving: awklog -s f.dl
	# | head kills sort once head has what it wants, and mawk and gawk
	# report that here as 269 (256 + 13).  Taking it for a failed sort
	# would make an ordinary pipeline exit 1 with a bogus diagnostic --
	# and intermittently, since it depends on whether the reader went
	# first.  The modulus covers a host that returns the bare signal.
	if (status % 256 == 13)
		return
	die("", "sort failed (status " status "): cannot produce " what)
}

function query_run(r,   n) {
	array_clear(query_seen)
	# Belt and braces: join() unbinds at every level on the way out, the
	# ground short-circuit included, so this is already empty.  A query
	# must not inherit a binding from anything.
	array_clear(bind_has)
	query_rows = 0
	query_ground = (rule_head_arity[r] == 0)
	join_stop = 0
	# A query scans complete relations, never a delta: evaluation has
	# finished, and delta_lit is left pointing at whatever body position
	# the last rule run designated.
	delta_lit = 0
	n = plan_rule(r, 0)
	join(r, n, 1)
	# Cleared on the way out too: a ground query leaves the flag set, and
	# the next query reads the same flag inside join().
	join_stop = 0
	# No columns means a ground query -- including one whose only
	# variables are anonymous, since those are never projected -- and a
	# ground query answers true or false.
	if (query_ground)
		row_print(query_rows > 0 ? "true" : "false")
	rows_flush()
}

# Columns are the named variables in order of first appearance.
# Two bindings of the anonymous variables can project one row, so rows are
# deduplicated on their encoded values rather than on the printed text: a
# symbol and a string can print alike in text format and are still distinct.
function query_emit(r,   k, v, key, row) {
	query_rows++
	if (query_ground) {
		join_stop = 1
		return
	}
	key = ""
	row = ""
	for (k = 1; k <= rule_head_arity[r]; k++) {
		v = bind_val[rule_head_val[r, k]]
		key = key SUBSEP v
		row = (k == 1) ? format_field(v) : row FIELDSEP format_field(v)
	}
	if (key in query_seen)
		return
	query_seen[key] = 1
	row_print(row)
}

# ---------------------------------------------------------------- output ---
#
# Three formats, one column at a time.  README.md documents them as stable.
#
#	text	symbols and numbers bare, a string bare unless it is empty or
#		carries whitespace or a quote, in which case it is quoted with
#		the escapes of the source language, so it reads back.
#	csv	RFC 4180: a quote is doubled, and a field is quoted when it
#		holds a comma, a quote, CR or LF, or has a leading or trailing
#		space.
#	tsv	escaped, never quoted: backslash, tab, newline and CR become
#		\\, \t, \n and \r, so every row is one line and every column
#		one field.
#
# All three drop the type tag: none spells the symbol foo apart from the
# string "foo", since text quotes a string only when its contents force it.
# Only the relation dump keeps types, and it is not an output format.

function format_field(v) {
	if (opt_format == "csv")
		return csv_quote(value_decode(substr(v, 3)))
	if (opt_format == "tsv")
		return tsv_escape(value_decode(substr(v, 3)))
	return format_value(v)
}

# The text spelling of an encoded value, also what a diagnostic quotes back.
function format_value(v,   kind, text) {
	kind = substr(v, 1, 1)
	text = value_decode(substr(v, 3))
	if (kind == "q" && text_needs_quote(text))
		return text_quote(text)
	return text
}

# The inverse of value_escape(): \\ is a backslash, \S the SUBSEP byte.
function value_decode(s,   out, i, c) {
	if (index(s, "\\") == 0)
		return s
	out = ""
	for (i = 1; ; i++) {
		c = substr(s, i, 1)
		if (c == "")
			break
		if (c != "\\") {
			out = out c
			continue
		}
		i++
		c = substr(s, i, 1)
		out = out (c == "S" ? SUBSEP : c)
	}
	return out
}

function text_needs_quote(s) {
	return s == "" || index(s, " ") || index(s, "\t") || index(s, "\n") ||
		index(s, "\r") || index(s, "\"")
}

function text_quote(s) {
	return "\"" escape_text(s, 1) "\""
}

# tsv leans on the same escapes as a quoted text value, minus the quote
# itself, which tsv has no reason to touch.  A field with none of them is
# returned untouched, which is the common case and skips the scan.
function tsv_escape(s) {
	if (index(s, "\\") == 0 && index(s, "\t") == 0 && index(s, "\n") == 0 &&
	    index(s, "\r") == 0)
		return s
	return escape_text(s, 0)
}

# The source language's string escapes, built with a character loop rather
# than gsub(): POSIX leaves a backslash in a gsub() replacement undefined
# outside \& and \\.
function escape_text(s, quotes,   out, i, c) {
	out = ""
	for (i = 1; ; i++) {
		c = substr(s, i, 1)
		if (c == "")
			break
		if (c == "\\")
			out = out "\\\\"
		else if (c == "\"" && quotes)
			out = out "\\\""
		else if (c == "\n")
			out = out "\\n"
		else if (c == "\t")
			out = out "\\t"
		else if (c == "\r")
			out = out "\\r"
		else
			out = out c
	}
	return out
}

# RFC 4180.  Leading and trailing spaces are preserved by the standard but
# eaten by a good many readers, so a field carrying one is quoted too.
#
# A field holding a newline is quoted and stays as it is, which is what the
# standard asks for and what makes such a row span lines.  -s sorts lines,
# so the two do not mix: a csv result whose values carry newlines cannot be
# sorted meaningfully by anything line-oriented, sort(1) included.  tsv
# escapes instead of quoting and has no such hole.
#
# gsub() is safe here, unlike in escape_text(): the replacement holds no
# backslash, which is the only thing POSIX leaves undefined in one.
function csv_quote(s) {
	if (s !~ /[,"\n\r]|^ | $/)
		return s
	gsub(/"/, "\"\"", s)
	return "\"" s "\""
}

# ------------------------------------------------------------------ dump ---
#
# Every relation, whole, in an order that does not depend on the engine --
# the test suite compares this between -D naive and -D semi, and the two
# insert their tuples in different orders by construction.  Rows therefore go
# through sort(1) rather than out as stored: it is the same mechanism -s uses
# and the only sort available without asort().  A predicate's own line
# carries its size, so that a relation the
# other engine left empty is a difference and not a silence.
#
# A value is printed with its type letter and always quoted, so that the
# symbol foo, the string "foo" and the number 42 stay three distinct rows and
# a value holding a newline stays on one line.

function dump_relations(   p, k, a, t, line) {
	# Nothing to dump means nothing opens the pipe, and closing one that
	# was never opened would report a failure that never happened.
	if (pred_n == 0)
		return
	# The rows reach the terminal through sort's stdout and not through
	# awk's, so anything already printed has to be pushed out first or it
	# could land after them.  All four tested awks happen to flush at the
	# pipe themselves, but only fflush() makes that a guarantee.
	fflush()
	for (p = 1; p <= pred_n; p++) {
		print predicate_label(p) "\t#\t" pred_tuple_count[p] | SORTCMD
		for (k = 1; k <= pred_tuple_count[p]; k++) {
			t = pred_tuple[p, k]
			line = predicate_label(p)
			for (a = 1; a <= pred_arity[p]; a++)
				line = line "\t" dump_value(tuple_arg[t, a])
			print line | SORTCMD
		}
	}
	sort_close(SORTCMD, "the relation dump")
}

function dump_value(v) {
	return substr(v, 1, 1) text_quote(value_decode(substr(v, 3)))
}

# ------------------------------------------------------------ statistics ---

function print_stats(   p) {
	note("read " stat_lines " line(s) from " stat_files " file(s)")
	note(pred_n " predicate(s), " stat_input_facts " input fact(s), " \
		stat_rules " rule(s), " query_n " query(s), " \
		(max_stratum + 1) " stratum(s)")
	if (stat_dup_facts > 0)
		note(stat_dup_facts " duplicate fact(s) collapsed")
	if (stat_undefined > 0)
		note(stat_undefined " undefined predicate(s) treated as empty")
	if (stat_unused > 0)
		note(stat_unused " derived predicate(s) never used")
	# Only -c skips evaluation, so these would otherwise print a row of
	# zeros that reads as a result rather than as "not run".
	if (!opt_check)
		note(stat_derived_facts " derived fact(s) in " stat_iterations \
			" iteration(s), " stat_rule_runs " rule run(s), " \
			stat_tuple_scans " tuple scan(s)")
	# Relation sizes and strata are per predicate and grow with the program,
	# so they are held back until -v -v.  Predicates come out in order of
	# first appearance, which is stable for a given source.  The tuple count
	# comes first because a relation's size is what a -v -v reader is
	# usually after; recursive is printed only when it holds.
	if (opt_verbose >= 2)
		for (p = 1; p <= pred_n; p++)
			note(predicate_label(p) ": " pred_tuple_count[p] \
				" tuple(s), stratum " stratum[p] \
				((p in pred_recursive) ? ", recursive" : ""))
}
