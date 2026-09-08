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
	{ key = 'coverRule',    default = 'label' },
	{ key = 'coverLabel',   default = 'red' },
	{ key = 'coverPosition', default = 1 },
	{ key = 'sequenceBy',   default = 'lightroom' },
	{ key = 'doGit',        default = true },
	{ key = 'branchName',   default = '' },
	{ key = 'branchManual', default = false },
}

--------------------------------------------------------------------------------

-- Writes an auto-filled value only into a field the user has not edited: blank,
-- or still holding whatever the previous auto-fill put there.
local function prefill( propertyTable, key, value )
	local current = propertyTable[ key ]
	if current == '' or current == state.autoFilled[ key ] then
		propertyTable[ key ] = value
		state.autoFilled[ key ] = value
	end
end

-- Re-reads the catalog. Only called when the selection or a photo-dependent
-- setting changes, not on every keystroke.
local function recomputeFromPhotos( propertyTable )
	state.ordered = Metadata.sortPhotos( state.photos, propertyTable.sequenceBy )
	state.resolved = Metadata.resolve( state.ordered, propertyTable )

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
	local lines = {
		string.format( '%d photos: %s ... %s', n,
			Slug.fileName( slug, 1, n ), Slug.fileName( slug, n, n ) ),
		-- The repo is set in the Plug-in Manager and not shown above, so name
		-- the destination here rather than leaving it to be assumed.
		'Into ' .. ( repoPath ~= '' and ( repoPath .. '/' .. Repo.albumRelPath( slug ) .. '/' ) or '?' ),
	}

	local r = state.resolved
	if r then
		if r.coverIndex then
			local extra = r.coverCount > 1
				and string.format( ' (%d matched, first wins)', r.coverCount ) or ''
			lines[ #lines + 1 ] = 'Cover: ' .. Slug.fileName( slug, r.coverIndex, n ) .. extra
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
	propertyTable.LR_cantExportBecause = state.repoProblem
		or Repo.validateFields( propertyTable )
		or ( state.albumExists and ( Repo.albumRelPath( propertyTable.slug ) .. ' already exists.' ) )
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
local function refreshPaths( propertyTable )
	LrTasks.startAsyncTask( function()
		state.repoProblem, state.albumExists = Repo.validatePaths( propertyTable )
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
	state.autoFilled = {}

	propertyTable.dateChoices = {}   -- filled once the catalog has been read

	-- `state` outlives a single dialog, so reset the cached verdict too: a stale
	-- "repo is fine" from last time would briefly enable the Export button.
	state.photos, state.ordered, state.resolved = {}, {}, nil
	state.repoProblem, state.albumExists = 'Checking the repo...', false

	update( propertyTable )   -- valid state immediately; the preview fills in below

	for _, key in ipairs { 'albumTitle', 'branchName', 'albumDate', 'location' } do
		propertyTable:addObserver( key, function() update( propertyTable ) end )
	end
	-- The slug decides where the album would land, so it needs the file-system
	-- checks redone. The repo itself is fixed for the session - it is set in the
	-- Plug-in Manager, not here.
	propertyTable:addObserver( 'slug', function() refreshPaths( propertyTable ) end )
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
					height_in_lines = 3,
				},
			},
		},
	}
end

return Sections
