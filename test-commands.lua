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
stubs.LrTasks = {
	execute = function( cmd ) executed = cmd; return 0 end,
	pcall = function( f, ... ) return pcall( f, ... ) end,
}
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
-- The metadata layer. It was rewritten to read the catalog once per selection
-- instead of per photo - and, in the sort comparator, per comparison - so it is
-- worth proving the values still arrive where they are used.

local batchCalls, batchKeys = 0, nil
local function photo( name, fields )
	local p = { name = name }
	p.getRawMetadata = function( self, key ) return fields[ key ] end
	p.fields = fields
	return p
end

local later = photo( 'b.jpg', { dateTimeOriginalISO8601 = '2026-05-04T10:00:00',
	dateTimeOriginal = 200, fileName = 'b.jpg', rating = 5 } )
local earlier = photo( 'a.jpg', { dateTimeOriginalISO8601 = '2026-05-02T10:00:00',
	dateTimeOriginal = 100, fileName = 'a.jpg', rating = 2,
	gps = { latitude = 45.4408, longitude = 12.3155 } } )
local shot = { later, earlier }   -- deliberately not in capture order

stubs.LrApplication = { activeCatalog = function()
	return { batchGetRawMetadata = function( _, photos, keys )
		batchCalls, batchKeys = batchCalls + 1, keys
		local out = {}
		for _, ph in ipairs( photos ) do out[ ph ] = ph.fields end
		return out
	end }
end }

package.loaded[ 'HugoAlbumMetadata' ] = nil
local Metadata = require 'HugoAlbumMetadata'

local meta = Metadata.read( shot )
eq( batchCalls, 1, 'metadata: one batch call for the whole selection' )
eq( #batchKeys >= 7, true, 'metadata: asks for every field the album needs' )
eq( meta[ earlier ].fileName, 'a.jpg', 'metadata: batch result is keyed by photo' )

local byCapture = Metadata.sortPhotos( shot, 'capture', meta )
eq( byCapture[ 1 ].name, 'a.jpg', 'sort: capture order, without touching the catalog again' )
eq( batchCalls, 1, 'sort: the comparator did not re-read the catalog' )
eq( Metadata.sortPhotos( shot, 'filename', meta )[ 1 ].name, 'a.jpg', 'sort: by filename' )
eq( Metadata.sortPhotos( shot, 'lightroom', meta )[ 1 ].name, 'b.jpg', 'sort: Lightroom order is left alone' )

local resolved = Metadata.resolve( byCapture, { coverRule = 'rating' }, meta )
eq( resolved.date, '2026-05-02', 'resolve: earliest capture date' )
eq( resolved.lat, 45.4408, 'resolve: GPS from the first photo that has it' )
eq( resolved.coverIndex, 2, 'resolve: highest rating wins, in sequence order' )
eq( resolved.coverCount, 1, 'resolve: one clear winner' )

-- If the batch call is unavailable the dialog must still work, not die.
stubs.LrApplication = { activeCatalog = function()
	return { batchGetRawMetadata = function() error( 'nope' ) end }
end }
package.loaded[ 'HugoAlbumMetadata' ] = nil
Metadata = require 'HugoAlbumMetadata'
local fallback = Metadata.read( shot )
eq( fallback[ earlier ].fileName, 'a.jpg', 'metadata: falls back to per-photo reads' )
eq( Metadata.resolve( shot, { coverRule = 'first' }, fallback ).date, '2026-05-02',
	'metadata: the fallback carries the same values' )


--------------------------------------------------------------------------------
-- Preferences that reach the filesystem and git. albumsFolder is free text and
-- decides where albums are written; the numeric fields go straight into the
-- export API.

package.loaded[ 'HugoAlbumPrefs' ] = nil
package.loaded[ 'HugoAlbumRepo' ] = nil
local prefsTable = { repoPath = '/site', albumsFolder = 'content' }
stubs.LrPrefs.prefsForPlugin = function() return prefsTable end
local Prefs = require 'HugoAlbumPrefs'
Repo = require 'HugoAlbumRepo'

local function folder( value )
	prefsTable.albumsFolder = value
	local cleaned, ok = Prefs.folder( 'albumsFolder' )
	return cleaned .. ( ok and '' or ' [rejected]' )
end

eq( folder( 'content' ), 'content', 'folder: the ordinary case' )
eq( folder( 'content/albums' ), 'content/albums', 'folder: nested section' )
eq( folder( 'content/' ), 'content', 'folder: trailing slash trimmed' )
eq( folder( 'content//albums' ), 'content/albums', 'folder: doubled slash collapsed' )
eq( folder( '' ), 'content', 'folder: empty falls back to the default, not the repo root' )
eq( folder( '  ' ), 'content', 'folder: whitespace is empty' )
eq( folder( '/content' ), 'content [rejected]', 'folder: absolute paths are refused' )
eq( folder( 'C:/content' ), 'content [rejected]', 'folder: drive letters are refused' )
eq( folder( 'content/../..' ), 'content [rejected]', 'folder: cannot climb out of the site' )
eq( folder( 'content\\albums' ), 'content/albums', 'folder: backslashes are normalised' )

prefsTable.albumsFolder = 'content/albums'
eq( Repo.albumRelPath( 'venice' ), 'content/albums/venice', 'folder: git sees a clean relative path' )
prefsTable.albumsFolder = '/content'
eq( Repo.albumRelPath( 'venice' ), 'content/venice', 'folder: a rejected value cannot reach git' )
prefsTable.albumsFolder = 'content'

local function number( key, value )
	prefsTable[ key ] = value
	return Prefs.number( key )
end
eq( number( 'longEdge', '0' ), 240, 'clamp: a long edge of 0 would export nothing' )
eq( number( 'longEdge', '99999' ), 10000, 'clamp: upper bound' )
eq( number( 'longEdge', 'abc' ), 2048, 'clamp: nonsense falls back to the default' )
eq( number( 'longEdge', '' ), 2048, 'clamp: empty falls back to the default' )
eq( number( 'jpegQuality', '900' ), 100, 'clamp: 900 would become LR_jpeg_quality 9.0' )
eq( number( 'jpegQuality', '0' ), 1, 'clamp: lower bound' )
eq( number( 'jpegQuality', '92' ), 92, 'clamp: a sane value is untouched' )
prefsTable.longEdge, prefsTable.jpegQuality = 2048, 92

--------------------------------------------------------------------------------
-- Committing only the album. The dialog promises that nothing else of the
-- user's gets committed; without the pathspec on the commit that is false.

local commands = {}
local realExecute = stubs.LrTasks.execute
stubs.LrTasks.execute = function( cmd ) commands[ #commands + 1 ] = cmd ; return realExecute( cmd ) end

Repo.commitAlbum( '/site', 'content/venice', 'Add Venice' )
eq( #commands, 2, 'commit: stages then commits' )
eq( commands[ 1 ]:match( "git' (.-) > " ), "-C '/site' 'add' '--' 'content/venice'",
	'commit: the add is limited to the album' )
eq( commands[ 2 ]:match( "git' (.-) > " ),
	"-C '/site' 'commit' '-m' 'Add Venice' '--' 'content/venice'",
	'commit: and so is the commit, so nothing already staged rides along' )
stubs.LrTasks.execute = realExecute

--------------------------------------------------------------------------------

io.write( '\n', failures == 0 and 'all command tests passed\n' or ( failures .. ' FAILURES\n' ) )
os.exit( failures == 0 and 0 or 1 )
