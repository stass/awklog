# awklog -- convenience targets only; nothing here is needed to run awklog.

PREFIX?=	/usr/local
BINDIR?=	$(PREFIX)/bin
LIBEXECDIR?=	$(PREFIX)/libexec
INSTALL?=	install

all:
	@echo "nothing to build; try: make test, make fuzz, make install, make lint, make count"

# The cases, then a short random differential run, so that the two engines
# are compared on programs nobody wrote on every run.
test:
	sh tests/run.sh
	sh tests/fuzz.sh 25

# The portability sweep: make test, but an error rather than a warning when
# any of BWK awk, mawk or gawk is missing.
sweep:
	SWEEP=1 sh tests/run.sh
	SWEEP=1 sh tests/fuzz.sh 25

# 500 generated programs through both engines and every awk.
# FUZZ="count first-seed" picks another range.
FUZZ?=	500 1
fuzz:
	sh tests/fuzz.sh $(FUZZ)

# The installed wrapper cannot find awklog.awk beside itself, so its default
# libexec path is rewritten to this install's LIBEXECDIR, so it resolves
# deterministically.  DESTDIR is left out: it only stages.
# The rewrite goes to a scratch file and is checked before anything is
# installed: if the wrapper's default ever stops matching the pattern, the
# install fails rather than ship a wrapper that cannot find its interpreter.
# install(1) then replaces the destination instead of writing through it,
# which matters when that destination is a symlink back into this checkout.
install:
	sed '/^libexec=/s|/usr/local/libexec/awklog.awk|$(LIBEXECDIR)/awklog.awk|' \
		awklog > awklog.inst
	grep -q '^libexec=.*:-$(LIBEXECDIR)/awklog.awk}$$' awklog.inst || \
		{ rm -f awklog.inst; echo "install: cannot set the libexec path" >&2; exit 1; }
	$(INSTALL) -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(LIBEXECDIR)
	$(INSTALL) -m 644 awklog.awk $(DESTDIR)$(LIBEXECDIR)/awklog.awk
	$(INSTALL) -m 755 awklog.inst $(DESTDIR)$(BINDIR)/awklog
	rm -f awklog.inst

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/awklog $(DESTDIR)$(LIBEXECDIR)/awklog.awk

# Portability gate: shell syntax, awk parse, and a grep for constructs outside
# POSIX awk (comment lines are blanked first).
lint:
	@sh -n awklog && echo "awklog: sh syntax ok"
	@for f in tests/run.sh tests/fuzz.sh tests/awks.sh; do \
		sh -n $$f && echo "$$f: sh syntax ok" || exit 1; done
	@awk -f awklog.awk /dev/null && echo "awklog.awk: parses"
	@awk -f tests/gen.awk > /dev/null && echo "tests/gen.awk: parses"
	@for f in awklog.awk tests/gen.awk; do \
		awk '{ if ($$0 ~ /^[ \t]*#/) print ""; else print }' $$f | \
		if grep -n -E 'asorti?\(|gensub\(|PROCINFO|@namespace|typeof\(|switch *\(|length\([A-Za-z_][A-Za-z_0-9]*\)|\\s'; then \
			echo "lint: forbidden construct above in $$f" >&2; exit 1; \
		else echo "$$f: no forbidden constructs"; fi || exit 1; done

count:
	@awk 'END { print NR " lines in awklog.awk" }' awklog.awk

.PHONY: all test sweep fuzz install uninstall lint count
