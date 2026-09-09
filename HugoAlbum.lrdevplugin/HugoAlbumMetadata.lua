--[[
Reads the album's front-matter values out of the Lightroom catalog: capture
date, GPS, and which photo is the cover.

Read-only throughout - nothing here needs catalog write access.
]]

local LrApplication = import 'LrApplication'
local LrDate        = import 'LrDate'
local LrPathUtils   = import 'LrPathUtils'
local LrTasks       = import 'LrTasks'

local Coords      = require 'HugoAlbumCoords'
local FrontMatter = require 'HugoAlbumFrontMatter'
local Prefs       = require 'HugoAlbumPrefs'
local Slug        = require 'HugoAlbumSlug'
local log         = require 'HugoAlbumLog'

local Metadata = {}

-- dateTimeOriginal is NOT a Unix timestamp: it counts seconds from
-- 2001-01-01 UTC, so os.date on it is ~31 years wrong. The ISO8601 variant
-- sidesteps the arithmetic entirely, and LrDate.timeToIsoDate handles the
-- fallback correctly.
--[[
Everything the album needs from the catalog, read once for the whole selection.

Every field below used to be fetched per photo, and the sort comparator fetched
two of them on every comparison - O(n log n) trips into the catalog where O(n)
does. One batch call replaces all of it, which also means changing the cover rule
in the dialog needs no catalog access at all.

Falls back to per-photo reads if the batch call is unavailable: this is the one
place where a single unsupported key would otherwise take the whole dialog down.
]]
-- Raw keys only. `fileName` is formatted-only and raises "Unknown key" here;
-- the raw equivalent is `path`, from which the leaf name is taken below.
local KEYS = {
	'dateTimeOriginalISO8601', 'dateTimeOriginal', 'path',
	'rating', 'pickStatus', 'colorNameForLabel', 'gps', 'uuid',
}

