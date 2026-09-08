--[[
Checks the git command lines HugoAlbumRepo builds, on both platforms.

This is the one part of the plugin that cannot be exercised any other way: it
leaves the SDK, and the Windows half has never run on Windows. So the SDK is
stubbed out and the REAL module is loaded - what is asserted here is the string
that would actually be handed to the shell, not a re-implementation of it.

	luajit test-commands.lua
]]

package.path = './HugoAlbum.lrdevplugin/?.lua;' .. package.path

local failures = 0
local function eq( got, want, label )
	if got ~= want then
		failures = failures + 1
		io.write( 'FAIL ', label, '\n  got:  ', tostring( got ), '\n  want: ', tostring( want ), '\n' )
	else
		io.write( 'ok   ', label, '\n' )
	end
end

--------------------------------------------------------------------------------
-- Minimal SDK stubs. Only what HugoAlbumRepo and its requires actually touch.

local executed, sep, tempDir, existing

local stubs = {}
stubs.LrPathUtils = {
	child = function( a, b ) return a .. sep .. b end,
	getStandardFilePath = function() return tempDir end,
}
stubs.LrFileUtils = {
	exists = function( path ) return existing[ path ] == true end,
	readFile = function() return 'stub output\n' end,
	delete = function() end,
}
stubs.LrTasks = { execute = function( cmd ) executed = cmd; return 0 end }
stubs.LrPrefs = { prefsForPlugin = function() return { repoPath = '' } end }
stubs.LrDate = { timeToIsoDate = function() return '2026-01-01' end, currentTime = function() return 0 end }
stubs.LrLogger = function()
	local noop = function() end
	return { enable = noop, info = noop, warn = noop, error = noop, trace = noop }
end

function import( name )
	return stubs[ name ] or error( 'unstubbed import: ' .. name )
end

-- IS_WIN is decided when the module loads, so each platform needs a fresh one.
local function loadRepo( isWindows )
	WIN_ENV = isWindows or nil
	for _, m in ipairs { 'HugoAlbumRepo', 'HugoAlbumPrefs', 'HugoAlbumLog', 'HugoAlbumCoords', 'HugoAlbumSlug' } do
		package.loaded[ m ] = nil
	end
	return require 'HugoAlbumRepo'
end

--------------------------------------------------------------------------------
-- macOS

sep, tempDir, existing = '/', '/tmp', {}
math.randomseed( 1 ) ; local Repo = loadRepo( false )

Repo.git( '/Users/me/My Site', { 'status', '--porcelain' } )
eq( executed:match( "^(.-) > " ),
	"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin '/usr/bin/git' -C '/Users/me/My Site' 'status' '--porcelain'",
	'macOS: absolute git, PATH prefix, single quotes' )
eq( executed:match( " 2>&1$" ) ~= nil, true, 'macOS: stderr is captured' )
eq( executed:sub( 1, 1 ) ~= '"', true, 'macOS: no outer wrapping quotes' )

Repo.git( nil, { '--version' } )
eq( executed:match( "'%-C'" ), nil, 'macOS: no -C when no path is given' )

Repo.git( "/Users/me/it's", { 'status' } )
eq( executed:match( "'/Users/me/it'\\''s'" ) ~= nil, true, 'macOS: apostrophe in a path is escaped' )

--------------------------------------------------------------------------------
-- Windows

sep, tempDir, existing = '\\', 'C:\\Temp', { ['C:\\Program Files\\Git\\cmd\\git.exe'] = true }
Repo = loadRepo( true )

Repo.git( 'C:\\Users\\me\\My Site', { 'status', '--porcelain' } )
eq( executed:sub( 1, 1 ), '"', 'Windows: command line is wrapped for cmd.exe' )
eq( executed:sub( -1 ), '"', 'Windows: ... and closed again' )
eq( executed:match( '^"(.-) > ' ),
	'"C:\\Program Files\\Git\\cmd\\git.exe" -C "C:\\Users\\me\\My Site" "status" "--porcelain"',
	'Windows: probed git.exe, double quotes, no PATH prefix' )
eq( executed:match( 'PATH=' ), nil, 'Windows: the sh-only PATH prefix is omitted' )

-- Falls back to the bare name when the probe finds nothing, since the installer
-- puts git on the system PATH.
existing = {}
Repo = loadRepo( true )
Repo.git( nil, { '--version' } )
eq( executed:match( '^""(.-)"' ), 'git', 'Windows: falls back to bare git' )

local ok, err = pcall( Repo.git, 'C:\\bad"path', { 'status' } )
eq( ok, false, 'Windows: a path containing a double quote is refused, not mangled' )


--------------------------------------------------------------------------------
-- Reading an album that already exists. Filename parsing and "where does the
-- next photo start" decide whether an append collides with what is there, so it
-- is worth checking against the real module rather than by eye.

sep, tempDir = '/', '/tmp'
existing = {
	['/site/content/venice'] = true,
	['/site/content/venice/index.md'] = true,
}
local files = {
	'/site/content/venice/venice-01.jpg',
	'/site/content/venice/venice-09.jpg',
	'/site/content/venice/venice-42.jpg',
	'/site/content/venice/index.md',
	'/site/content/venice/venice-notes.txt',
	'/site/content/venice/other-07.jpg',
}
stubs.LrFileUtils.files = function()
	local i = 0
	return function() i = i + 1 ; return files[ i ] end
end
stubs.LrPathUtils.leafName = function( p ) return p:match( '[^/]+$' ) end
stubs.LrPrefs.prefsForPlugin = function()
	return { repoPath = '/site', albumsFolder = 'content', writeCoordinates = false }
end

Repo = loadRepo( false )
local info = Repo.inspectAlbum( '/site', 'venice' )
eq( info.count, 3, 'inspect: counts only this album\'s photos' )
eq( info.highest, 42, 'inspect: finds the highest number in use' )
eq( info.width, 2, 'inspect: reports the padding width already in use' )
eq( info.index ~= nil, true, 'inspect: reads index.md' )

existing = {}
eq( Repo.inspectAlbum( '/site', 'nothing-here' ), nil, 'inspect: nil when the album is not there' )


--------------------------------------------------------------------------------
-- Consent before appending. Typing "Dolomites New" passes through the exact slug
-- "dolomites" on the way, so an album that already exists must never be written
-- to just because the name momentarily matched.

existing = {
	['/site/.git'] = true,
	['/site/hugo.toml'] = true,
	['/site/content'] = true,
	['/site/content/venice'] = true,
}
Repo = loadRepo( false )

local function settings( extra_fields )
	local t = { slug = 'venice', albumTitle = 'Venice', albumDate = '2026-05-02', location = '' }
	for k, v in pairs( extra_fields or {} ) do t[ k ] = v end
	return t
end

eq( Repo.validate( settings() ),
	'content/venice already exists, and "Add to the existing album" is not ticked.',
	'consent: an existing album is refused by default' )
eq( Repo.validate( settings { updateExisting = true } ), nil,
	'consent: ticked, the append is allowed' )

existing[ '/site/content/venice' ] = nil
eq( Repo.validate( settings() ), nil, 'consent: irrelevant when the album is new' )

-- The field checks still come first, so the message names the real problem.
existing[ '/site/content/venice' ] = true
eq( Repo.validate( settings { albumTitle = '' } ), 'Enter an album title.',
	'consent: a missing title outranks the exists check' )

--------------------------------------------------------------------------------

io.write( '\n', failures == 0 and 'all command tests passed\n' or ( failures .. ' FAILURES\n' ) )
os.exit( failures == 0 and 0 or 1 )
