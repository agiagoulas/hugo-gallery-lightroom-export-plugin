local FrontMatter = {}
local function quote( s )
	s = tostring( s or '' )
	s = s:gsub( '\r', '' )
	s = s:gsub( '[\n\t]', ' ' )
	s = s:gsub( '\\', '\\\\' )
	s = s:gsub( '"', '\\"' )
	return '"' .. s .. '"'
end

function FrontMatter.splitCategories( text )
	local out = {}
	for part in tostring( text or '' ):gmatch( '[^,]+' ) do
		local trimmed = part:match( '^%s*(.-)%s*$' )
		if trimmed ~= '' then out[ #out + 1 ] = trimmed end
	end
	return out
end

local function keyLines( key, album )
	if key == 'date' then
		return album.date and album.date ~= '' and { 'date: ' .. album.date } or nil
	elseif key == 'title' then
		return album.title and album.title ~= '' and { 'title: ' .. quote( album.title ) } or nil
	elseif key == 'sort_by' then
		return { 'sort_by: Name' }
	elseif key == 'categories' then
		local cats = album.categories or {}
		if #cats == 0 then return nil end
		local quoted = {}
		for i, c in ipairs( cats ) do quoted[ i ] = quote( c ) end
		return { 'categories: [' .. table.concat( quoted, ', ' ) .. ']' }
	elseif key == 'lat' then
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

local function isUnmanaged( lines )
	if #lines > 1 then return true end
	local value = lines[ 1 ]:match( '^[%w_%-]+:%s*(.-)%s*$' ) or ''
	return value:match( '^[|>][%+%-]?%d*$' ) ~= nil
end

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

	local insertAt
	local latReplaced = false

	for _, key in ipairs( parsed.keys ) do
		if key == 'resources' and not insertAt then insertAt = #out + 1 end

		if key == 'lng' and latReplaced then
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

function FrontMatter.plan( existing, album )
	if not existing then
		return 'write', FrontMatter.render( album ), {}
	end

	if existing.indexExists and not existing.index then
		return 'leave', nil,
			{ 'index.md could not be read, so it was left untouched - the photos were still added.' }
	end

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
