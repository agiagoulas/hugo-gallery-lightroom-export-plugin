--[[
Plug-in preferences, with their defaults in one place.

Everything here is a property of the machine and the site, not of an album, so
it is set once in the Plug-in Manager rather than at every export.

The defaults are written into the preference table on load, so the Plug-in
Manager can bind straight to it and still show something sensible on a first
run.
]]

local LrPrefs = import 'LrPrefs'

local Prefs = {}

Prefs.DEFAULTS = {
	-- The Hugo site's working copy.
	repoPath = '',

	-- Where album bundles live, relative to the repo root and with forward
	-- slashes. 'content' suits a site whose albums sit at the content root;
	-- 'content/albums' and the like work just as well.
	albumsFolder = 'content',

	-- Long edge in pixels and JPEG quality for the exported files. 2048 is a
	-- deliberate default: hugo-theme-gallery's largest derivative is 1600px, so
	-- this is invisible on the page while leaving headroom, and it keeps photos
	-- small enough to live in git.
	longEdge = 2048,
	jpegQuality = 92,

	-- lat/lng in the front matter. Off by default because it is NOT part of
	-- hugo-theme-gallery: it only means anything on a site that has added a map
	-- layout reading those two keys.
	writeCoordinates = false,
}

-- Materialise the defaults once, so bindings and getters see the same values.
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
		-- An emptied number field should fall back rather than export at zero.
		if type( Prefs.DEFAULTS[ key ] ) == 'number' then return Prefs.DEFAULTS[ key ] end
	end
	if value == nil then return Prefs.DEFAULTS[ key ] end
	return value
end

-- Bounds for the numeric settings. These are free-text fields, so a slip of the
-- keyboard would otherwise reach the export API directly: a long edge of 0 or a
-- quality of 900 (which becomes LR_jpeg_quality 9.0, far outside its 0..1 range)
-- would break every photo in the album without ever looking like an error.
local RANGES = {
	longEdge = { min = 240, max = 10000 },
	jpegQuality = { min = 1, max = 100 },
}

-- Numbers arrive from edit fields as strings.
function Prefs.number( key )
	local value = tonumber( Prefs.get( key ) ) or Prefs.DEFAULTS[ key ]
	local range = RANGES[ key ]
	if range then
		value = math.max( range.min, math.min( range.max, value ) )
	end
	return value
end

return Prefs
