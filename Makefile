test:
	luajit test-pure.lua
	luajit test-commands.lua

.PHONY: test
