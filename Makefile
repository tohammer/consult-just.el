EMACS ?= emacs
# Directories of the dependencies (consult, compat), if they are not
# installed with package.el, e.g.  make LOAD_PATH="-L ../consult -L ../compat"
LOAD_PATH ?=
BATCH  = $(EMACS) -Q --batch --eval '(package-initialize)' $(LOAD_PATH) -L . \
	  --eval '(setq load-prefer-newer t)'

.PHONY: all compile checkdoc test clean

all: compile checkdoc test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile consult-just.el

checkdoc:
	$(BATCH) --eval '(checkdoc-file "consult-just.el")' \
	  --eval '(when (get-buffer "*Warnings*") (kill-emacs 1))'

test:
	$(BATCH) -l test/consult-just-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
