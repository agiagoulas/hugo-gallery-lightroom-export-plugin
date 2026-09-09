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

--[[
Everything platform-specific in this plug-in lives in this block. WIN_ENV is a
global the SDK defines; compared with `== true` so that a nil under a plain Lua
interpreter simply means "not Windows".

Windows support is experimental and unverified - see docs/windows-port.md, and
the "Test git" button in the Plug-in Manager, which exists to check exactly the
quoting produced here.
]]
local IS_WIN = WIN_ENV == true

-- On macOS git is invoked by absolute path, because Lightroom launched from
-- Finder has a minimal environment. Windows programs inherit the system PATH and
-- the Git for Windows installer puts git on it, so a bare `git` is the normal
-- case there, with the standard install locations as a fallback.
local WIN_GIT_CANDIDATES = {
	'C:\\Program Files\\Git\\cmd\\git.exe',
	'C:\\Program Files (x86)\\Git\\cmd\\git.exe',
}

local gitExecutable
do
	local cached
	gitExecutable = function()
		if cached then return cached end
		if not IS_WIN then
			cached = '/usr/bin/git'
		else
			for _, candidate in ipairs( WIN_GIT_CANDIDATES ) do
				if LrFileUtils.exists( candidate ) then cached = candidate break end
			end
			cached = cached or 'git'
		end
		return cached
	end
end

-- macOS only: PATH is prefixed so the repo's own git hooks can find the tools
-- they call. A pre-commit hook guarding image sizes typically starts with
--   command -v exiftool >/dev/null || exit 0
-- and Homebrew is not on the PATH Lightroom inherits - so without this the hook
-- would find no exiftool and SILENTLY SKIP its check, which is worse than it
-- failing loudly. On Windows the prefix is not merely useless but invalid: it is
-- sh syntax, and cmd.exe would read it as a program name.
local MAC_PATH = 'PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'

--[[
Argument quoting.

macOS gets POSIX single quotes. Lua's %q escapes for Lua, not for sh: it leaves
$ and backticks live, so it must not be used here.

cmd.exe has no single quotes at all, and no escape for a double quote inside a
quoted argument - so a path containing one is refused rather than silently
mangled into a different path.
]]
local function quote( s )
	s = tostring( s )
	if IS_WIN then
		if s:find( '"', 1, true ) then
			error( 'cmd.exe cannot quote a path containing a double quote: ' .. s )
		end
		return '"' .. s .. '"'
	end
	return "'" .. s:gsub( "'", "'\\''" ) .. "'"
end

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
	for segment in Prefs.folder( 'albumsFolder' ):gmatch( '[^/]+' ) do
		dir = LrPathUtils.child( dir, segment )
	end
	return dir
end

function Repo.albumDir( repoPath, slug )
	return LrPathUtils.child( Repo.albumsDir( repoPath ), slug )
end

-- Forward slashes, for git and for messages.
function Repo.albumRelPath( slug )
	return Prefs.folder( 'albumsFolder' ) .. '/' .. slug
end

