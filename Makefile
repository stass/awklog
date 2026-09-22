# awklog -- convenience targets only; nothing here is needed to run awklog.

PREFIX?=	/usr/local
BINDIR?=	$(PREFIX)/bin
LIBEXECDIR?=	$(PREFIX)/libexec
INSTALL?=	install

all:
	@echo "nothing to build; try: make test, make install, make lint, make count"

test:
	sh tests/run.sh

# The portability sweep of PLAN.md section 11 (M7): make test, but an error
# rather than a warning when any of BWK awk, mawk or gawk is missing.
sweep:
	SWEEP=1 sh tests/run.sh

# The installed wrapper cannot find awklog.awk beside itself, so its default
# libexec path is rewritten to this install's LIBEXECDIR (spec §83: resolve the
# installed path deterministically).  DESTDIR is left out: it only stages.
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

# Portability gate: constructs forbidden by PLAN.md section 13.
lint:
	@sh -n awklog && echo "awklog: sh syntax ok"
	@sh -n tests/run.sh && echo "tests/run.sh: sh syntax ok"
	@awk -f awklog.awk /dev/null && echo "awklog.awk: parses"
	@awk '{ if ($$0 ~ /^[ \t]*#/) print ""; else print }' awklog.awk | \
	if grep -n -E 'asorti?\(|gensub\(|PROCINFO|@namespace|typeof\(|switch *\(|length\([A-Za-z_][A-Za-z_0-9]*\)|\\s'; then \
		echo "lint: forbidden construct above" >&2; exit 1; \
	else echo "awklog.awk: no forbidden constructs"; fi

count:
	@awk 'END { print NR " lines in awklog.awk (budget 700-1200)" }' awklog.awk

.PHONY: all test sweep install uninstall lint count
