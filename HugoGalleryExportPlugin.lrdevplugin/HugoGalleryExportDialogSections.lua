local LrApplication = import 'LrApplication'
local LrHttp        = import 'LrHttp'
local LrColor       = import 'LrColor'
local LrTasks       = import 'LrTasks'
local LrView        = import 'LrView'

local Coords      = require 'HugoGalleryCoords'
local FrontMatter = require 'HugoGalleryFrontMatter'
local Metadata    = require 'HugoGalleryMetadata'
local Prefs       = require 'HugoGalleryPrefs'
local Repo        = require 'HugoGalleryRepo'
local Slug        = require 'HugoGallerySlug'
local log         = require 'HugoGalleryLog'

local Sections = {}

local state = {
	photos = {}, ordered = {}, resolved = nil, autoFilled = {},
	meta = {},
	repoProblem = 'Checking the site folder...',
	albumExists = false,
}

Sections.exportPresetFields = {
	{ key = 'albumTitle',   default = '' },
	{ key = 'slug',         default = '' },
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

local function prefill( propertyTable, key, value )
	if value == nil then return end
	local current = propertyTable[ key ]
	if current == '' or current == state.autoFilled[ key ] then
		propertyTable[ key ] = value
		state.autoFilled[ key ] = value
	end
end

local function recomputeFromPhotos( propertyTable )
	state.ordered = Metadata.sortPhotos( state.photos, propertyTable.sequenceBy, state.meta )
	state.resolved = Metadata.resolve( state.ordered, propertyTable, state.meta )
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

local updating = false

local function update( propertyTable )
	if updating then return end
	updating = true

	prefill( propertyTable, 'albumTitle', Slug.titleFromSlug( propertyTable.slug ) )

	if not propertyTable.branchManual then
		propertyTable.branchName = propertyTable.slug ~= '' and ( 'album/' .. propertyTable.slug ) or ''
	end

	propertyTable.albumExists = state.albumExists == true
	propertyTable.LR_cantExportBecause = state.repoProblem
		or Repo.validateFields( propertyTable )
		or ( state.albumExists and not propertyTable.updateExisting
			and ( Repo.albumRelPath( propertyTable.slug )
				.. ' already exists. Tick "Add to the existing album", or change the slug.' ) )
		or nil
	local lat, lng = Coords.parse( propertyTable.location )
	propertyTable.hasLocation = lat ~= nil
	propertyTable.locationEcho = lat and ( 'Pin at ' .. Coords.format( lat, lng ) ) or ''

	propertyTable.previewText = previewText( propertyTable )

	updating = false
end

local function refresh( propertyTable )
	LrTasks.startAsyncTask( function()
		recomputeFromPhotos( propertyTable )
		update( propertyTable )
	end )
end

local function applyExistingValues( propertyTable )
	local values = propertyTable.updateExisting and state.existing and state.existing.values
	local resolved = state.resolved

	if values then
		prefill( propertyTable, 'albumTitle', values.title )
		prefill( propertyTable, 'albumDate', values.date )
		prefill( propertyTable, 'description', values.description )
		prefill( propertyTable, 'categories', values.categories )
		if values.lat and values.lng then
			prefill( propertyTable, 'location', Coords.format( values.lat, values.lng ) )
		end
	else
		prefill( propertyTable, 'albumTitle', Slug.titleFromSlug( propertyTable.slug ) )
		prefill( propertyTable, 'albumDate', resolved and resolved.date )
		if resolved and resolved.lat then
			prefill( propertyTable, 'location', Coords.format( resolved.lat, resolved.lng ) )
		end
	end
end

local function refreshPaths( propertyTable )
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

		if propertyTable.slug ~= wanted then return end

		state.repoProblem, state.albumExists, state.existing = problem, exists, existing
		update( propertyTable )
	end )
end

--------------------------------------------------------------------------------

function Sections.startDialog( propertyTable )
	propertyTable.albumTitle = ''
	propertyTable.slug = ''
	propertyTable.description = ''
	propertyTable.branchManual = false
	propertyTable.previewText = ''
	propertyTable.albumDate, propertyTable.location = '', ''
	propertyTable.hasLocation, propertyTable.locationEcho = false, ''
	propertyTable.updateExisting, propertyTable.albumExists = false, false
	state.autoFilled = {}
	propertyTable.dateChoices = {}
	state.photos, state.ordered, state.resolved, state.meta = {}, {}, nil, {}
	state.existing = nil
	state.repoProblem, state.albumExists = 'Checking the repo...', false

	update( propertyTable )

	for _, key in ipairs { 'albumTitle', 'branchName', 'albumDate', 'location',
		'branchManual' } do
		propertyTable:addObserver( key, function() update( propertyTable ) end )
	end

	propertyTable:addObserver( 'slug', function()
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
			f:spacer { height = 4 },
			f:row {
				f:static_text { title = '', width = share 'label_width' },
				f:static_text {
					title = bind 'locationEcho',
					fill_horizontal = 1,
					text_color = LrColor( 0.4, 0.4, 0.4 ),
				},
			},
			f:spacer { height = 8 },
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
			title = 'Hugo Gallery',
			synopsis = bind 'slug',

			f:row {
				f:static_text { title = 'Slug:', alignment = 'right', width = share 'label_width' },
				f:edit_field {
					value = bind 'slug',
					immediate = true,
					width_in_chars = 24,
					tooltip = 'Lowercase letters, digits and hyphens. Names the album folder and '
						.. 'every file in it. Type the slug of an album that already exists to '
						.. 'add to it.',
				},
			},
			f:row {
				f:static_text { title = '', width = share 'label_width' },
				f:static_text {
					title = 'names the folder, and finds an album that already exists',
					text_color = LrColor( 0.4, 0.4, 0.4 ),
				},
			},

			f:row {
				f:static_text { title = 'Title:', alignment = 'right', width = share 'label_width' },
				f:edit_field {
					value = bind 'albumTitle',
					immediate = true,
					fill_horizontal = 1,
					tooltip = 'Follows the slug until you type your own - "test-hello" gives '
						.. '"Test Hello". An album that already exists brings its own title.',
				},
			},

			f:row {
				f:static_text { title = '', width = share 'label_width' },
				f:checkbox {
					title = 'Add to the existing album',
					value = bind 'updateExisting',
					enabled = bind 'albumExists',
					tooltip = 'Appends the photos and merges index.md instead of refusing. '
						.. 'Pins the slug, so the title becomes free to edit - that is how you '
						.. 'retitle an album. Clears itself whenever the slug changes, so '
						.. 'consent is never carried from one album to another.',
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
					height_in_lines = 8,
				},
			},
		},
	}
end

return Sections
