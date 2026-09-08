--[[
Slug derivation and filename padding.

Pure Lua on purpose: no `Lr*` imports, so this can be exercised under a plain
`lua` interpreter (see ../README.md). Together with HugoAlbumFrontMatter these
are the two modules that can silently corrupt an album, which is exactly why
they are testable outside Lightroom.
]]

local Slug = {}

-- Transliteration table. The keys are literal UTF-8 byte sequences; gsub treats
-- them as plain substrings because no byte above 127 is a Lua pattern magic
-- character. Applied before string.lower, which only folds ASCII A-Z.
--
-- Two rules, not one: letters that are letters in their own right expand
-- (ü -> ue, ø -> oe, å -> aa), while plain diacritics are stripped
-- (é -> e), so "Brüssels" becomes "bruessels" rather than "brssels".
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

-- "Brüssels" -> "bruessels";  'Brüssels & Co: "day one"' -> "bruessels-co-day-one"
function Slug.slugify( text )
	if type( text ) ~= 'string' then return '' end
	local s = text
	for from, to in pairs( TRANSLITERATE ) do
		s = s:gsub( from, to )
	end
	s = s:lower()
	s = s:gsub( '[^a-z0-9]+', '-' )
	s = s:gsub( '^%-+', '' ):gsub( '%-+$', '' )
	return s
end

-- The slug becomes the album's directory name and the stem of every
-- filename in it, so keep it to what Hugo and the shell both handle plainly.
function Slug.isValid( slug )
	return type( slug ) == 'string' and slug:match( '^[a-z0-9][a-z0-9%-]*$' ) ~= nil
end

--[[
Numbering for one export.

Filenames set the album's default display order (sort_by: Name), so they must be
zero-padded or "venice-10" sorts before "venice-2". Always at least two digits:
42 photos -> 01..42, 120 photos -> 001..120.

When adding to an album that already exists, `existing` carries its highest
number and the width it uses, so new photos continue the sequence in the same
shape rather than colliding with or reformatting what is there.

`widthGrew` flags the one case this cannot paper over: an album already numbered
01..99 that grows past 99 needs three digits, and "venice-100" then sorts before
"venice-99". The caller warns rather than silently renaming the existing files.
]]
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

function Slug.fileName( slug, index, numbering )
	local number = numbering.offset + index
	return slug .. '-' .. string.format( '%0' .. numbering.width .. 'd', number ) .. '.jpg'
end

return Slug
