--[[
Renders an album table into the YAML front matter of an album's index.md.

Pure Lua on purpose (see HugoAlbumSlug.lua for why).

Field order is fixed so a diff against a hand-written album reads cleanly:

	date, title, sort_by, categories, lat, lng, description, resources
]]

local FrontMatter = {}

-- Free text from the export dialog goes through here. Quoting unconditionally is
-- what makes that safe: a title starting with '#', '-', '[', '@' or containing
-- ': ' is legal YAML only when quoted, and we cannot know in advance which the
-- user will type. An unquoted 'Las Vegas | Nevada' happens to be legal YAML;
-- that is luck, not a rule.)
local function quote( s )
	s = tostring( s or '' )
	s = s:gsub( '\r', '' )
	s = s:gsub( '[\n\t]', ' ' )
	s = s:gsub( '\\', '\\\\' )
	s = s:gsub( '"', '\\"' )
	return '"' .. s .. '"'
end

-- "travel, 2026" -> { "travel", "2026" }. Empty entries dropped, so a trailing
-- comma or a stray ", ," cannot produce an empty category.
function FrontMatter.splitCategories( text )
	local out = {}
	for part in tostring( text or '' ):gmatch( '[^,]+' ) do
		local trimmed = part:match( '^%s*(.-)%s*$' )
		if trimmed ~= '' then out[ #out + 1 ] = trimmed end
	end
	return out
end

--[[
album = {
	date        = '2026-05-02',      -- required, YYYY-MM-DD
	title       = 'Venice',          -- required
	categories  = { 'travel', '2026' },
	lat         = 45.4408,           -- both or neither
	lng         = 12.3155,
	description = 'A long weekend in Venice.',
	cover       = 'venice-17.jpg',   -- omitted -> Hugo falls back to the first image
}
]]
function FrontMatter.render( album )
	local out = { '---' }

	out[ #out + 1 ] = 'date: ' .. album.date          -- bare: Hugo wants a date, not a string
	out[ #out + 1 ] = 'title: ' .. quote( album.title )
	out[ #out + 1 ] = 'sort_by: Name'                 -- filenames are the running order

	local cats = album.categories or {}
	if #cats > 0 then
		local quoted = {}
		for i, c in ipairs( cats ) do quoted[ i ] = quote( c ) end
		out[ #out + 1 ] = 'categories: [' .. table.concat( quoted, ', ' ) .. ']'
	end

	-- Half a coordinate pair would put the album at the equator or the prime
	-- meridian, so it is both or neither.
	if album.lat and album.lng then
		out[ #out + 1 ] = string.format( 'lat: %.4f', album.lat )
		out[ #out + 1 ] = string.format( 'lng: %.4f', album.lng )
	end

	if album.description and album.description ~= '' then
		out[ #out + 1 ] = 'description: ' .. quote( album.description )
	end

	if album.cover then
		out[ #out + 1 ] = 'resources:'
		out[ #out + 1 ] = '  - src: ' .. album.cover
		out[ #out + 1 ] = '    params:'
		out[ #out + 1 ] = '      cover: true'
	end

	out[ #out + 1 ] = '---'
	out[ #out + 1 ] = ''
	return table.concat( out, '\n' )
end

return FrontMatter
