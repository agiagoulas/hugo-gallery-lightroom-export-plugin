local LrPrefs = import 'LrPrefs'
local Prefs = {}

Prefs.DEFAULTS = {
	repoPath = '',
	albumsFolder = 'content',
	shortEdge = 1365,
	jpegQuality = 90,
	writeCoordinates = false,
}

local prefs = LrPrefs.prefsForPlugin()
for key, value in pairs( Prefs.DEFAULTS ) do
	if prefs[ key ] == nil then prefs[ key ] = value end
end

function Prefs.raw()
	return prefs
end

function Prefs.get( key )
	local value = prefs[ key ]
	if value == nil or value == '' then
		if type( Prefs.DEFAULTS[ key ] ) == 'number' then return Prefs.DEFAULTS[ key ] end
	end
	if value == nil then return Prefs.DEFAULTS[ key ] end
	return value
end

local RANGES = {
	shortEdge = { min = 240, max = 10000 },
	jpegQuality = { min = 1, max = 100 },
}

function Prefs.folder( key )
	local raw = tostring( Prefs.get( key ) or '' )
	local cleaned = raw:gsub( '\\', '/' ):gsub( '%s+', '' )
	local rejected = cleaned:match( '^/' ) ~= nil or cleaned:match( '^%a:' ) ~= nil
	local segments = {}
	for segment in cleaned:gmatch( '[^/]+' ) do
		if segment == '..' then
			rejected = true
		elseif segment ~= '.' then
			segments[ #segments + 1 ] = segment
		end
	end

	if rejected then
		return Prefs.DEFAULTS[ key ], false
	end
	if #segments == 0 then
		return Prefs.DEFAULTS[ key ], cleaned == ''
	end
	return table.concat( segments, '/' ), true
end

function Prefs.number( key )
	local value = tonumber( Prefs.get( key ) ) or Prefs.DEFAULTS[ key ]
	local range = RANGES[ key ]
	if range then
		value = math.max( range.min, math.min( range.max, value ) )
	end
	return value
end

return Prefs
