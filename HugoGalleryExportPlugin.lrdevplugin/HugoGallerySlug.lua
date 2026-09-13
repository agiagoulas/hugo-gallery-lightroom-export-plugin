local Slug = {}
local TRANSLITERATE = {
	['Ä'] = 'ae', ['ä'] = 'ae', ['Ö'] = 'oe', ['ö'] = 'oe',
	['Ü'] = 'ue', ['ü'] = 'ue', ['ß'] = 'ss',
	['Æ'] = 'ae', ['æ'] = 'ae', ['Ø'] = 'oe', ['ø'] = 'oe',
	['Å'] = 'aa', ['å'] = 'aa',
	['Á'] = 'a', ['À'] = 'a', ['Â'] = 'a', ['Ã'] = 'a',
	['á'] = 'a', ['à'] = 'a', ['â'] = 'a', ['ã'] = 'a',
	['É'] = 'e', ['È'] = 'e', ['Ê'] = 'e', ['Ë'] = 'e',
	['é'] = 'e', ['è'] = 'e', ['ê'] = 'e', ['ë'] = 'e',
	['Í'] = 'i', ['Ì'] = 'i', ['Î'] = 'i', ['Ï'] = 'i',
	['í'] = 'i', ['ì'] = 'i', ['î'] = 'i', ['ï'] = 'i',
	['Ó'] = 'o', ['Ò'] = 'o', ['Ô'] = 'o', ['Õ'] = 'o',
	['ó'] = 'o', ['ò'] = 'o', ['ô'] = 'o', ['õ'] = 'o',
	['Ú'] = 'u', ['Ù'] = 'u', ['Û'] = 'u',
	['ú'] = 'u', ['ù'] = 'u', ['û'] = 'u',
	['Ñ'] = 'n', ['ñ'] = 'n', ['Ç'] = 'c', ['ç'] = 'c',
	['Ý'] = 'y', ['ý'] = 'y',
}

function Slug.slugify( text )
	if type( text ) ~= 'string' then return '' end
	local s = text:gsub( '[\128-\255][\128-\191]*', TRANSLITERATE )
	s = s:lower()
	s = s:gsub( '[^a-z0-9]+', '-' )
	s = s:gsub( '^%-+', '' ):gsub( '%-+$', '' )
	return s
end

function Slug.isValid( slug )
	return type( slug ) == 'string' and slug:match( '^[a-z0-9][a-z0-9%-]*$' ) ~= nil
end

function Slug.numbering( newCount, existing )
	local offset = existing and existing.highest or 0
	local existingWidth = ( existing and existing.width ~= 0 ) and existing.width or nil
	local width = math.max( 2, #tostring( offset + newCount ), existingWidth or 0 )
	return {
		offset = offset,
		width = width,
		widthGrew = existingWidth ~= nil and width > existingWidth,
	}
end

function Slug.titleFromSlug( slug )
	if type( slug ) ~= 'string' then return '' end
	local words = {}
	for word in slug:gmatch( '[^%-]+' ) do
		words[ #words + 1 ] = word:sub( 1, 1 ):upper() .. word:sub( 2 )
	end
	return table.concat( words, ' ' )
end

function Slug.fileName( slug, index, numbering )
	local number = numbering.offset + index
	return slug .. '-' .. string.format( '%0' .. numbering.width .. 'd', number ) .. '.jpg'
end

return Slug
