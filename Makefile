# The slug/filename and YAML-escaping modules import nothing from the Lightroom
# SDK precisely so they can be checked here - they are the ones that could
# silently write a broken index.md into a site.
test:
	luajit test-pure.lua

.PHONY: test
