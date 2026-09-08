--[[
Exercises the two modules that have no Lightroom dependency - the two that can
silently corrupt content/ if their escaping or padding is wrong.

	luajit test-pure.lua      (brew install luajit)
]]

package.path = './HugoAlbum.lrdevplugin/?.lua;' .. package.path

local Slug        = require 'HugoAlbumSlug'
local FrontMatter = require 'HugoAlbumFrontMatter'
local Coords      = require 'HugoAlbumCoords'

local failures = 0

local function eq( got, want, label )
	if got ~= want then
		failures = failures + 1
		io.write( 'FAIL ', label, '\n  got:  ', tostring( got ), '\n  want: ', tostring( want ), '\n' )
	else
		io.write( 'ok   ', label, '\n' )
	end
end

-- Slugs -----------------------------------------------------------------------

eq( Slug.slugify( 'Venice' ), 'venice', 'plain title' )
eq( Slug.slugify( 'Brüssels' ), 'bruessels', 'umlaut expands rather than being stripped' )
eq( Slug.slugify( 'Las Vegas | Nevada' ), 'las-vegas-nevada', 'punctuation collapses' )
eq( Slug.slugify( 'Brüssels & Co: "day one"' ), 'bruessels-co-day-one', 'quotes and colon' )
eq( Slug.slugify( '  --Trailing-- ' ), 'trailing', 'edges trimmed' )
eq( Slug.slugify( 'Zürich 2026' ), 'zuerich-2026', 'digits kept' )
eq( Slug.slugify( 'Køge Ærø Åland' ), 'koege-aeroe-aaland', 'nordic letters expand like umlauts' )
eq( Slug.slugify( 'Straße' ), 'strasse', 'eszett' )
eq( Slug.slugify( '' ), '', 'empty' )
eq( Slug.slugify( nil ), '', 'nil' )

eq( Slug.isValid( 'venice' ), true, 'valid slug' )
eq( Slug.isValid( 'Venice' ), false, 'uppercase rejected' )
eq( Slug.isValid( '-venice' ), false, 'leading hyphen rejected' )
eq( Slug.isValid( 'ven ice' ), false, 'space rejected' )
eq( Slug.isValid( '' ), false, 'empty rejected' )

-- Padding: the whole point is that venice-10 must not sort before venice-2.
eq( Slug.fileName( 'venice', 1, 3 ), 'venice-01.jpg', '3 photos -> 2 digits' )
eq( Slug.fileName( 'venice', 42, 42 ), 'venice-42.jpg', '42 photos -> 2 digits' )
eq( Slug.fileName( 'venice', 7, 120 ), 'venice-007.jpg', '120 photos -> 3 digits' )
local a, b = Slug.fileName( 'v', 2, 10 ), Slug.fileName( 'v', 10, 10 )
eq( a < b, true, 'padded names sort numerically' )

-- Front matter ----------------------------------------------------------------

eq( FrontMatter.render {
	date = '2026-05-02', title = 'Venice', categories = { 'travel', '2026' },
	lat = 45.4408, lng = 12.3155, description = 'A long weekend in Venice.',
	cover = 'venice-17.jpg',
}, [[
---
date: 2026-05-02
title: "Venice"
sort_by: Name
categories: ["travel", "2026"]
lat: 45.4408
lng: 12.3155
description: "A long weekend in Venice."
resources:
  - src: venice-17.jpg
    params:
      cover: true
---
]], 'full album, in the documented field order' )

eq( FrontMatter.render { date = '2026-01-01', title = 'Bare' }, [[
---
date: 2026-01-01
title: "Bare"
sort_by: Name
---
]], 'optional keys omitted entirely, no empty categories or resources' )

-- The reason quoting is unconditional.
local hostile = FrontMatter.render {
	date = '2026-01-01',
	title = '#1: a "great" trip\\home',
	description = 'line one\nline two\ttabbed\r',
	categories = { '- weird', 'ok' },
}
eq( hostile:match( '\ntitle: (.-)\n' ), '"#1: a \\"great\\" trip\\\\home"', 'title escaped' )
eq( hostile:match( '\ndescription: (.-)\n' ), '"line one line two tabbed"', 'newlines flattened' )
eq( hostile:match( '\ncategories: (.-)\n' ), '["- weird", "ok"]', 'categories quoted' )

-- Half a coordinate pair would put the album at the equator.
eq( FrontMatter.render { date = '2026-01-01', title = 'X', lat = 1.0 }:match( 'lat' ), nil,
	'lat without lng is dropped' )

local cats = FrontMatter.splitCategories( ' travel , , 2026,' )
eq( #cats .. ':' .. table.concat( cats, '|' ), '2:travel|2026', 'category splitting trims and drops blanks' )
eq( #FrontMatter.splitCategories( '' ), 0, 'empty category string' )

-- Coordinates ------------------------------------------------------------------

local function coords( text, label )
	local lat, lng = Coords.parse( text )
	return ( lat and Coords.format( lat, lng ) or 'nil' )
end

eq( coords( '45.4408, 12.3155' ), '45.4408, 12.3155', 'decimal pair with comma' )
eq( coords( '45.4408 12.3155' ), '45.4408, 12.3155', 'decimal pair with space' )
eq( coords( '  45.4408,12.3155  ' ), '45.4408, 12.3155', 'surrounding whitespace' )
eq( coords( '-33.8688, 151.2093' ), '-33.8688, 151.2093', 'southern hemisphere' )

eq( coords( '46°32\'25.8"N 12°08\'08.5"E' ), '46.5405, 12.1357', 'DMS' )
eq( coords( '46°32\'25.8"S 12°08\'08.5"W' ), '-46.5405, -12.1357', 'DMS south/west' )
eq( coords( '46°N 12°E' ), '46.0000, 12.0000', 'degrees only' )

-- Map links are deliberately not accepted: paste the coordinates themselves.
eq( coords( 'https://www.google.com/maps/@46.5405,12.1357,14z' ), 'nil', 'google url rejected' )
eq( coords( 'https://maps.apple.com/?ll=46.5405,12.1357&z=14' ), 'nil', 'apple url rejected' )
eq( coords( 'https://www.google.com/maps/place/X/@40.0,10.0,17z/data=!3d46.5!4d12.1' ), 'nil',
	'google place url rejected' )

eq( coords( '' ), 'nil', 'empty' )
eq( coords( '   ' ), 'nil', 'blank' )
eq( coords( nil ), 'nil', 'nil' )
eq( coords( 'Venice' ), 'nil', 'place name is not coordinates' )
eq( coords( '91.0, 12.0' ), 'nil', 'latitude out of range' )
eq( coords( '45.0, 181.0' ), 'nil', 'longitude out of range' )
eq( coords( '45.4408' ), 'nil', 'a single number is not a pair' )

eq( Coords.format( nil, nil ), '', 'format with no coordinates' )
eq( Coords.mapUrl( 46.5405, 12.1357 ):match( '^https://www%.openstreetmap%.org/' ) ~= nil, true,
	'map url' )

--------------------------------------------------------------------------------

io.write( '\n', failures == 0 and 'all tests passed\n' or ( failures .. ' FAILURES\n' ) )
os.exit( failures == 0 and 0 or 1 )
