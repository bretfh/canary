GCELL = $(CURDIR)/../..

.PHONY: test

# Smoke test: stage a throwaway app pointing at gcell's counter
# example, ship it, assert dist/<name> exists and is executable.
test:
	@set -e; \
	smoke=$$(mktemp -d); \
	mkdir -p $$smoke/src; \
	cp $(GCELL)/examples/counter.scm $$smoke/src/smoke.scm; \
	printf '(gcell-app (name "smoke") (load-paths "src"))\n' > $$smoke/gcell-app.scm; \
	cd $$smoke && $(CURDIR)/gcell-build ship; \
	test -x $$smoke/dist/smoke && echo "OK: ship produced dist/smoke"; \
	rm -rf $$smoke
