--[[
Everything that touches the Hugo site's working copy: validation, and a git wrapper.
]]

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks     = import 'LrTasks'

local Coords = require 'HugoAlbumCoords'
local Prefs  = require 'HugoAlbumPrefs'
local Slug   = require 'HugoAlbumSlug'
local log  = require 'HugoAlbumLog'

local Repo = {}

-- git is invoked by absolute path because Lightroom launched from Finder has a
-- minimal environment.
local GIT = '/usr/bin/git'

-- And PATH is prefixed so the repo's own git hooks can find the tools they call.
-- A pre-commit hook that guards image sizes typically starts with something like
--   command -v exiftool >/dev/null || exit 0
-- and Homebrew is not on the PATH Lightroom inherits - so without this the hook
-- would find no exiftool and SILENTLY SKIP its check, which is worse than it
-- failing loudly.
local PATH = 'PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'

-- POSIX single-quote quoting. Lua's %q escapes for Lua, not for sh: it leaves $
-- and backticks live, so it must not be used here.
local function sh( s )
	return "'" .. tostring( s ):gsub( "'", "'\\''" ) .. "'"
end

Repo.shellQuote = sh

-- The repo lives in the plugin's preferences, set once in the Plug-in Manager,
-- rather than in the export settings: it is a property of this machine, not of
-- an album, and re-picking it per export (or per export preset) is exactly the
-- chore the plugin exists to remove.
function Repo.configuredPath()
	return Prefs.get( 'repoPath' )
end

-- The albums folder is stored with forward slashes ('content', 'content/albums')
-- and has to become real path segments.
function Repo.albumsDir( repoPath )
	local dir = repoPath
	for segment in tostring( Prefs.get( 'albumsFolder' ) ):gmatch( '[^/]+' ) do
		dir = LrPathUtils.child( dir, segment )
	end
	return dir
end

function Repo.albumDir( repoPath, slug )
	return LrPathUtils.child( Repo.albumsDir( repoPath ), slug )
end

-- Forward slashes, for git and for messages.
function Repo.albumRelPath( slug )
	return tostring( Prefs.get( 'albumsFolder' ) ):gsub( '/+$', '' ) .. '/' .. slug
end

-- Hugo accepts a lot of names for its configuration, and a repo that has none of
-- them is almost certainly not the one the user meant to pick.
local CONFIG_FILES = {
	'hugo.toml', 'hugo.yaml', 'hugo.yml', 'hugo.json',
	'config.toml', 'config.yaml', 'config.yml', 'config.json',
	'config/_default/hugo.toml', 'config/_default/hugo.yaml',
	'config/_default/config.toml', 'config/_default/config.yaml',
}

function Repo.looksLikeHugoSite( repoPath )
	for _, name in ipairs( CONFIG_FILES ) do
		local path = repoPath
		for segment in name:gmatch( '[^/]+' ) do
			path = LrPathUtils.child( path, segment )
		end
		if LrFileUtils.exists( path ) then return true end
	end
	return false
end

--[[
Runs git in `repoPath`. Returns ok (boolean), output (string), rawStatus.

LrTasks.execute gives system()-shaped status on macOS, i.e. commonly
exitcode * 256. Only `== 0` is a reliable test; never compare against 1.
Must be called from inside a task.
]]
function Repo.git( repoPath, args )
	local outFile = LrPathUtils.child( LrPathUtils.getStandardFilePath( 'temp' ),
		'hugo-album-git-' .. tostring( math.random( 1, 1000000000 ) ) .. '.txt' )

	local parts = { PATH, GIT, '-C', sh( repoPath ) }
	for _, a in ipairs( args ) do parts[ #parts + 1 ] = sh( a ) end
	local cmd = table.concat( parts, ' ' ) .. ' > ' .. sh( outFile ) .. ' 2>&1'

	local status = LrTasks.execute( cmd )

	local output = ''
	if LrFileUtils.exists( outFile ) then
		output = LrFileUtils.readFile( outFile ) or ''
		LrFileUtils.delete( outFile )
	end

	log:info( string.format( 'git %s -> status=%s\n%s',
		table.concat( args, ' ' ), tostring( status ), output ) )

	return status == 0, output, status
end

function Repo.currentBranch( repoPath )
	local ok, out = Repo.git( repoPath, { 'rev-parse', '--abbrev-ref', 'HEAD' } )
	if not ok then return nil end
	return ( out:gsub( '%s+$', '' ) )
end

function Repo.branchExists( repoPath, branch )
	local ok = Repo.git( repoPath, { 'rev-parse', '--verify', '--quiet', 'refs/heads/' .. branch } )
	return ok
end

function Repo.isDirty( repoPath )
	local ok, out = Repo.git( repoPath, { 'status', '--porcelain' } )
	return ok and out:gsub( '%s+', '' ) ~= ''
end

--[[
Validation is split in two because of where each half can run.

`validateFields` is pure string work, so an observer - which runs inside the
property table's assignment metamethod, where nothing may yield - can call it
directly. `validatePaths` touches the file system and is therefore only ever
called from a task, with the dialog caching its result.

Both return a reason to show under a dimmed Export button, or nil.
]]
function Repo.validateFields( settings )
	if not settings.albumTitle or settings.albumTitle == '' then
		return 'Enter an album title.'
	end
	if not Slug.isValid( settings.slug ) then
		return 'Slug must be lowercase letters, digits and hyphens.'
	end

	-- These reach Hugo unquoted, so a typo here is a failed build rather than a
	-- bad-looking page. Cheaper to catch in the dialog.
	if not tostring( settings.albumDate ):match( '^%d%d%d%d%-%d%d%-%d%d$' ) then
		return 'Date must be YYYY-MM-DD.'
	end
	local location = settings.location or ''
	if location:match( '^%s*$' ) == nil and not Coords.parse( location ) then
		return 'Could not read those coordinates. Use "45.4408, 12.3155" or 46°32\'25.8"N 12°08\'08.5"E.'
	end

	return nil
end

-- Returns repoProblem, albumExists. Kept separate so the caller can report them
-- in the right order: a bad repo path outranks a missing title, but an existing
-- content/<slug> only means anything once the slug itself is valid.
function Repo.validatePaths( settings )
	local repoPath = Repo.configuredPath()
	if repoPath == '' then
		return 'Set the site folder in File > Plug-in Manager > Hugo Album Export.', false
	end
	if not LrFileUtils.exists( LrPathUtils.child( repoPath, '.git' ) ) then
		return 'Not a git repository: ' .. repoPath, false
	end
	-- Guards against pointing at some other folder, which would otherwise get a
	-- perfectly valid album written into it.
	if not Repo.looksLikeHugoSite( repoPath ) then
		return 'No Hugo configuration found in ' .. repoPath .. '.', false
	end
	if not LrFileUtils.exists( Repo.albumsDir( repoPath ) ) then
		return 'No ' .. Prefs.get( 'albumsFolder' ) .. '/ folder in ' .. repoPath .. '.', false
	end

	local exists = Slug.isValid( settings.slug )
		and LrFileUtils.exists( Repo.albumDir( repoPath, settings.slug ) )
	return nil, exists and true or false
end

-- The whole check, in display order. Only safe from a task.
function Repo.validate( settings )
	local repoProblem, albumExists = Repo.validatePaths( settings )
	if repoProblem then return repoProblem end

	local fieldProblem = Repo.validateFields( settings )
	if fieldProblem then return fieldProblem end

	if albumExists then
		return Repo.albumRelPath( settings.slug ) .. ' already exists.'
	end
	return nil
end

return Repo
