--[[
Parses coordinates out of whatever the user has in the clipboard.

Most photos carry no GPS, so the coordinates usually get typed or pasted by
hand, in whichever notation they were copied from:

	45.4408, 12.3155
	45.4408 12.3155
	46°32'25.8"N 12°08'08.5"E

Pure Lua on purpose (see HugoAlbumSlug.lua for why).
]]

local Coords = {}

local NUM = '(-?%d+%.?%d*)'

local function inRange( lat, lng )
	if not lat or not lng then return nil end
	if lat < -90 or lat > 90 or lng < -180 or lng > 180 then return nil end
	return lat, lng
end

-- One "46 32 25.8" chunk plus its hemisphere letter. Missing minutes and
-- seconds are fine: "46°N" and "46°32'N" both work.
local function dmsChunk( chunk, hemisphere )
	local nums = {}
	for n in chunk:gmatch( '%d+%.?%d*' ) do nums[ #nums + 1 ] = tonumber( n ) end
	if #nums == 0 then return nil end

	local value = nums[ 1 ] + ( nums[ 2 ] or 0 ) / 60 + ( nums[ 3 ] or 0 ) / 3600
	hemisphere = hemisphere:upper()
	if hemisphere == 'S' or hemisphere == 'W' then value = -value end
	return value, hemisphere
end

-- Requires the N/S/E/W letters, which is what makes this unambiguous enough to
-- try before the plain-number forms.
local function parseDMS( text )
	local t = text:gsub( '°', ' ' ):gsub( '′', "'" ):gsub( '″', '"' )
	local lat, lng
	for chunk, hemisphere in t:gmatch( '([%d%.%s\'"]+)([NSEWnsew])' ) do
		local value, letter = dmsChunk( chunk, hemisphere )
		if value then
			if letter == 'N' or letter == 'S' then lat = value else lng = value end
		end
	end
	return lat, lng
end

local function parsePair( text )
	local a, b = text:match( '^%s*' .. NUM .. '%s*[,;]?%s+' .. NUM .. '%s*$' )
	if not a then
		a, b = text:match( '^%s*' .. NUM .. '%s*,%s*' .. NUM .. '%s*$' )
	end
	if a and b then return tonumber( a ), tonumber( b ) end
end

-- Returns lat, lng, or nil when nothing usable is in there.
function Coords.parse( text )
	if type( text ) ~= 'string' or text:match( '^%s*$' ) then return nil end

	local lat, lng = parseDMS( text )
	if not lat then lat, lng = parsePair( text ) end

	return inRange( lat, lng )
end

-- Four decimals, matching the existing albums (~11m, plenty for a map pin).
function Coords.format( lat, lng )
	if not lat or not lng then return '' end
	return string.format( '%.4f, %.4f', lat, lng )
end

-- A pin to eyeball before committing. OpenStreetMap needs no API key and no
-- account, unlike the Google and Apple equivalents.
function Coords.mapUrl( lat, lng )
	return string.format( 'https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f#map=13/%.5f/%.5f',
		lat, lng, lat, lng )
end

return Coords