--[[
Diagnostics for the Plug-in Manager's "Test git" button.

It runs the two shapes of command the plug-in actually builds: one without a
path, and one with the site folder - which is where quoting goes wrong first,
because that path routinely contains spaces. Reports what ran, so a tester can
paste it back without needing a debugger or any Lua.
]]
function Repo.diagnose()
	local lines = { 'Platform: ' .. ( IS_WIN and 'Windows' or 'macOS' ) }
	lines[ #lines + 1 ] = 'git: ' .. gitExecutable()

	local ok, output, status, cmd = Repo.git( nil, { '--version' } )
	lines[ #lines + 1 ] = ''
	lines[ #lines + 1 ] = cmd
	lines[ #lines + 1 ] = string.format( '  -> status %s: %s',
		tostring( status ), ( output:gsub( '%s+$', '' ) ) )

	local path = Repo.configuredPath()
	if path == '' then
		lines[ #lines + 1 ] = ''
		lines[ #lines + 1 ] = 'No site folder set, so the path-quoting half was not tested.'
	else
		local ok2, output2, status2, cmd2 = Repo.git( path, { 'rev-parse', '--abbrev-ref', 'HEAD' } )
		lines[ #lines + 1 ] = ''
		lines[ #lines + 1 ] = cmd2
		lines[ #lines + 1 ] = string.format( '  -> status %s: %s',
			tostring( status2 ), ( output2:gsub( '%s+$', '' ) ) )
		ok = ok and ok2
	end

	return ok, table.concat( lines, '\n' )
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
Runs git, inside `repoPath` when one is given. Returns ok (boolean), output
(string), rawStatus, and the command line - the last so the "Test git" button
can show exactly what ran.

LrTasks.execute gives system()-shaped status, commonly exitcode * 256. Only
`== 0` is a reliable test; never compare against 1. Must be called from inside a
task.
]]
function Repo.git( repoPath, args )
	local outFile = LrPathUtils.child( LrPathUtils.getStandardFilePath( 'temp' ),
		'hugo-album-git-' .. tostring( math.random( 1, 1000000000 ) ) .. '.txt' )

	local parts = {}
	if not IS_WIN then parts[ #parts + 1 ] = MAC_PATH end
	parts[ #parts + 1 ] = quote( gitExecutable() )
	if repoPath and repoPath ~= '' then
		parts[ #parts + 1 ] = '-C'
		parts[ #parts + 1 ] = quote( repoPath )
	end
	for _, a in ipairs( args ) do parts[ #parts + 1 ] = quote( a ) end

	local cmd = table.concat( parts, ' ' ) .. ' > ' .. quote( outFile ) .. ' 2>&1'

	-- The long-known cmd.exe workaround: when the command line contains quoted
	-- paths, the whole thing needs one further pair of double quotes around it or
	-- cmd mis-parses it. Harmless when nothing is quoted, required as soon as the
	-- site folder or the temp path contains a space - which both routinely do.
	if IS_WIN then cmd = '"' .. cmd .. '"' end

	local status = LrTasks.execute( cmd )

	local output = ''
	if LrFileUtils.exists( outFile ) then
		output = LrFileUtils.readFile( outFile ) or ''
		LrFileUtils.delete( outFile )
	end

	log:info( string.format( 'git %s -> status=%s\n%s',
		table.concat( args, ' ' ), tostring( status ), output ) )

	return status == 0, output, status, cmd
end

function Repo.branchExists( repoPath, branch )
	local ok = Repo.git( repoPath, { 'rev-parse', '--verify', '--quiet', 'refs/heads/' .. branch } )
	return ok
end

--[[
Stages the album and commits only it.

The pathspec on the commit is what makes the dialog's promise true: without it,
anything the user had already staged before opening Lightroom rides along under
an "Add Venice" message. The `git add` is still needed - a pathspec commit will
not pick up an untracked directory on its own.
]]
function Repo.commitAlbum( repoPath, relPath, message )
	local ok, output = Repo.git( repoPath, { 'add', '--', relPath } )
	if not ok then return false, output end
	return Repo.git( repoPath, { 'commit', '-m', message, '--', relPath } )
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
	-- Only when the Location field is actually on screen. Otherwise a value left
	-- over from when coordinates were enabled would dim the Export button over a
	-- field the user cannot see, with no way out.
	local location = settings.location or ''
	if Prefs.get( 'writeCoordinates' ) and location:match( '^%s*$' ) == nil
		and not Coords.parse( location ) then
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
	local folder, folderOk = Prefs.folder( 'albumsFolder' )
	if not folderOk then
		return 'The albums folder must be a relative path inside the site, like "content".', false
	end
	if not LrFileUtils.exists( Repo.albumsDir( repoPath ) ) then
		return 'No ' .. folder .. '/ folder in ' .. repoPath .. '.', false
	end

	local exists = Slug.isValid( settings.slug )
		and LrFileUtils.exists( Repo.albumDir( repoPath, settings.slug ) )
	return nil, exists and true or false
end

--[[
Describes an album that is already there, so the export can add to it instead of
refusing.

	count    how many <slug>-N.jpg files it already holds
	highest  the largest N in use - new photos continue from there
	width    how many digits those names use, so the padding stays consistent
	index    the raw text of index.md, or nil
]]
function Repo.inspectAlbum( repoPath, slug )
	local dir = Repo.albumDir( repoPath, slug )
	local info = { count = 0, highest = 0, width = 0, indexExists = false }

	if not LrFileUtils.exists( dir ) then return nil end

	for path in LrFileUtils.files( dir ) do
		local name = LrPathUtils.leafName( path )
		local digits = name:match( '^' .. slug:gsub( '%p', '%%%0' ) .. '%-(%d+)%.[jJ][pP][eE]?[gG]$' )
		if digits then
			info.count = info.count + 1
			info.highest = math.max( info.highest, tonumber( digits ) )
			info.width = math.max( info.width, #digits )
		end
	end

	-- indexExists and index are deliberately separate. readFile returns nil on
	-- failure, and a caller that cannot tell "no index.md" from "an index.md I
	-- could not read" will happily render a fresh one over the second - which is
	-- the captions, the ordering and the body gone.
	local indexPath = LrPathUtils.child( dir, 'index.md' )
	info.indexExists = LrFileUtils.exists( indexPath )
	if info.indexExists then
		info.index = LrFileUtils.readFile( indexPath )
		if not info.index then
			log:error( 'index.md exists but could not be read: ' .. indexPath )
		end
	end

	return info
end

-- The whole check, in display order. Only safe from a task.
--
-- An album that already exists is only allowed when `updateExisting` says so.
-- Checked here as well as in the dialog, because the dialog's own check runs
-- asynchronously and the answer could be a keystroke out of date by now.
function Repo.validate( settings )
	local repoProblem, albumExists = Repo.validatePaths( settings )
	if repoProblem then return repoProblem end

	local fieldProblem = Repo.validateFields( settings )
	if fieldProblem then return fieldProblem end

	if albumExists and not settings.updateExisting then
		return Repo.albumRelPath( settings.slug )
			.. ' already exists, and "Add to the existing album" is not ticked.'
	end
	return nil
end

return Repo
