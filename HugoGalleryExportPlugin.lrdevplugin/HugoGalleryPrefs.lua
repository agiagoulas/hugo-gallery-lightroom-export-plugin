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

	-- SHORT edge in pixels, and JPEG quality.
	--
	-- The short edge, not the long one, because hugo-theme-gallery's album grid
	-- is a justified layout: it lays photos out to a common height, so what
	-- decides sharpness is how many rows a photo has. Capping the long edge gives
	-- a 4:1 panorama a quarter of the rows of an ordinary photo, and it shows.
	--
	-- 1365 is chosen so an ordinary 3:2 photo comes out at 2048x1365, which is
	-- what a long edge of 2048 used to give it. Only wide photos get larger.
	shortEdge = 1365,
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
	shortEdge = { min = 240, max = 10000 },
	jpegQuality = { min = 1, max = 100 },
}

--[[
A relative folder preference, normalised.

albumsFolder is a free-text field that decides where albums are written and what
`git add` is handed. Left empty it wrote to the repository root; with a leading
slash `git add` failed with "outside repository"; and `content/../..` escaped the
working copy altogether. Anything it cannot make sense of falls back to the
default rather than guessing.

Returns the cleaned value, and false when the raw input had to be rejected.
]]
function Prefs.folder( key )
	local raw = tostring( Prefs.get( key ) or '' )
	local cleaned = raw:gsub( '\\', '/' ):gsub( '%s+', '' )

	-- An absolute path or a drive letter is not a path inside the repository.
	local rejected = cleaned:match( '^/' ) ~= nil or cleaned:match( '^%a:' ) ~= nil

	local segments = {}
	for segment in cleaned:gmatch( '[^/]+' ) do
		if segment == '..' then
			rejected = true      -- would climb out of the working copy
		elseif segment ~= '.' then
			segments[ #segments + 1 ] = segment
		end
	end

	if rejected then
		return Prefs.DEFAULTS[ key ], false          -- unusable input, say so
	end
	if #segments == 0 then
		-- Compared after cleaning, so a field of spaces counts as unset rather
		-- than as a mistake worth a message. A deliberate "." does not: the
		-- repository root is exactly what this is meant to keep albums out of.
		return Prefs.DEFAULTS[ key ], cleaned == ''
	end
	return table.concat( segments, '/' ), true
end

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
