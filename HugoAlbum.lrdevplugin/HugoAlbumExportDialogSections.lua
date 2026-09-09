--[[
The "Hugo Album" section of the Export dialog: everything that ends up in the
front matter, plus live validation and a preview of the filenames that will be
written.
]]

local LrApplication = import 'LrApplication'
local LrHttp        = import 'LrHttp'
local LrColor       = import 'LrColor'
local LrTasks       = import 'LrTasks'
local LrView        = import 'LrView'

local Coords      = require 'HugoAlbumCoords'
local FrontMatter = require 'HugoAlbumFrontMatter'
local Metadata    = require 'HugoAlbumMetadata'
local Prefs       = require 'HugoAlbumPrefs'
local Repo        = require 'HugoAlbumRepo'
local Slug        = require 'HugoAlbumSlug'
local log         = require 'HugoAlbumLog'

local Sections = {}

-- Dialog-lifetime scratch state. Not on the property table: it holds LrPhoto
-- objects and a resolved-metadata cache, neither of which belongs in a saved
-- export preset. Only one export dialog exists at a time in practice.
-- `autoFilled` records what the last auto-fill wrote, so a later recompute can
-- tell an untouched field from one the user typed into and leave the latter be.
local state = {
	photos = {}, ordered = {}, resolved = nil, autoFilled = {},
	-- The catalog, read once when the selection is loaded. Changing the cover
	-- rule or the order then costs no catalog access at all.
	meta = {},
	-- Cached result of Repo.validatePaths. The file system can only be touched
	-- from a task, but LR_cantExportBecause has to be recomputed synchronously
	-- on every keystroke, so the IO half is cached here and refreshed whenever
	-- the repo path or the slug changes.
	repoProblem = 'Checking the site folder...',
	albumExists = false,
}

Sections.exportPresetFields = {
	{ key = 'albumTitle',   default = '' },
	{ key = 'slug',         default = '' },
	{ key = 'slugManual',   default = false },
	{ key = 'description',  default = '' },
	{ key = 'categories',   default = '' },
	{ key = 'albumDate',    default = '' },
	{ key = 'location',     default = '' },
	{ key = 'coverRule',    default = 'rating' },
	{ key = 'coverLabel',   default = 'red' },
	{ key = 'coverPosition', default = 1 },
	{ key = 'sequenceBy',   default = 'lightroom' },
	{ key = 'updateExisting', default = false },
	{ key = 'doGit',        default = true },
	{ key = 'branchName',   default = '' },
	{ key = 'branchManual', default = false },
}

--------------------------------------------------------------------------------

-- Writes an auto-filled value only into a field the user has not edited: blank,
-- or still holding whatever the previous auto-fill put there.
local function prefill( propertyTable, key, value )
	-- nil means "no suggestion", which is not the same as "make it empty". Passing
	-- nil used to blank the field, so unticking the append box - or a keystroke
	-- that changed the slug - wiped the date and dimmed Export with
	-- "Date must be YYYY-MM-DD" and no way back.
	if value == nil then return end

	local current = propertyTable[ key ]
	if current == '' or current == state.autoFilled[ key ] then
		propertyTable[ key ] = value
		state.autoFilled[ key ] = value
	end
end

-- Re-reads the catalog. Only called when the selection or a photo-dependent
-- setting changes, not on every keystroke.
local function recomputeFromPhotos( propertyTable )
	state.ordered = Metadata.sortPhotos( state.photos, propertyTable.sequenceBy, state.meta )
	state.resolved = Metadata.resolve( state.ordered, propertyTable, state.meta )

	-- The dates the selection actually spans, newest last, plus today. There is
	-- no calendar widget in LrView, and for this job a menu of the real shoot
	-- dates beats one anyway - it is almost always one of them.
	propertyTable.dateChoices = state.resolved.dates

	prefill( propertyTable, 'albumDate', state.resolved.date )
	prefill( propertyTable, 'location',
		Coords.format( state.resolved.lat, state.resolved.lng ) )
end

