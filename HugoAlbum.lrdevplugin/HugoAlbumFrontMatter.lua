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
-- One place per key, so render() and merge() cannot drift apart. Returns a list
-- of lines, or nil when the album has nothing to say about that key.
local function keyLines( key, album )
	if key == 'date' then
		-- bare: Hugo wants a date, not a string
		return album.date and album.date ~= '' and { 'date: ' .. album.date } or nil

	elseif key == 'title' then
		return album.title and album.title ~= '' and { 'title: ' .. quote( album.title ) } or nil

	elseif key == 'sort_by' then
		return { 'sort_by: Name' }   -- filenames are the running order

	elseif key == 'categories' then
		local cats = album.categories or {}
		if #cats == 0 then return nil end
		local quoted = {}
		for i, c in ipairs( cats ) do quoted[ i ] = quote( c ) end
		return { 'categories: [' .. table.concat( quoted, ', ' ) .. ']' }

	elseif key == 'lat' then
		-- Half a pair would put the album at the equator or the prime meridian,
		-- so lat carries both or neither and lng renders nothing on its own.
		if not ( album.lat and album.lng ) then return nil end
		return {
			string.format( 'lat: %.4f', album.lat ),
			string.format( 'lng: %.4f', album.lng ),
		}

	elseif key == 'description' then
		if not album.description or album.description == '' then return nil end
		return { 'description: ' .. quote( album.description ) }

	elseif key == 'resources' then
		if not album.cover then return nil end
		return {
			'resources:',
			'  - src: ' .. album.cover,
			'    params:',
			'      cover: true',
		}
	end
	return nil
end

-- Written in this order for a new album; an existing one keeps its own order.
local CREATE_ORDER = { 'date', 'title', 'sort_by', 'categories', 'lat', 'description', 'resources' }