function Metadata.read( photos )
	local catalog = LrApplication.activeCatalog()
	local ok, batch = LrTasks.pcall( catalog.batchGetRawMetadata, catalog, photos, KEYS )
	if ok and type( batch ) == 'table' then return batch end

	log:warn( 'batchGetRawMetadata unavailable, falling back to per-photo reads: '
		.. tostring( batch ) )
	-- Per key, not per photo, and tolerant: getRawMetadata raises on a key it does
	-- not know, and a fallback that dies of the same cause as the batch call is
	-- no fallback at all. A key that fails leaves its field nil and says so once.
	local usable = {}
	for _, key in ipairs( KEYS ) do
		local readable = LrTasks.pcall( function()
			return photos[ 1 ] and photos[ 1 ]:getRawMetadata( key )
		end )
		if readable then
			usable[ #usable + 1 ] = key
		else
			log:error( 'unusable metadata key, skipping: ' .. key )
		end
	end

	local meta = {}
	for _, photo in ipairs( photos ) do
		local one = {}
		for _, key in ipairs( usable ) do one[ key ] = photo:getRawMetadata( key ) end
		meta[ photo ] = one
	end
	return meta
end

local function captureDate( m )
	local iso = m and m.dateTimeOriginalISO8601
	if type( iso ) == 'string' and #iso >= 10 then
		return iso:sub( 1, 10 )
	end
	if type( m and m.dateTimeOriginal ) == 'number' then
		return LrDate.timeToIsoDate( m.dateTimeOriginal )
	end
	return nil
end

-- Sort helpers for the `sequenceBy` setting. photosToExport() order is what the
-- filmstrip shows, which is normally what you want - but it is not documented,
-- hence the two explicit alternatives.
--
-- Returns a new list rather than sorting in place: the caller keeps the
-- original order, so switching the dialog back to 'lightroom' can restore it.
local function sortPhotos( input, sequenceBy, meta )
	local photos = {}
	for i, photo in ipairs( input ) do photos[ i ] = photo end

	-- The comparator only ever touches this table, never the catalog: table.sort
	-- calls it O(n log n) times, and a catalog read in there would be paid that
	-- many times over for values that cannot change mid-sort.
	local function of( photo )
		return meta and meta[ photo ] or {}
	end

	local function leaf( m )
		return m.path and LrPathUtils.leafName( m.path ) or ''
	end

	if sequenceBy == 'capture' then
		-- Stable via the filename tie-break: two frames from the same second
		-- still get a deterministic order.
		table.sort( photos, function( a, b )
			local ma, mb = of( a ), of( b )
			local ta = ma.dateTimeOriginal or math.huge
			local tb = mb.dateTimeOriginal or math.huge
			if ta ~= tb then return ta < tb end
			return leaf( ma ) < leaf( mb )
		end )
	elseif sequenceBy == 'filename' then
		table.sort( photos, function( a, b )
			return leaf( of( a ) ) < leaf( of( b ) )
		end )
	end
	return photos
end

Metadata.sortPhotos = sortPhotos

--[[
Which photo becomes the cover.

Returns index, count - count being how many photos qualified, so the dialog can
say when the choice was ambiguous and the first one won.

On colour labels: colorNameForLabel reflects the catalog's Label Set text, so a
custom or localised set returns something other than the six documented English
names. Hence the case-insensitive comparison - and hence the rules below that
need no label at all.
]]
local function resolveCover( photos, settings, meta )
	local rule = settings.coverRule
	local n = #photos
	if n == 0 then return nil, 0 end

	-- Positional rules: never ambiguous.
	if rule == 'first' then return 1, 1 end
	if rule == 'last' then return n, 1 end
	if rule == 'position' then
		local i = math.floor( tonumber( settings.coverPosition ) or 0 )
		if i >= 1 and i <= n then return i, 1 end
		return nil, 0   -- asked for a photo that is not in the selection
	end

	if rule == 'rating' then
		-- Highest rating wins, ties go to the first in order. A wholly unrated
		-- selection yields no cover rather than picking arbitrarily.
		local best, index, count = 0, nil, 0
		for i, photo in ipairs( photos ) do
			local rating = ( meta[ photo ] or {} ).rating or 0
			if rating > best then
				best, index, count = rating, i, 1
			elseif rating == best and best > 0 then
				count = count + 1
			end
		end
		return index, count
	end

	-- label / flag: first match wins.
	local index, count = nil, 0
	for i, photo in ipairs( photos ) do
		local m = meta[ photo ] or {}
		local match
		if rule == 'flag' then
			match = m.pickStatus == 1
		else
			match = type( m.colorNameForLabel ) == 'string'
				and m.colorNameForLabel:lower() == tostring( settings.coverLabel ):lower()
		end
		if match then
			count = count + 1
			if not index then index = i end
		end
	end
	return index, count
end

--[[
Resolves everything derived from the photos themselves.

	photos      ordered list of LrPhoto (already sequenced)
	settings    the export dialog's property table

Returns:
	date        YYYY-MM-DD, earliest capture date, today if none has one
	dates       every distinct capture date in the selection, ascending
	lat, lng    numbers from the first photo carrying GPS, or nil
	coverIndex  1-based index into `photos`, or nil
	coverCount  how many photos matched the cover rule (for the summary)
]]
function Metadata.resolve( photos, settings, meta )
	local result = { coverCount = 0, dates = {} }
	local seenDate = {}

	for _, photo in ipairs( photos ) do
		local m = meta[ photo ] or {}
		local d = captureDate( m )
		if d and ( not result.date or d < result.date ) then
			result.date = d
		end
		-- Every date the shoot actually spans, for the dialog's date menu: a
		-- trip over a long weekend gives three entries to pick between.
		if d and not seenDate[ d ] then
			seenDate[ d ] = true
			result.dates[ #result.dates + 1 ] = d
		end

		if not result.lat then
			local gps = m.gps
			if gps and gps.latitude and gps.longitude then
				result.lat, result.lng = gps.latitude, gps.longitude
			end
		end
	end

	result.coverIndex, result.coverCount = resolveCover( photos, settings, meta )

	table.sort( result.dates )

	local today = LrDate.timeToIsoDate( LrDate.currentTime() )
	if not result.date then
		result.date = today
		log:warn( 'No capture date on any photo; defaulting to today: ' .. today )
	end
	if not seenDate[ today ] then
		result.dates[ #result.dates + 1 ] = today
	end

	log:info( string.format( 'resolved: date=%s lat=%s lng=%s coverIndex=%s coverCount=%d',
		tostring( result.date ), tostring( result.lat ), tostring( result.lng ),
		tostring( result.coverIndex ), result.coverCount ) )

	return result
end

-- The dialog's values win; auto-fill only supplies what was left blank.
function Metadata.merge( settings, resolved, numbering )
	local album = {}

	album.date = ( settings.albumDate ~= '' and settings.albumDate ) or resolved.date
	album.title = settings.albumTitle
	album.description = settings.description
	album.categories = FrontMatter.splitCategories( settings.categories )

	-- lat/lng are not part of hugo-theme-gallery, so they are only written when
	-- the site actually has a map layout reading them. The dialog prefills the
	-- field, so an empty one is a deliberate "no coordinates", not a gap to fill
	-- from the catalog.
	if Prefs.get( 'writeCoordinates' ) then
		local lat, lng = Coords.parse( settings.location )
		if lat and lng then album.lat, album.lng = lat, lng end
	end

	if resolved.coverIndex then
		album.cover = Slug.fileName( settings.slug, resolved.coverIndex, numbering )
	end

	return album
end

return Metadata
