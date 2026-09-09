--[[
Hugo Gallery export service.

Renders the selected photos at the configured long edge, moves them into
<albums folder>/<slug>/ under sequential names, writes index.md, and optionally
creates a branch and commits. It never pushes: on a git-deployed site pushing is
the deploy, and that stays a deliberate act.
]]

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

-- Every one of these is dictated by the repo, so none of them is the user's to
-- get wrong. Hiding exportLocation additionally makes Lightroom render into a
-- temp directory it deletes once processRenderedPhotos returns - which is
-- exactly the staging area we want, since every file gets renamed on the way
-- into the album folder. LR_export_destinationPathPrefix is never set.
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

	--[[
	The SHORT edge is the constraint, not the long one.

	The album grid is a justified layout: it lays photos out to a common height,
	so how many rows a photo has is what decides whether it looks sharp. A
	long-edge cap gives a 4:1 panorama a quarter of the rows of an ordinary photo
	- 2048x506 against 2048x1365 - and no amount of care further down the line
	puts those rows back.

	Which of maxHeight/maxWidth Lightroom reads for a shortEdge resize is not
	documented. Both are set to the same number, so it cannot matter - that
	equality is load-bearing, not incidental.

	Exporting at the site's own cap means any resize-on-commit step the repo has
	finds nothing left to do, and the downscale comes straight from the RAW
	instead of a second JPEG round through some other tool.
	]]
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

	-- This is what keeps FNumber/ExposureTime/ISO/FocalLength/LensModel/Model
	-- alive - the fields hugo-theme-gallery builds its lightbox caption from
	-- ("35mm - f/4 - 1/1600s - ISO 200"), subject to the site's
	-- [imaging.exif] includeFields.
	-- LR_minimizeEmbeddedMetadata would override this and strip them.
	exportSettings.LR_minimizeEmbeddedMetadata = false
	exportSettings.LR_embeddedMetadataOption   = 'all'
	exportSettings.LR_metadata_keywordOptions  = 'flat'
	-- Publishing a photo's own coordinates is rarely intended, and Hugo's
	-- disableLatLong defaults to hiding them anyway. The album's coordinates are
	-- a separate, deliberate front-matter field.
	exportSettings.LR_removeLocationMetadata = true

	exportSettings.LR_renamingTokensOn      = false   -- we name the files ourselves
	exportSettings.LR_extensionCase         = 'lowercase'
	exportSettings.LR_collisionHandling     = 'overwrite'
	exportSettings.LR_reimportExportedPhoto = false
	exportSettings.LR_includeVideoFiles     = false
	exportSettings.LR_useWatermark          = false
end

--------------------------------------------------------------------------------

--[[
The photos in export order.

Taken from the session's renditions rather than photosToExport() for two
reasons: it is by definition the exact set that will be rendered, and its
iteration form is (index, rendition). photosToExport() yields a BARE photo -
`for photo in ...`, not `for i, photo in ...` - which is easy to write wrongly
and produces a silently empty list rather than an error.
]]
local function collectPhotos( session )
	local photos = {}
	for i, rendition in session:renditions() do
		photos[ i ] = rendition.photo
	end
	return photos
end

-- Bail out. The renditions still have to be consumed or Lightroom waits on an
-- iterator that never finishes.
local function abort( exportContext, message )
	log:error( message )

	-- Report before touching the renditions: if consuming them throws, the user
	-- has still been told what actually went wrong.
	LrDialogs.message( 'Hugo Gallery export cancelled', message, 'critical' )

	-- Iterate the SESSION, not the context. exportContext:renditions() is what
	-- starts the rendering, and skipRender() is illegal once it has - calling it
	-- there fails with "must not be called after exportSession has started
	-- rendering", which then hides the real reason for the abort.
	for _, rendition in exportContext.exportSession:renditions() do
		rendition:skipRender()
	end
end

local function writeFile( path, contents )
	-- Binary mode deliberately: in text mode Lua on Windows turns every \n into
	-- \r\n, so the same album would get different line endings depending on who
	-- exported it. 'wb' keeps the output byte-identical across platforms.
	local handle, err = io.open( path, 'wb' )
	if not handle then
		error( 'Could not write ' .. path .. ': ' .. tostring( err ) )
	end

	-- Both returns are checked. In Lua 5.1 file:write does not raise on failure,
	-- it returns nil plus a message, and a buffered write error commonly only
	-- surfaces at close - so ignoring these is how a full disk produces a
	-- truncated index.md that the export then reports as a success and commits.
	-- Note write returns the HANDLE on success, not true: test `not ok`.
	local ok, writeErr = handle:write( contents )
	local closed, closeErr = handle:close()
	if not ok then
		error( 'Could not write ' .. path .. ': ' .. tostring( writeErr ) )
	end
	if not closed then
		error( 'Could not finish writing ' .. path .. ': ' .. tostring( closeErr ) )
	end