function FrontMatter.render( album )
	local out = { '---' }
	for _, key in ipairs( CREATE_ORDER ) do
		local rendered = keyLines( key, album )
		if rendered then
			for _, line in ipairs( rendered ) do out[ #out + 1 ] = line end
		end
	end
	out[ #out + 1 ] = '---'
	out[ #out + 1 ] = ''
	return table.concat( out, '\n' )
end

--------------------------------------------------------------------------------
-- Reading and updating an album that already exists.
--
-- Deliberately not a YAML parser. It works line by line and keeps every block it
-- does not understand exactly as it found it, because that is where the things
-- this plug-in knows nothing about live: featured, layout, menu, a
-- sort_by: Params.weight, the per-photo title: captions and weight: params, and
-- any Markdown body below the front matter. Losing those to a round trip through
-- an export dialog would be far worse than not offering the feature.

local function splitLines( text )
	local out, pos = {}, 1
	local sawCRLF = false
	while pos <= #text do
		local nl = text:find( '\n', pos, true )
		local line
		if nl then
			line = text:sub( pos, nl - 1 )
			pos = nl + 1
		else
			line = text:sub( pos )
			pos = #text + 1
		end
		if line:sub( -1 ) == '\r' then
			sawCRLF = true
			line = line:sub( 1, -2 )
		end
		out[ #out + 1 ] = line
	end
	return out, sawCRLF and '\r\n' or '\n'
end

-- A block this module must not rewrite: it has continuation lines, or its value
-- is a block-scalar header (`>`, `|`, `|-`, `>2` ...) with the content on the
-- lines below. Reducing either to a single quoted line is exactly the data loss
-- the merge exists to prevent - a folded three-line description would come back
-- as `description: ">"`.
local function isUnmanaged( lines )
	if #lines > 1 then return true end
	local value = lines[ 1 ]:match( '^[%w_%-]+:%s*(.-)%s*$' ) or ''
	return value:match( '^[|>][%+%-]?%d*$' ) ~= nil
end

--[[
Splits an index.md into ordered top-level blocks plus the body.

	keys       top-level key names, in the order they appear
	block      key -> the lines it owns, continuation lines included
	unmanaged  key -> true for blocks that must be preserved verbatim
	preamble   anything before the first key (comments)
	body       everything after the closing ---
	eol        the file's line ending, so the merge can write it back unchanged

Returns nil when the file has no front matter, which the caller must treat as
"do not touch this file".
]]
function FrontMatter.parse( text )
	if type( text ) ~= 'string' then return nil end
	local ls, eol = splitLines( text )
	if ls[ 1 ] ~= '---' then return nil end

	local closing
	for i = 2, #ls do
		if ls[ i ] == '---' then closing = i break end
	end
	if not closing then return nil end

	local parsed = { keys = {}, block = {}, unmanaged = {}, preamble = {}, eol = eol }
	local current
	for i = 2, closing - 1 do
		local line = ls[ i ]
		local key = line:match( '^([%w_%-]+):' )
		if key and not parsed.block[ key ] then
			current = key
			parsed.keys[ #parsed.keys + 1 ] = key
			parsed.block[ key ] = { line }
		elseif key then
			-- A repeat of a key already seen. Appending it to whatever block came
			-- before would move it, and the merge would then emit both copies, so
			-- it gets its own block that nothing will rewrite.
			current = nil
			parsed.keys[ #parsed.keys + 1 ] = line
			parsed.block[ line ] = { line }
			parsed.unmanaged[ line ] = true
		elseif current then
			table.insert( parsed.block[ current ], line )
		else
			parsed.preamble[ #parsed.preamble + 1 ] = line
		end
	end

	for key, lines in pairs( parsed.block ) do
		if isUnmanaged( lines ) then parsed.unmanaged[ key ] = true end
	end

	local body = table.concat( ls, eol, closing + 1 )
	parsed.body = body ~= '' and ( body .. eol ) or ''
	return parsed
end

local function unquote( value )
	value = value:match( '^%s*(.-)%s*$' )
	local inner = value:match( '^"(.*)"$' ) or value:match( "^'(.*)'$" )
	if not inner then return value end
	return ( inner:gsub( '\\"', '"' ):gsub( '\\\\', '\\' ) )
end

--[[
Pulls the values the Export dialog owns back out of an existing album, so the
dialog can be prefilled with them instead of silently replacing them.

A key whose block is unmanaged comes back as nil and is named in `unmanaged`.
nil rather than the raw first line, because every consumer already treats a
missing key as nil - and because handing the dialog `">"` to edit, as this once
did, is how the block below it got destroyed.
]]
function FrontMatter.readValues( text )
	local parsed = FrontMatter.parse( text )
	if not parsed then return nil end

	local function scalar( key )
		local lines = parsed.block[ key ]
		if not lines or parsed.unmanaged[ key ] then return nil end
		return unquote( lines[ 1 ]:match( '^[%w_%-]+:%s*(.*)$' ) or '' )
	end

	local values = {
		date = scalar( 'date' ),
		title = scalar( 'title' ),
		description = scalar( 'description' ),
		lat = tonumber( scalar( 'lat' ) ),
		lng = tonumber( scalar( 'lng' ) ),
		hasResources = parsed.block.resources ~= nil,
		unmanaged = parsed.unmanaged,
	}

	local cats = scalar( 'categories' )
	if cats then
		local names = {}
		for item in cats:gmatch( '[^,%[%]]+' ) do
			local name = unquote( item )
			if name ~= '' then names[ #names + 1 ] = name end
		end
		values.categories = table.concat( names, ', ' )
	end

	return values
end

--[[
Rewrites an existing index.md with the album values, preserving everything else.

Three rules make this safe to run over a hand-edited file:

  * it never deletes. A key the dialog left empty keeps whatever the file had -
    clearing a field is an edit you make in the file, not a side effect of an
    export.
  * `resources` is never rewritten, only added when absent. That is where
    per-photo captions and weights live. `sort_by` is likewise only ever added.
  * a multi-line block is never touched at all, whatever key it belongs to.

Returns the new text and a list of keys that were left alone despite being ones
the dialog manages, so the caller can say so. nil if there is no front matter to
merge into.
]]
local MERGEABLE = { date = true, title = true, categories = true, lat = true, description = true }
local ADD_IF_ABSENT = { sort_by = true, resources = true }

function FrontMatter.merge( existingText, album )
	local parsed = FrontMatter.parse( existingText )
	if not parsed then return nil end

	local out, written, skipped = {}, {}, {}
	for _, line in ipairs( parsed.preamble ) do out[ #out + 1 ] = line end

	local function emit( lines )
		for _, line in ipairs( lines ) do out[ #out + 1 ] = line end
	end

	-- Where a key added below should go. A new scalar belongs above the
	-- resources list, not stranded after sixty lines of per-photo entries.
	local insertAt
	local latReplaced = false

	for _, key in ipairs( parsed.keys ) do
		if key == 'resources' and not insertAt then insertAt = #out + 1 end

		if key == 'lng' and latReplaced then
			-- keyLines emits lng alongside lat, so this block is already out.
			written[ key ] = true
		else
			local replacement
			if MERGEABLE[ key ] then
				if parsed.unmanaged[ key ] then
					skipped[ #skipped + 1 ] = key
				else
					replacement = keyLines( key, album )
				end
			end
			if key == 'lat' and replacement then latReplaced = true end
			emit( replacement or parsed.block[ key ] )
			written[ key ] = true
		end
	end

	for _, key in ipairs( CREATE_ORDER ) do
		if not written[ key ] and ( MERGEABLE[ key ] or ADD_IF_ABSENT[ key ] ) then
			local rendered = keyLines( key, album )
			if rendered then
				if insertAt then
					for i, line in ipairs( rendered ) do
						table.insert( out, insertAt + i - 1, line )
					end
					insertAt = insertAt + #rendered
				else
					emit( rendered )
				end
			end
		end
	end

	local eol = parsed.eol
	return '---' .. eol .. table.concat( out, eol ) .. eol .. '---' .. eol .. parsed.body, skipped
end

--[[
Decides what to do with an album's index.md, and says why.

Pure on purpose: this is the decision that can destroy a hand-written file, and
keeping it out of processRenderedPhotos is what makes it testable.

	existing  nil for a new album, else Repo.inspectAlbum's return
	returns   action ('write' | 'merge' | 'leave'), contents, notes
]]
function FrontMatter.plan( existing, album )
	if not existing then
		return 'write', FrontMatter.render( album ), {}
	end

	-- The file is there but could not be read. Rendering a fresh one would
	-- silently replace captions, ordering and body with a four-line stub, which
	-- is the single worst thing this module could do.
	if existing.indexExists and not existing.index then
		return 'leave', nil,
			{ 'index.md could not be read, so it was left untouched - the photos were still added.' }
	end

	-- An album folder with no index.md at all: nothing to lose by writing one.
	if not existing.index then
		return 'write', FrontMatter.render( album ), {}
	end

	local merged, skipped = FrontMatter.merge( existing.index, album )
	if not merged then
		return 'leave', nil,
			{ 'index.md was left untouched - it has no front matter this could merge into.' }
	end

	local notes = { 'index.md updated; captions, ordering and anything else it had were kept.' }
	if #skipped > 0 then
		notes[ #notes + 1 ] = 'Left exactly as they were, being multi-line blocks: '
			.. table.concat( skipped, ', ' ) .. '.'
	end
	return 'merge', merged, notes
end

return FrontMatter
