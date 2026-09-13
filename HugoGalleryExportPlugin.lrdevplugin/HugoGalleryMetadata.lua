local LrApplication = import 'LrApplication'
local LrDate        = import 'LrDate'
local LrPathUtils   = import 'LrPathUtils'
local LrTasks       = import 'LrTasks'
local Coords      = require 'HugoGalleryCoords'
local FrontMatter = require 'HugoGalleryFrontMatter'
local Prefs       = require 'HugoGalleryPrefs'
local Slug        = require 'HugoGallerySlug'
local log         = require 'HugoGalleryLog'
local Metadata = {}
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

local function sortPhotos( input, sequenceBy, meta )
	local photos = {}
	for i, photo in ipairs( input ) do photos[ i ] = photo end
	local function of( photo )
		return meta and meta[ photo ] or {}
	end
	local function leaf( m )
		return m.path and LrPathUtils.leafName( m.path ) or ''
	end
	if sequenceBy == 'capture' then
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

local function resolveCover( photos, settings, meta )
	local rule = settings.coverRule
	local n = #photos
	if n == 0 then return nil, 0 end
	if rule == 'first' then return 1, 1 end
	if rule == 'last' then return n, 1 end
	if rule == 'position' then
		local i = math.floor( tonumber( settings.coverPosition ) or 0 )
		if i >= 1 and i <= n then return i, 1 end
		return nil, 0
	end

	if rule == 'rating' then
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

function Metadata.resolve( photos, settings, meta )
	local result = { coverCount = 0, dates = {} }
	local seenDate = {}

	for _, photo in ipairs( photos ) do
		local m = meta[ photo ] or {}
		local d = captureDate( m )
		if d and ( not result.date or d < result.date ) then
			result.date = d
		end
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

function Metadata.merge( settings, resolved, numbering )
	local album = {}
	album.date = ( settings.albumDate ~= '' and settings.albumDate ) or resolved.date
	album.title = settings.albumTitle
	album.description = settings.description
	album.categories = FrontMatter.splitCategories( settings.categories )

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
