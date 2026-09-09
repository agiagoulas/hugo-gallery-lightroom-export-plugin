--[[
Checks the git command lines HugoGalleryRepo builds, on both platforms.

This is the one part of the plugin that cannot be exercised any other way: it
leaves the SDK, and the Windows half has never run on Windows. So the SDK is
stubbed out and the REAL module is loaded - what is asserted here is the string
that would actually be handed to the shell, not a re-implementation of it.

	luajit test-commands.lua
]]

package.path = './HugoGalleryExportPlugin.lrdevplugin/?.lua;' .. package.path

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
-- Minimal SDK stubs. Only what HugoGalleryRepo and its requires actually touch.

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
	for _, m in ipairs { 'HugoGalleryRepo', 'HugoGalleryPrefs', 'HugoGalleryLog', 'HugoGalleryCoords', 'HugoGallerySlug' } do
		package.loaded[ m ] = nil
	end
	return require 'HugoGalleryRepo'
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
	dateTimeOriginal = 200, path = '/photos/b.jpg', rating = 5 } )
local earlier = photo( 'a.jpg', { dateTimeOriginalISO8601 = '2026-05-02T10:00:00',
	dateTimeOriginal = 100, path = '/photos/a.jpg', rating = 2,
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

package.loaded[ 'HugoGalleryMetadata' ] = nil
local Metadata = require 'HugoGalleryMetadata'

local meta = Metadata.read( shot )
eq( batchCalls, 1, 'metadata: one batch call for the whole selection' )
local asked = {}
for _, k in ipairs( batchKeys ) do asked[ k ] = true end
eq( asked.uuid, true, 'metadata: uuid comes from the batch too, not per photo' )
eq( asked.rating and asked.gps and asked.colorNameForLabel and asked.pickStatus, true,
	'metadata: asks for every field the album needs' )
eq( meta[ earlier ].path, '/photos/a.jpg', 'metadata: batch result is keyed by photo' )
local rawOnly = {}
for _, k in ipairs( batchKeys ) do rawOnly[ k ] = true end
eq( rawOnly.fileName, nil,
	'metadata: no formatted-only key is asked of getRawMetadata - fileName raises "Unknown key"' )
eq( rawOnly.path, true, 'metadata: the raw equivalent is path' )

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
package.loaded[ 'HugoGalleryMetadata' ] = nil
Metadata = require 'HugoGalleryMetadata'
local fallback = Metadata.read( shot )
eq( fallback[ earlier ].path, '/photos/a.jpg', 'metadata: falls back to per-photo reads' )
eq( Metadata.resolve( shot, { coverRule = 'first' }, fallback ).date, '2026-05-02',
	'metadata: the fallback carries the same values' )

-- The batch call fails wholesale on one bad key, and the fallback then reads the
-- same keys one by one. If it does not tolerate the bad one it dies of the very
-- cause it exists to survive - which is exactly how "Unknown key: fileName" took
-- the whole Export dialog down.
local hostile = photo( 'h.jpg', { path = '/photos/h.jpg', rating = 4 } )
hostile.getRawMetadata = function( self, key )
	if key == 'rating' then error( 'Unknown key: "rating"' ) end
	return self.fields[ key ]
end
local survived = Metadata.read { hostile }
eq( survived[ hostile ].path, '/photos/h.jpg', 'metadata: a rejected key costs only that field' )
eq( survived[ hostile ].rating, nil, 'metadata: ... and the rejected one is simply absent' )


--------------------------------------------------------------------------------
-- Preferences that reach the filesystem and git. albumsFolder is free text and
-- decides where albums are written; the numeric fields go straight into the
-- export API.

package.loaded[ 'HugoGalleryPrefs' ] = nil
package.loaded[ 'HugoGalleryRepo' ] = nil
local prefsTable = { repoPath = '/site', albumsFolder = 'content' }
stubs.LrPrefs.prefsForPlugin = function() return prefsTable end
local Prefs = require 'HugoGalleryPrefs'
Repo = require 'HugoGalleryRepo'

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
eq( number( 'shortEdge', '0' ), 240, 'clamp: a short edge of 0 would export nothing' )
eq( number( 'shortEdge', '99999' ), 10000, 'clamp: upper bound' )
eq( number( 'shortEdge', 'abc' ), 1365, 'clamp: nonsense falls back to the default' )
eq( number( 'shortEdge', '' ), 1365, 'clamp: empty falls back to the default' )
eq( number( 'jpegQuality', '900' ), 100, 'clamp: 900 would become LR_jpeg_quality 9.0' )
eq( number( 'jpegQuality', '0' ), 1, 'clamp: lower bound' )
eq( number( 'jpegQuality', '92' ), 92, 'clamp: a sane value is untouched' )
prefsTable.shortEdge, prefsTable.jpegQuality = 1365, 92

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
-- The locked export settings. A plain function over a plain table, and the two
-- values in it that would ruin every photo in an album without ever looking like
-- an error: the cap has to be on the short edge, and quality is a 0..1 fraction.

stubs.LrColor = function() return {} end
stubs.LrHttp = { openUrlInBrowser = function() end }
stubs.LrView = { bind = function() end, share = function() end }
stubs.LrDialogs = { message = function() end, confirm = function() end, runOpenPanel = function() end }

package.loaded[ 'HugoGalleryExportServiceProvider' ] = nil
package.loaded[ 'HugoGalleryExportDialogSections' ] = nil
prefsTable.shortEdge, prefsTable.jpegQuality = 1365, 92
local provider = require 'HugoGalleryExportServiceProvider'

local settings = {}
provider.updateExportSettings( settings )

eq( settings.LR_size_resizeType, 'shortEdge',
	'export: the short edge, so a panorama keeps its rows instead of being squashed' )
eq( settings.LR_size_maxHeight, 1365, 'export: the cap reaches the size fields' )
eq( settings.LR_size_maxHeight == settings.LR_size_maxWidth, true,
	'export: both fields carry it, so which one Lightroom reads for shortEdge cannot matter' )
eq( settings.LR_jpeg_quality, 0.92, 'export: quality is a 0..1 fraction, not 92' )
eq( settings.LR_minimizeEmbeddedMetadata, false, 'export: EXIF is kept for the lightbox captions' )
eq( settings.LR_embeddedMetadataOption, 'all', 'export: ... explicitly' )
eq( settings.LR_removeLocationMetadata, true, 'export: GPS is stripped from the files' )
eq( settings.LR_renamingTokensOn, false, 'export: the plugin names the files itself' )
eq( settings.LR_format, 'JPEG', 'export: format' )

prefsTable.shortEdge, prefsTable.jpegQuality = '900', '1000'
local clamped = {}
provider.updateExportSettings( clamped )
eq( clamped.LR_size_maxHeight, 900, 'export: a sane custom short edge is honoured' )
eq( clamped.LR_jpeg_quality, 1, 'export: an absurd quality is clamped before the division' )
prefsTable.shortEdge, prefsTable.jpegQuality = 1365, 92

--------------------------------------------------------------------------------
-- The cover rules that had no coverage: label, flag, ties and position.

package.loaded[ 'HugoGalleryMetadata' ] = nil
stubs.LrApplication = { activeCatalog = function()
	return { batchGetRawMetadata = function( _, photos )
		local out = {}
		for _, ph in ipairs( photos ) do out[ ph ] = ph.fields end
		return out
	end }
end }
Metadata = require 'HugoGalleryMetadata'

local red   = photo( 'a.jpg', { fileName = 'a.jpg', colorNameForLabel = 'Red', rating = 3 } )
local blue  = photo( 'b.jpg', { fileName = 'b.jpg', colorNameForLabel = 'blue', pickStatus = 1, rating = 3 } )
local plain = photo( 'c.jpg', { fileName = 'c.jpg', colorNameForLabel = 'none', pickStatus = 0 } )
local set = { red, blue, plain }
local setMeta = Metadata.read( set )

local function cover( rules )
	local r = Metadata.resolve( set, rules, setMeta )
	return tostring( r.coverIndex ) .. '/' .. r.coverCount
end

eq( cover { coverRule = 'label', coverLabel = 'red' }, '1/1',
	'cover: the label comparison is case-insensitive both ways' )
eq( cover { coverRule = 'label', coverLabel = 'BLUE' }, '2/1', 'cover: ... and on the setting too' )
eq( cover { coverRule = 'label', coverLabel = 'green' }, 'nil/0', 'cover: no match leaves it unset' )
eq( cover { coverRule = 'flag' }, '2/1', 'cover: pick flag' )
eq( cover { coverRule = 'rating' }, '1/2', 'cover: a tie goes to the first, and is reported as a tie' )
eq( cover { coverRule = 'first' }, '1/1', 'cover: first' )
eq( cover { coverRule = 'last' }, '3/1', 'cover: last' )
eq( cover { coverRule = 'position', coverPosition = 2 }, '2/1', 'cover: an explicit number' )
eq( cover { coverRule = 'position', coverPosition = 9 }, 'nil/0', 'cover: out of range leaves it unset' )
eq( cover { coverRule = 'position', coverPosition = 'x' }, 'nil/0', 'cover: not a number' )

-- Appending: the cover filename must carry the offset, or it names a photo from
-- the wrong end of the album.
local appended = Metadata.merge(
	{ slug = 'venice', albumTitle = 'V', albumDate = '2026-01-01', location = '', categories = '' },
	{ coverIndex = 2, coverCount = 1, date = '2026-01-01' },
	{ offset = 42, width = 2 } )
eq( appended.cover, 'venice-44.jpg', 'cover: an appended batch names the file it actually wrote' )

--------------------------------------------------------------------------------
-- validateFields' date and coordinate branches.

prefsTable.writeCoordinates = true
package.loaded[ 'HugoGalleryRepo' ] = nil
Repo = require 'HugoGalleryRepo'

local function fields( over )
	local t = { slug = 'venice', albumTitle = 'Venice', albumDate = '2026-05-02', location = '' }
	for k, v in pairs( over or {} ) do t[ k ] = v end
	return Repo.validateFields( t )
end

eq( fields(), nil, 'fields: a complete set passes' )
eq( fields { slug = '' }, 'Enter a slug - it names the album folder.',
	'fields: the slug is the required input, and empty is not malformed' )
eq( fields { slug = 'Brüssels' },
	'Slug must be lowercase letters, digits and hyphens - try "bruessels".',
	'fields: a typed title is answered with the slug it should have been' )
eq( fields { slug = 'UPPER' },
	'Slug must be lowercase letters, digits and hyphens - try "upper".',
	'fields: ... including the simple case' )
eq( fields { albumDate = '2026-5-2' }, 'Date must be YYYY-MM-DD.', 'fields: a loose date is refused' )
eq( fields { albumDate = '' }, 'Date must be YYYY-MM-DD.', 'fields: an empty date is refused' )
eq( fields { location = '45.4408, 12.3155' }, nil, 'fields: readable coordinates pass' )
eq( fields { location = 'Venice' } ~= nil, true, 'fields: a place name is refused' )
prefsTable.writeCoordinates = false
eq( fields { location = 'Venice' }, nil,
	'fields: with coordinates off, a stale value cannot dim Export over a hidden field' )

--------------------------------------------------------------------------------

io.write( '\n', failures == 0 and 'all command tests passed\n' or ( failures .. ' FAILURES\n' ) )
os.exit( failures == 0 and 0 or 1 )
