LUAJIT ?= luajit
PYTHON ?= python3
VERSION ?= 0.1.0

.PHONY: test check package

test:
	@set -e; for t in tests/test_*.lua; do $(LUAJIT) "$$t"; done
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

check:
	@set -e; tmp=$$(mktemp); trap 'rm -f "$$tmp"' EXIT; for f in gdriveshelf.koplugin/*.lua gdriveshelf.koplugin/providers/*.lua; do $(LUAJIT) -b "$$f" "$$tmp"; done
	$(PYTHON) -m py_compile tools/authorize.py tools/package.py

package: check test
	$(PYTHON) tools/package.py --version "$(VERSION)"