local function previewText( propertyTable )
	local n = #state.ordered
	if n == 0 then return 'No photos selected.' end

	local slug = propertyTable.slug
	if not Slug.isValid( slug ) then
		return n .. ' photos - enter a title to see the filenames.'
	end

	local repoPath = Repo.configuredPath()
	local existing = state.existing
	local numbering = Slug.numbering( n, propertyTable.updateExisting and existing or nil )

	local lines = {
		string.format( '%d photos: %s ... %s', n,
			Slug.fileName( slug, 1, numbering ), Slug.fileName( slug, n, numbering ) ),
		-- The repo is set in the Plug-in Manager and not shown above, so name
		-- the destination here rather than leaving it to be assumed.
		'Into ' .. ( repoPath ~= '' and ( repoPath .. '/' .. Repo.albumRelPath( slug ) .. '/' ) or '?' ),
	}

	if existing then
		local was = existing.values and existing.values.title
		local what = string.format( '%d photos%s', existing.count,
			was and ( ', currently titled "' .. was .. '"' ) or '' )
		lines[ #lines + 1 ] = propertyTable.updateExisting
			and ( 'Adding to an existing album of ' .. what .. '.' )
			or ( 'That album already exists (' .. what .. ').' )
		if numbering.widthGrew then
			lines[ #lines + 1 ] = 'Warning: past ' .. string.rep( '9', numbering.width - 1 )
				.. ' the filenames need another digit, which breaks sort_by: Name.'
		end

		-- Naming them here is the difference between "your description was
		-- ignored" and "the plugin ate my description".
		local unmanaged = existing.values and existing.values.unmanaged
		if propertyTable.updateExisting and unmanaged then
			local names = {}
			for key in pairs( unmanaged ) do names[ #names + 1 ] = key end
			table.sort( names )
			if #names > 0 then
				lines[ #lines + 1 ] = 'Multi-line in index.md, so left exactly as they are: '
					.. table.concat( names, ', ' ) .. '.'
			end
		end
	end

	local r = state.resolved
	if propertyTable.updateExisting and existing then
		-- The cover rule only ever runs over the photos being added, so applying
		-- it to an album that already has one would promote a newcomer. An
		-- existing album keeps whatever cover it has; change it in the file.
		lines[ #lines + 1 ] = 'Cover: unchanged - an existing album keeps its own.'
	elseif r then
		if r.coverIndex then
			local extra = r.coverCount > 1
				and string.format( ' (%d matched, first wins)', r.coverCount ) or ''
			lines[ #lines + 1 ] = 'Cover: ' .. Slug.fileName( slug, r.coverIndex, numbering ) .. extra
		elseif propertyTable.coverRule == 'position' then
			local wanted = tonumber( propertyTable.coverPosition )
			lines[ #lines + 1 ] = wanted
				and string.format( 'Cover: photo %d, but only %d selected - Hugo will use the first.',
					wanted, n )
				or 'Cover: that is not a photo number - Hugo will use the first photo.'
		elseif propertyTable.coverRule == 'rating' then
			lines[ #lines + 1 ] = 'Cover: nothing rated - Hugo will use the first photo.'
		else
			lines[ #lines + 1 ] = 'Cover: none matched - Hugo will use the first photo.'
		end
	end

	if Prefs.get( 'writeCoordinates' ) and not Coords.parse( propertyTable.location ) then
		lines[ #lines + 1 ] = 'No coordinates - lat/lng will be left out.'
	end

	return table.concat( lines, '\n' )
end

-- Observers can set the very keys they watch (slug follows the title), so guard
-- against re-entering while a pass is in flight.
local updating = false

-- Synchronous and catalog-free: safe to call straight from an observer.
local function update( propertyTable )
	if updating then return end
	updating = true

	if not propertyTable.slugManual then
		propertyTable.slug = Slug.slugify( propertyTable.albumTitle )
	end
	if not propertyTable.branchManual then
		propertyTable.branchName = propertyTable.slug ~= '' and ( 'album/' .. propertyTable.slug ) or ''
	end

	-- The documented way to block an export: Lightroom dims the Export button
	-- and shows this string under it. nil re-enables.
	--
	-- Display order: a bad repo path outranks a missing title, but an existing
	-- an existing album folder only means anything once the slug is valid.
	-- Appending to an album that is already there is never something to arrive at
	-- by accident, so it stays blocked until the box is ticked for that album.
	propertyTable.albumExists = state.albumExists == true
	propertyTable.LR_cantExportBecause = state.repoProblem
		or Repo.validateFields( propertyTable )
		or ( state.albumExists and not propertyTable.updateExisting
			and ( Repo.albumRelPath( propertyTable.slug )
				.. ' already exists. Tick "Add to the existing album", or change the title.' ) )
		or nil
	local lat, lng = Coords.parse( propertyTable.location )
	propertyTable.hasLocation = lat ~= nil
	propertyTable.locationEcho = lat and ( 'Pin at ' .. Coords.format( lat, lng ) ) or ''

	propertyTable.previewText = previewText( propertyTable )

	updating = false
end

--[[
Reading the catalog can yield, and neither startDialog nor a property observer
is allowed to: an observer runs inside the property table's assignment
metamethod, and Lua 5.1 cannot yield across a C boundary at all. Doing the work
in a task is the only way to touch the catalog from here.

This is what "Yielding is not allowed within a C or metamethod call" means when
it comes out of the Export dialog.
]]
local function refresh( propertyTable )
	LrTasks.startAsyncTask( function()
		recomputeFromPhotos( propertyTable )
		update( propertyTable )
	end )
end

-- Same reason: Repo.validatePaths stats the file system.
--[[
Copies an existing album's metadata into the dialog, or takes it back out again.

Only ever runs on an explicit tick of "Add to the existing album". Doing it
automatically was wrong: typing "Dolomites New" passes through the exact slug
"dolomites" on the way, and the dialog would quietly absorb that album's date,
description and categories into what is meant to be a new one.

The title is never copied. The album is found BY the slug and the slug derives
from the title, so writing the file's title back into the field could point at a
different album and oscillate. The typed title wins, which is also how an album
is retitled; the preview names the current one so the change stays visible.
]]
local function applyExistingValues( propertyTable )
	local values = propertyTable.updateExisting and state.existing and state.existing.values
	local resolved = state.resolved

	if values then
		prefill( propertyTable, 'albumDate', values.date )
		prefill( propertyTable, 'description', values.description )
		prefill( propertyTable, 'categories', values.categories )
		if values.lat and values.lng then
			prefill( propertyTable, 'location', Coords.format( values.lat, values.lng ) )
		end
	else
		-- Back to what the photos themselves say, not to empty. Only fields the
		-- user has not touched move, because that is what prefill guarantees.
		prefill( propertyTable, 'albumDate', resolved and resolved.date )
		if resolved and resolved.lat then
			prefill( propertyTable, 'location', Coords.format( resolved.lat, resolved.lng ) )
		end
	end
end

local function refreshPaths( propertyTable )
	-- The slug this run is about. Everything below works from the snapshot, never
	-- from the live property, because the user goes on typing while it runs.
	local wanted = propertyTable.slug
	local snapshot = { slug = wanted }

	LrTasks.startAsyncTask( function()
		local problem, exists = Repo.validatePaths( snapshot )

		local existing
		if exists then
			existing = Repo.inspectAlbum( Repo.configuredPath(), wanted )
			if existing and existing.index then
				existing.values = FrontMatter.readValues( existing.index )
			end
		end

		-- Another keystroke may have landed while the file system was being read.
		-- Its own task owns the state now; finishing this one would leave the
		-- dialog describing an album the user has already typed past - including
		-- a photo count that would start the numbering in the wrong place.
		if propertyTable.slug ~= wanted then return end

		state.repoProblem, state.albumExists, state.existing = problem, exists, existing
		update( propertyTable )
	end )
end

--------------------------------------------------------------------------------

function Sections.startDialog( propertyTable )
	-- Per-album fields are cleared so the previous export's title can never be
	-- carried silently into the next one. Categories survive: "travel" is
	-- usually the same album to album.
	propertyTable.albumTitle = ''
	propertyTable.slug = ''
	propertyTable.slugManual = false
	propertyTable.description = ''
	propertyTable.branchManual = false
	propertyTable.previewText = ''

	-- Cleared before the first prefill: values carried over in the export preset
	-- describe the previous album, so they must not be mistaken for edits to
	-- this one.
	propertyTable.albumDate, propertyTable.location = '', ''
	propertyTable.hasLocation, propertyTable.locationEcho = false, ''
	propertyTable.updateExisting, propertyTable.albumExists = false, false
	state.autoFilled = {}

	propertyTable.dateChoices = {}   -- filled once the catalog has been read

	-- `state` outlives a single dialog, so reset the cached verdict too: a stale
	-- "repo is fine" from last time would briefly enable the Export button.
	state.photos, state.ordered, state.resolved, state.meta = {}, {}, nil, {}
	state.existing = nil
	state.repoProblem, state.albumExists = 'Checking the repo...', false

	update( propertyTable )   -- valid state immediately; the preview fills in below

	for _, key in ipairs { 'albumTitle', 'branchName', 'albumDate', 'location',
		'slugManual', 'branchManual' } do
		propertyTable:addObserver( key, function() update( propertyTable ) end )
	end
	-- The slug decides where the album would land, so it needs the file-system
	-- checks redone. The repo itself is fixed for the session - it is set in the
	-- Plug-in Manager, not here.
	propertyTable:addObserver( 'slug', function()
		-- Consent is per album: a different slug is a different decision.
		propertyTable.updateExisting = false
		refreshPaths( propertyTable )
	end )
	propertyTable:addObserver( 'updateExisting', function()
		applyExistingValues( propertyTable )
		update( propertyTable )
	end )
	for _, key in ipairs { 'coverRule', 'coverLabel', 'coverPosition', 'sequenceBy' } do
		propertyTable:addObserver( key, function() refresh( propertyTable ) end )
	end

	-- getTargetPhotos() is the catalog's target set at dialog time. Normally
	-- identical to what gets exported, but it is only used for the preview -
	-- processRenderedPhotos recomputes everything authoritatively.
	--
	-- Note the LrTasks.pcall: plain pcall is a C call, and a yield inside one is
	-- exactly the error this whole arrangement exists to avoid.
	LrTasks.startAsyncTask( function()
		local ok, photos = LrTasks.pcall( function()
			return LrApplication.activeCatalog():getTargetPhotos()
		end )
		state.photos = ok and photos or {}
		if not ok then log:error( 'getTargetPhotos failed: ' .. tostring( photos ) ) end
		state.meta = Metadata.read( state.photos )
		log:info( 'dialog opened with ' .. #state.photos .. ' target photos' )

		state.repoProblem, state.albumExists = Repo.validatePaths( propertyTable )
		recomputeFromPhotos( propertyTable )
		update( propertyTable )
	end )
end

--------------------------------------------------------------------------------

function Sections.sectionsForTopOfDialog( f, propertyTable )
	local bind = LrView.bind
	local share = LrView.share

	-- lat/lng are not part of hugo-theme-gallery, so the whole row only exists
	-- on a site that has said it has a map layout reading them. Built as a
	-- conditional rather than bound to `visible`: that property is not bindable,
	-- and layout containers like f:row do not accept it at all. Deciding here is
	-- enough, since the setting lives in the Plug-in Manager and cannot change
	-- while this dialog is open.
	local locationRows = f:spacer { height = 0 }
	if Prefs.get( 'writeCoordinates' ) then
		locationRows = f:column {
			fill_horizontal = 1,
			f:row {
				f:static_text { title = 'Location:', alignment = 'right', width = share 'label_width' },
				f:edit_field {
					value = bind 'location',
					immediate = true,
					fill_horizontal = 1,
					tooltip = '"45.4408, 12.3155" or 46°32\'25.8"N 12°08\'08.5"E. Prefilled '
						.. 'from the photos\' GPS when they have any. Leave empty to write no '
						.. 'coordinates.',
				},
				f:push_button {
					title = 'Show on map',
					enabled = bind 'hasLocation',
					action = function()
						local lat, lng = Coords.parse( propertyTable.location )
						if lat then LrHttp.openUrlInBrowser( Coords.mapUrl( lat, lng ) ) end
					end,
				},
			},
			f:row {
				f:static_text { title = '', width = share 'label_width' },
				f:static_text {
					title = bind 'locationEcho',
					fill_horizontal = 1,
					text_color = LrColor( 0.4, 0.4, 0.4 ),
				},
			},
		}
	end

	local function row( label, control )
		return f:row {
			f:static_text { title = label, alignment = 'right', width = share 'label_width' },
			control,
		}
	end

	return {
		{
			title = 'Hugo Album',
			synopsis = bind 'slug',

			row( 'Title:', f:edit_field {
				value = bind 'albumTitle', immediate = true, fill_horizontal = 1,
			} ),

			f:row {
				f:static_text { title = 'Slug:', alignment = 'right', width = share 'label_width' },
				f:edit_field {
					value = bind 'slug',
					enabled = bind 'slugManual',
					immediate = true,
					width_in_chars = 24,
					tooltip = 'Directory name inside the albums folder, and the stem of every filename.',
				},
				f:checkbox {
					title = 'Edit manually',
					value = bind 'slugManual',
					tooltip = 'Off: the slug follows the title.',
				},
			},

			f:row {
				f:static_text { title = '', width = share 'label_width' },
				f:checkbox {
					title = 'Add to the existing album',
					value = bind 'updateExisting',
					enabled = bind 'albumExists',
					tooltip = 'Appends the photos and merges index.md instead of refusing. '
						.. 'Clears itself whenever the slug changes, so consent is never '
						.. 'carried from one album to another.',
				},
			},

			row( 'Description:', f:edit_field {
				value = bind 'description', immediate = true, fill_horizontal = 1, height_in_lines = 2,
			} ),

			row( 'Categories:', f:edit_field {
				value = bind 'categories',
				immediate = true,
				fill_horizontal = 1,
				tooltip = 'Comma separated, e.g. travel, 2026',
			} ),

			f:row {
				f:static_text { title = 'Date:', alignment = 'right', width = share 'label_width' },
				f:combo_box {
					value = bind 'albumDate',
					items = bind 'dateChoices',
					immediate = true,
					width_in_chars = 12,
					tooltip = 'Pick a capture date from the selection, or type any YYYY-MM-DD.',
				},
			},

			locationRows,

			f:separator { fill_horizontal = 1 },

			f:row {
				f:static_text { title = 'Cover:', alignment = 'right', width = share 'label_width' },
				f:popup_menu {
					value = bind 'coverRule',
					items = {
						{ title = 'Highest star rating', value = 'rating' },
						{ title = 'Colour label', value = 'label' },
						{ title = 'Flagged as pick', value = 'flag' },
						{ title = 'First photo', value = 'first' },
						{ title = 'Last photo', value = 'last' },
						{ title = 'Photo number', value = 'position' },
					},
				},
				-- Each rule's own control sits next to it, live only for that rule.
				f:popup_menu {
					value = bind 'coverLabel',
					enabled = bind { key = 'coverRule', transform = function( v ) return v == 'label' end },
					items = {
						{ title = 'Red', value = 'red' }, { title = 'Yellow', value = 'yellow' },
						{ title = 'Green', value = 'green' }, { title = 'Blue', value = 'blue' },
						{ title = 'Purple', value = 'purple' },
					},
				},
				f:edit_field {
					value = bind 'coverPosition',
					enabled = bind { key = 'coverRule', transform = function( v ) return v == 'position' end },
					immediate = true,
					width_in_chars = 4,
					tooltip = 'Counted in the export order set below.',
				},
			},

			row( 'Order:', f:popup_menu {
				value = bind 'sequenceBy',
				items = {
					{ title = 'Lightroom order', value = 'lightroom' },
					{ title = 'Capture time', value = 'capture' },
					{ title = 'Filename', value = 'filename' },
				},
			} ),

			f:separator { fill_horizontal = 1 },

			f:row {
				f:static_text { title = 'Git:', alignment = 'right', width = share 'label_width' },
				f:checkbox { title = 'Create branch and commit', value = bind 'doGit' },
			},
			f:row {
				f:static_text { title = 'Branch:', alignment = 'right', width = share 'label_width' },
				f:edit_field {
					value = bind 'branchName',
					-- Editable only when both the git step is on and the user has
					-- taken the name off auto.
					enabled = bind {
						keys = { 'doGit', 'branchManual' },
						operation = function( _, values )
							return values.doGit and values.branchManual
						end,
					},
					immediate = true,
					width_in_chars = 22,
				},
			},
			f:row {
				f:static_text { title = '', width = share 'label_width' },
				f:checkbox {
					title = 'Edit branch name manually',
					value = bind 'branchManual',
					enabled = bind 'doGit',
					tooltip = 'Off: the branch follows the slug.',
				},
			},
			f:row {
				f:static_text { title = '', width = share 'label_width' },
				f:static_text {
					title = 'Nothing is pushed - push to main is the deploy.',
					text_color = LrColor( 0.4, 0.4, 0.4 ),
				},
			},

			f:separator { fill_horizontal = 1 },

			f:row {
				f:static_text {
					title = bind 'previewText',
					fill_horizontal = 1,
					-- previewText emits at most seven lines and the destination
					-- path wraps on its own. Too small a value clips silently, and
					-- what got clipped was the Cover line and the warning that the
					-- album's sort order is about to break.
					height_in_lines = 8,
				},
			},
		},
	}
end

return Sections
