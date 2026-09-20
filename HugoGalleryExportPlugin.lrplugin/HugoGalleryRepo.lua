local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks     = import 'LrTasks'
local Coords = require 'HugoGalleryCoords'
local Prefs  = require 'HugoGalleryPrefs'
local Slug   = require 'HugoGallerySlug'
local log  = require 'HugoGalleryLog'
local Repo = {}
local IS_WIN = WIN_ENV == true
local MAC_PATH = 'PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
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

function Repo.configuredPath()
	return Prefs.get( 'repoPath' )
end

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

function Repo.albumRelPath( slug )
	return Prefs.folder( 'albumsFolder' ) .. '/' .. slug
end

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

local CONFIG_FILES = {
	'hugo.toml', 'hugo.yaml', 'hugo.yml', 'hugo.json',
	'config.toml', 'config.yaml', 'config.yml', 'config.json',
	'config/_default/hugo.toml', 'config/_default/hugo.yaml',
	'config/_default/hugo.yml', 'config/_default/hugo.json',
	'config/_default/config.toml', 'config/_default/config.yaml',
	'config/_default/config.yml', 'config/_default/config.json',
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

function Repo.git( repoPath, args )
	local outFile = LrPathUtils.child( LrPathUtils.getStandardFilePath( 'temp' ),
		'hugo-gallery-export-git-' .. tostring( math.random( 1, 1000000000 ) ) .. '.txt' )

	local parts = {}
	if not IS_WIN then parts[ #parts + 1 ] = MAC_PATH end
	parts[ #parts + 1 ] = quote( gitExecutable() )
	if repoPath and repoPath ~= '' then
		parts[ #parts + 1 ] = '-C'
		parts[ #parts + 1 ] = quote( repoPath )
	end
	for _, a in ipairs( args ) do parts[ #parts + 1 ] = quote( a ) end

	local cmd = table.concat( parts, ' ' ) .. ' > ' .. quote( outFile ) .. ' 2>&1'

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

function Repo.commitAlbum( repoPath, relPath, message )
	local ok, output, status, command = Repo.git( repoPath, { 'add', '--', relPath } )
	if not ok then return false, output, status, command end
	return Repo.git( repoPath, { 'commit', '-m', message, '--', relPath } )
end

function Repo.isDirty( repoPath )
	local ok, out = Repo.git( repoPath, { 'status', '--porcelain' } )
	return ok and out:gsub( '%s+', '' ) ~= ''
end

function Repo.validateFields( settings )
	if not settings.slug or settings.slug == '' then
		return 'Enter a slug - it names the album folder.'
	end
	if not Slug.isValid( settings.slug ) then
		local suggestion = Slug.slugify( settings.slug )
		if suggestion ~= '' and suggestion ~= settings.slug then
			return 'Slug must be lowercase letters, digits and hyphens - try "'
				.. suggestion .. '".'
		end
		return 'Slug must be lowercase letters, digits and hyphens.'
	end
	if not settings.albumTitle or settings.albumTitle == '' then
		return 'Enter an album title.'
	end

	if not tostring( settings.albumDate ):match( '^%d%d%d%d%-%d%d%-%d%d$' ) then
		return 'Date must be YYYY-MM-DD.'
	end

	local location = settings.location or ''
	if Prefs.get( 'writeCoordinates' ) and location:match( '^%s*$' ) == nil
		and not Coords.parse( location ) then
		return 'Could not read those coordinates. Use "45.4408, 12.3155" or 46°32\'25.8"N 12°08\'08.5"E.'
	end

	return nil
end

function Repo.validatePaths( settings )
	local repoPath = Repo.configuredPath()
	if repoPath == '' then
		return 'Set the site folder in File > Plug-in Manager > Hugo Gallery Export Plugin.', false
	end
	if not LrFileUtils.exists( LrPathUtils.child( repoPath, '.git' ) ) then
		return 'Not a git repository: ' .. repoPath, false
	end
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
