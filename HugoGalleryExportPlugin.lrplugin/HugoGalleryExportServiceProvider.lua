local LrDialogs   = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks     = import 'LrTasks'
local FrontMatter = require 'HugoGalleryFrontMatter'
local Metadata    = require 'HugoGalleryMetadata'
local Prefs       = require 'HugoGalleryPrefs'
local Repo        = require 'HugoGalleryRepo'
local Sections    = require 'HugoGalleryExportDialogSections'
local Slug        = require 'HugoGallerySlug'
local log         = require 'HugoGalleryLog'

local provider = {}

provider.exportPresetFields      = Sections.exportPresetFields
provider.startDialog             = Sections.startDialog
provider.sectionsForTopOfDialog  = Sections.sectionsForTopOfDialog
provider.hideSections = {
	'exportLocation', 'fileNaming', 'fileSettings', 'imageSettings',
	'outputSharpening', 'metadata', 'video', 'watermarking',
}
provider.allowFileFormats   = { 'JPEG' }
provider.allowColorSpaces   = { 'sRGB' }
provider.canExportVideo     = false

function provider.updateExportSettings( exportSettings )
	exportSettings.LR_format            = 'JPEG'
	exportSettings.LR_export_colorSpace = 'sRGB'
	exportSettings.LR_jpeg_quality      = Prefs.number( 'jpegQuality' ) / 100   -- the API wants 0..1
	exportSettings.LR_jpeg_useLimitSize  = false
	local shortEdge = Prefs.number( 'shortEdge' )
	exportSettings.LR_size_doConstrain     = true
	exportSettings.LR_size_resizeType      = 'shortEdge'
	exportSettings.LR_size_units           = 'pixels'
	exportSettings.LR_size_maxHeight       = shortEdge
	exportSettings.LR_size_maxWidth        = shortEdge
	exportSettings.LR_size_doNotEnlarge    = true
	exportSettings.LR_size_resolution      = 240
	exportSettings.LR_size_resolutionUnits = 'inch'
	exportSettings.LR_outputSharpeningOn = false
	exportSettings.LR_minimizeEmbeddedMetadata = false
	exportSettings.LR_embeddedMetadataOption   = 'all'
	exportSettings.LR_metadata_keywordOptions  = 'flat'
	exportSettings.LR_removeLocationMetadata = true
	exportSettings.LR_renamingTokensOn      = false
	exportSettings.LR_extensionCase         = 'lowercase'
	exportSettings.LR_collisionHandling     = 'overwrite'
	exportSettings.LR_reimportExportedPhoto = false
	exportSettings.LR_includeVideoFiles     = false
	exportSettings.LR_useWatermark          = false
end

local function collectPhotos( session )
	local photos = {}
	for i, rendition in session:renditions() do
		photos[ i ] = rendition.photo
	end
	return photos
end

local function abort( exportContext, message )
	log:error( message )
	LrDialogs.message( 'Hugo Gallery export cancelled', message, 'critical' )
	for _, rendition in exportContext.exportSession:renditions() do
		rendition:skipRender()
	end
end

local function writeFile( path, contents )
	local handle, err = io.open( path, 'wb' )
	if not handle then
		error( 'Could not write ' .. path .. ': ' .. tostring( err ) )
	end
	local ok, writeErr = handle:write( contents )
	local closed, closeErr = handle:close()
	if not ok then
		error( 'Could not write ' .. path .. ': ' .. tostring( writeErr ) )
	end
	if not closed then
		error( 'Could not finish writing ' .. path .. ': ' .. tostring( closeErr ) )
	end
end

local function freeBranchName( repoPath, base )
	for n = 2, 50 do
		local candidate = base .. '-' .. n
		if not Repo.branchExists( repoPath, candidate ) then return candidate end
	end
	return nil
end

