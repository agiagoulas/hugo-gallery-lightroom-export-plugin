# test-pure     the modules that import nothing from the SDK - they are the ones
#               that could silently write a broken index.md.
# test-commands the git command lines, on both platforms, by stubbing the SDK and
#               loading the real module. The only way to check the Windows half
#               without a Windows machine.
test:
	luajit test-pure.lua
	luajit test-commands.lua

.PHONY: test