end

-- Picks album/<slug>-2, -3, ... for the case where the obvious name is taken.
local function freeBranchName( repoPath, base )
	for n = 2, 50 do
		local candidate = base .. '-' .. n
		if not Repo.branchExists( repoPath, candidate ) then return candidate end
	end
	return nil
end

--[[
Preflight for the git step, run before anything is rendered so a decision about
branches never has to be made with half an album already on disk.

Returns branchName (possibly changed), or nil to skip the git step entirely.
]]
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
			return alt, false            -- fresh branch album/<slug>-N
		elseif choice == 'ok' then
			return branchName, true      -- 50 suffixes taken; fall back to the existing one
		elseif choice == 'other' then
			return branchName, true   -- existing branch: commit, do not create
		else
			return nil
		end
	end
	return branchName, false
end

--------------------------------------------------------------------------------

function provider.processRenderedPhotos( functionContext, exportContext )
	local settings = exportContext.propertyTable
	local session  = exportContext.exportSession

	local unordered = collectPhotos( session )
	local meta      = Metadata.read( unordered )
	local photos    = Metadata.sortPhotos( unordered, settings.sequenceBy, meta )
	local total     = #photos

	-- Re-validate rather than trusting LR_cantExportBecause: the dialog's checks
	-- ran against getTargetPhotos(), and the album folder could have appeared in
	-- the meantime.
	local problem = Repo.validate( settings )
	if total == 0 then problem = 'No photos to export.' end
	if problem then
		return abort( exportContext, problem )
	end

	local repoPath = Repo.configuredPath()   -- set in the Plug-in Manager
	local slug     = settings.slug
	local albumDir = Repo.albumDir( repoPath, slug )

	-- uuid comes from the batch like everything else, with a per-photo read only
	-- as a fallback: without it, any case where the two rendition iterators hand
	-- back different photo identities turns a saving into a dead export.
	local indexByUuid = {}
	for i, photo in ipairs( photos ) do
		local m = meta[ photo ]
		indexByUuid[ ( m and m.uuid ) or photo:getRawMetadata( 'uuid' ) ] = i
	end

	-- Adding to an album that is already there: continue its numbering rather
	-- than starting over, and keep its index.md rather than replacing it. Only
	-- ever on an explicit tick - validate() has already refused otherwise, and
	-- this second guard means a stale dialog state cannot append by accident.
	local existing = settings.updateExisting and Repo.inspectAlbum( repoPath, slug ) or nil
	local numbering = Slug.numbering( total, existing )

	local resolved = Metadata.resolve( photos, settings, meta )
	local album    = Metadata.merge( settings, resolved, numbering )

	-- An existing album keeps its own cover. Without this, appending to one whose
	-- index.md happens to have no resources block would quietly promote one of
	-- the photos just added - the merge adds the block it finds missing, and the
	-- cover rule only ever ran over the new photos.
	if existing then album.cover = nil end

	-- Git decisions up front, while nothing has been written yet.
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

	--[[
	Tidying up and reporting both live here, because this is the one place that
	runs however the export ends.

	A cancel does not necessarily fall out of the rendition loop and continue: the
	SDK does not say whether `stopIfCanceled` returns or unwinds, and in practice
	nothing after the loop ran - which is why cancelling used to finish in
	silence. A cleanup handler runs on both paths.
	]]
	functionContext:addCleanupHandler( function()
		-- Only ever removes a directory this export created. An album that
		-- existed beforehand is never deleted, however badly the export goes.
		if not succeeded and createdDir and LrFileUtils.exists( albumDir ) then
			log:warn( 'export did not complete - removing ' .. albumDir )
			LrFileUtils.delete( albumDir )
		end

		if succeeded or reported then return end
		reported = true

		local removed = createdDir
			and ( ' ' .. Repo.albumRelPath( slug ) .. ' was removed.' )
			or ( ' The photos already added were left in place.' )

		-- Cancelling makes the render that was in flight fail with no reason
		-- attached; those are counted separately, so what is left in `failures`
		-- is only ever something that actually went wrong.
		local cancelled = #failures == 0
		local message
		if cancelled then
			message = string.format( 'Cancelled after %d of %d photos.%s', written, total, removed )
		else
			message = string.format( 'Wrote %d of %d photos.%s\n\n%s',
				written, total, removed, table.concat( failures, '\n' ) )
		end

		-- Logged before the dialog on purpose: if this line is in the log and no
		-- dialog appeared, the handler ran and the dialog itself was suppressed,
		-- which is a different problem from the handler never running.
		log:warn( string.format( '%s (%d renders stopped without a reason)',
			message, cancelledRenders ) )

		-- 'warning' rather than 'info' for the cancel. A cancelled export showed
		-- nothing at all while this said 'info', where the identical call at
		-- 'critical' had been showing - so the style is the only thing that had
		-- changed, and this is the least alarming one still known to appear.
		local shown, err = LrTasks.pcall( LrDialogs.message,
			'Album ' .. slug .. ' was not completed', message,
			cancelled and 'warning' or 'critical' )
		if not shown then log:error( 'could not show the summary: ' .. tostring( err ) ) end
	end )

	LrFileUtils.createAllDirectories( albumDir )
	createdDir = ( existing == nil )

	exportContext:configureProgress { title = 'Building album ' .. slug }

	--[[
	A rendition that goes wrong is reported to Lightroom and the loop carries on.

	Raising here instead - as this used to - unwinds straight out of
	exportContext:renditions() leaving the remaining renditions unconsumed, which
	is the hang this file warns about at the top. Failures are collected and
	reported once, after the iterator has drained.
	]]
	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		local function fail( message )
			log:error( message )
			failures[ #failures + 1 ] = message
			rendition:renditionIsDone( false, message )
		end

		local ok, pathOrMessage = rendition:waitForRender()
		if not ok then
			if pathOrMessage == nil then
				-- Cancelling is what this looks like from in here: the render in
				-- flight fails and Lightroom gives no reason. Reporting it as
				-- "Render failed: nil" says nothing to anybody.
				cancelledRenders = cancelledRenders + 1
				rendition:renditionIsDone( false, 'Export cancelled' )
			else
				fail( 'Render failed: ' .. tostring( pathOrMessage ) )
			end
		else
			-- Index by uuid, not by the loop counter: renditions do not
			-- necessarily complete in the order the photos were listed.
			local m = meta[ rendition.photo ]
			local uuid = ( m and m.uuid ) or rendition.photo:getRawMetadata( 'uuid' )
			local i = indexByUuid[ uuid ]

			if not i then
				fail( 'Rendered a photo that was not in the export list.' )
			elseif takenBy[ i ] then
				-- Two renditions claiming one destination would overwrite each
				-- other, and `written` counts renditions, so the album would come
				-- out one photo short with nothing to show for it.
				fail( 'Two photos claim the same destination number ' .. i .. '.' )
			else
				takenBy[ i ] = true
				local dest = LrPathUtils.child( albumDir, Slug.fileName( slug, i, numbering ) )

				LrFileUtils.move( pathOrMessage, dest )
				if not LrFileUtils.exists( dest ) then
					-- Safety net for a cross-volume temp directory, where move is a
					-- copy rather than a rename and can fail. Testing the
					-- destination rather than move's return value keeps this correct
					-- whichever convention the SDK follows, and never copies from an
					-- already-consumed source. The delete comes after the check, so
					-- a failed copy does not destroy the only rendered file.
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

	-- Nothing to report here: the cleanup handler owns that, so the message is
	-- the same whether this returns or the loop unwound past it.
	if written < total then return end

	--[[
	index.md last: an abort mid-render then leaves no half-valid page bundle even
	if the cleanup handler somehow does not run.

	What happens to an existing one is decided by FrontMatter.plan, which is pure
	and therefore testable - this is the decision that can destroy a hand-written
	file, so it does not belong inline here.
	]]
	local action, contents, indexNotes = FrontMatter.plan( existing, album )
	if contents then
		writeFile( LrPathUtils.child( albumDir, 'index.md' ), contents )
	end
	log:info( 'index.md: ' .. action )
	succeeded = true

	--------------------------------------------------------------------------

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

	-- In update mode the resources block is preserved, so the cover is whatever
	-- the album already had.
	if not existing and not album.cover then
		summary[ #summary + 1 ] = 'No cover matched - Hugo will use the first photo.'
	end
	-- Only worth mentioning on a site that asked for coordinates in the first
	-- place; everywhere else their absence is simply normal.
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
			-- Most likely one of the repo's own pre-commit hooks refusing the
			-- photos; its message already says what to do. The branch and the
			-- staged files are deliberately left in place to be finished in a
			-- terminal.
			-- git's own message is the useful part - a refusing pre-commit hook
			-- says exactly what to do. When there is none, the command line and
			-- the exit status beat "git failed with no output".
			LrDialogs.message( 'Commit refused',
				output ~= '' and output
					or string.format( 'git exited with status %s and said nothing.\n\n%s',
						tostring( status ), tostring( command ) ),
				'critical' )
			-- Which of the three steps failed decides what is true afterwards.
			-- Saying "staged on <branch>" after a failed checkout is the opposite
			-- of what happened, and the checkout is very reachable: it refuses
			-- when local changes conflict, which the dirty-repo dialog said was
			-- fine to continue with.
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