local function planGitStep( repoPath, branchName )
	if Repo.branchExists( repoPath, branchName ) then
		local alt = freeBranchName( repoPath, branchName )
		local choice = LrDialogs.confirm(
			'Branch ' .. branchName .. ' already exists',
			'Commit on it, or use a new branch?',
			alt and ( 'Use ' .. alt ) or 'Use existing',
			'Skip the git step',
			'Commit on ' .. branchName )
		if choice == 'ok' and alt then
			return alt, false
		elseif choice == 'ok' then
			return branchName, true
		elseif choice == 'other' then
			return branchName, true
		else
			return nil
		end
	end
	return branchName, false
end

function provider.processRenderedPhotos( functionContext, exportContext )
	local settings = exportContext.propertyTable
	local session  = exportContext.exportSession
	local unordered = collectPhotos( session )
	local meta      = Metadata.read( unordered )
	local photos    = Metadata.sortPhotos( unordered, settings.sequenceBy, meta )
	local total     = #photos
	local problem = Repo.validate( settings )
	if total == 0 then problem = 'No photos to export.' end
	if problem then
		return abort( exportContext, problem )
	end
	local repoPath = Repo.configuredPath()
	local slug     = settings.slug
	local albumDir = Repo.albumDir( repoPath, slug )
	local indexByUuid = {}
	for i, photo in ipairs( photos ) do
		local m = meta[ photo ]
		indexByUuid[ ( m and m.uuid ) or photo:getRawMetadata( 'uuid' ) ] = i
	end
	local existing = settings.updateExisting and Repo.inspectAlbum( repoPath, slug ) or nil
	local numbering = Slug.numbering( total, existing )
	local resolved = Metadata.resolve( photos, settings, meta )
	local album    = Metadata.merge( settings, resolved, numbering )
	if existing then album.cover = nil end
	local branchName, useExistingBranch = nil, false
	if settings.doGit then
		if Repo.isDirty( repoPath ) then
			local choice = LrDialogs.confirm( 'The repo has uncommitted changes',
				'Only ' .. Repo.albumRelPath( slug ) .. ' will be staged, so nothing else of yours gets '
				.. 'committed - but the new branch will carry your other changes along.',
				'Continue', 'Cancel export' )
			if choice ~= 'ok' then
				return abort( exportContext, 'Cancelled: the repo has uncommitted changes.' )
			end
		end
		branchName, useExistingBranch = planGitStep( repoPath, settings.branchName )
	end

	local createdDir = false
	local succeeded = false
	local written, failures, takenBy = 0, {}, {}
	local cancelledRenders = 0
	local reported = false

	functionContext:addCleanupHandler( function()
		if not succeeded and createdDir and LrFileUtils.exists( albumDir ) then
			log:warn( 'export did not complete - removing ' .. albumDir )
			LrFileUtils.delete( albumDir )
		end

		if succeeded or reported then return end
		reported = true
		local removed = createdDir
			and ( ' ' .. Repo.albumRelPath( slug ) .. ' was removed.' )
			or ( ' The photos already added were left in place.' )
		local cancelled = #failures == 0
		local message
		if cancelled then
			message = string.format( 'Cancelled after %d of %d photos.%s', written, total, removed )
		else
			message = string.format( 'Wrote %d of %d photos.%s\n\n%s',
				written, total, removed, table.concat( failures, '\n' ) )
		end
		log:warn( string.format( '%s (%d renders stopped without a reason)',
			message, cancelledRenders ) )
		local shown, err = LrTasks.pcall( LrDialogs.message,
			'Album ' .. slug .. ' was not completed', message,
			cancelled and 'warning' or 'critical' )
		if not shown then log:error( 'could not show the summary: ' .. tostring( err ) ) end
	end )

	LrFileUtils.createAllDirectories( albumDir )
	createdDir = ( existing == nil )

	exportContext:configureProgress { title = 'Building album ' .. slug }

	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		local function fail( message )
			log:error( message )
			failures[ #failures + 1 ] = message
			rendition:renditionIsDone( false, message )
		end

		local ok, pathOrMessage = rendition:waitForRender()
		if not ok then
			if pathOrMessage == nil then
				cancelledRenders = cancelledRenders + 1
				rendition:renditionIsDone( false, 'Export cancelled' )
			else
				fail( 'Render failed: ' .. tostring( pathOrMessage ) )
			end
		else
			local m = meta[ rendition.photo ]
			local uuid = ( m and m.uuid ) or rendition.photo:getRawMetadata( 'uuid' )
			local i = indexByUuid[ uuid ]
			if not i then
				fail( 'Rendered a photo that was not in the export list.' )
			elseif takenBy[ i ] then
				fail( 'Two photos claim the same destination number ' .. i .. '.' )
			else
				takenBy[ i ] = true
				local dest = LrPathUtils.child( albumDir, Slug.fileName( slug, i, numbering ) )
				LrFileUtils.move( pathOrMessage, dest )

				if not LrFileUtils.exists( dest ) then
					LrFileUtils.copy( pathOrMessage, dest )
					if LrFileUtils.exists( dest ) then LrFileUtils.delete( pathOrMessage ) end
				end

				if LrFileUtils.exists( dest ) then
					written = written + 1
				else
					fail( 'Could not place ' .. dest )
				end
			end
		end
	end
	if written < total then return end
	local action, contents, indexNotes = FrontMatter.plan( existing, album )
	if contents then
		writeFile( LrPathUtils.child( albumDir, 'index.md' ), contents )
	end
	log:info( 'index.md: ' .. action )
	succeeded = true

	local summary = {}
	if existing then
		summary[ #summary + 1 ] = string.format( '%d photos added to %s/, which now holds %d.',
			written, Repo.albumRelPath( slug ), existing.count + written )
		summary[ #summary + 1 ] = 'They are numbered from '
			.. Slug.fileName( slug, 1, numbering ) .. '.'
		if numbering.widthGrew then
			summary[ #summary + 1 ] = 'Warning: the new names need an extra digit, so under '
				.. 'sort_by: Name they sort before the older ones. Renaming the album by hand '
				.. 'is the only fix.'
		end
	else
		summary[ #summary + 1 ] = string.format( '%d photos written to %s/',
			written, Repo.albumRelPath( slug ) )
	end
	for _, note in ipairs( indexNotes ) do summary[ #summary + 1 ] = note end

	if not existing and not album.cover then
		summary[ #summary + 1 ] = 'No cover matched - Hugo will use the first photo.'
	end

	if Prefs.get( 'writeCoordinates' ) and not album.lat then
		summary[ #summary + 1 ] = 'No coordinates - lat/lng were left out.'
	end

	if branchName then
		local ok, output, status, command
		if not useExistingBranch then
			ok, output, status, command = Repo.git( repoPath, { 'checkout', '-b', branchName } )
		else
			ok, output, status, command = Repo.git( repoPath, { 'checkout', branchName } )
		end

		local checkedOut = ok
		if ok then
			local verb = existing and 'Update ' or 'Add '
			ok, output, status, command = Repo.commitAlbum( repoPath, Repo.albumRelPath( slug ),
				verb .. album.title )
		end

		if ok then
			summary[ #summary + 1 ] = 'Committed on ' .. branchName .. '.'
			summary[ #summary + 1 ] = ''
			summary[ #summary + 1 ] = 'Next: preview the site, then'
			summary[ #summary + 1 ] = '  git push -u origin ' .. branchName
		else
			LrDialogs.message( 'Commit refused',
				output ~= '' and output
					or string.format( 'git exited with status %s and said nothing.\n\n%s',
						tostring( status ), tostring( command ) ),
				'critical' )
			summary[ #summary + 1 ] = checkedOut
				and ( 'The git step failed - the files are on disk, on branch ' .. branchName .. '.' )
				or ( 'The git step failed before switching branch - the files are on disk, '
					.. 'on whatever branch you were already on.' )
		end
	else
		summary[ #summary + 1 ] = ''
		summary[ #summary + 1 ] = 'Next: preview the site, then commit '
			.. Repo.albumRelPath( slug ) .. '.'
	end

	LrDialogs.message( 'Album ' .. slug .. ( existing and ' updated' or ' created' ),
		table.concat( summary, '\n' ), 'info' )
end

return provider
