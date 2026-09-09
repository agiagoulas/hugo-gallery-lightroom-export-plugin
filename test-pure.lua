--[[
Exercises the two modules that have no Lightroom dependency - the two that can
silently corrupt content/ if their escaping or padding is wrong.

	luajit test-pure.lua      (brew install luajit)
]]

package.path = './HugoGalleryExportPlugin.lrdevplugin/?.lua;' .. package.path

local Slug        = require 'HugoGallerySlug'
local FrontMatter = require 'HugoGalleryFrontMatter'
local Coords      = require 'HugoGalleryCoords'

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
local function names( count, existing )
	local n = Slug.numbering( count, existing )
	return function( i ) return Slug.fileName( 'venice', i, n ) end, n
end

eq( names( 3 )( 1 ), 'venice-01.jpg', '3 photos -> 2 digits' )
eq( names( 42 )( 42 ), 'venice-42.jpg', '42 photos -> 2 digits' )
eq( names( 120 )( 7 ), 'venice-007.jpg', '120 photos -> 3 digits' )
local ten = names( 10 )
eq( ten( 2 ) < ten( 10 ), true, 'padded names sort numerically' )

-- Adding to an existing album continues the sequence in its own shape.
local add = names( 3, { highest = 42, width = 2 } )
eq( add( 1 ), 'venice-43.jpg', 'append: continues after the highest existing number' )
eq( add( 3 ), 'venice-45.jpg', 'append: keeps counting' )
eq( select( 2, names( 3, { highest = 7, width = 3 } ) ).width, 3,
	'append: keeps the existing padding width even when fewer digits would do' )
eq( select( 2, names( 5, { highest = 98, width = 2 } ) ).widthGrew, true,
	'append: flags the 99 -> 100 case, where padding can no longer keep the order' )
eq( select( 2, names( 5, { highest = 40, width = 2 } ) ).widthGrew, false,
	'append: no false alarm when the width is unchanged' )

-- Title from slug ---------------------------------------------------------------
--
-- The dialog asks for the slug and offers a title, not the other way round.

eq( Slug.titleFromSlug( 'test-hello' ), 'Test Hello', 'title: hyphens become spaces' )
eq( Slug.titleFromSlug( 'venice' ), 'Venice', 'title: a single word' )
eq( Slug.titleFromSlug( 'dolomites-2026' ), 'Dolomites 2026', 'title: digits are left alone' )
eq( Slug.titleFromSlug( 'best-of' ), 'Best Of', 'title: every word, short ones included' )
eq( Slug.titleFromSlug( 'bruessels' ), 'Bruessels', 'title: no attempt to undo transliteration' )
eq( Slug.titleFromSlug( '' ), '', 'title: empty slug' )
eq( Slug.titleFromSlug( nil ), '', 'title: nil' )
eq( Slug.titleFromSlug( 'a--b' ), 'A B', 'title: a doubled hyphen does not make an empty word' )

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


-- Updating an existing album ---------------------------------------------------

-- Modelled on a real hand-edited album: manual ordering, a featured flag, and
-- per-photo captions. None of it is anything the plugin knows about.
local EXISTING = [[
---
date: 2026-08-25
title: Best Of
sort_by: Params.weight
description: A curated set of favorites.
featured: true
menu:
  main:
    weight: 20
resources:
  - src: dolomites-16.jpg
    title: Dolomites, 2024
    params:
      weight: 10
      cover: true
  - src: rome-33.jpg
    title: Rome, 2024
    params:
      weight: 20
---

Some prose under the front matter.
]]

local merged = FrontMatter.merge( EXISTING, {
	date = '2026-09-01',
	title = 'Best Of 2026',
	description = 'A curated set of favorites.',
	categories = { 'travel' },
	cover = 'ignored-because-resources-exist.jpg',
} )

eq( merged:match( '\nsort_by: (.-)\n' ), 'Params.weight', 'merge keeps a manual sort order' )
eq( merged:match( '\nfeatured: (.-)\n' ), 'true', 'merge keeps an unknown scalar key' )
eq( merged:match( '\nmenu:\n  main:\n    weight: 20\n' ) ~= nil, true, 'merge keeps a nested block' )
eq( merged:match( 'title: Dolomites, 2024' ) ~= nil, true, 'merge keeps per-photo captions' )
eq( merged:match( 'cover: true' ) ~= nil, true, 'merge keeps the existing cover' )
eq( select( 2, merged:gsub( 'src:', '' ) ), 2, 'merge does not touch the resources list' )
eq( merged:match( '\ntitle: (.-)\n' ), '"Best Of 2026"', 'merge updates the title' )
eq( merged:match( '\ndate: (.-)\n' ), '2026-09-01', 'merge updates the date' )
eq( merged:match( '\ncategories: (.-)\n' ), '["travel"]', 'merge adds a key the file lacked' )
eq( merged:match( 'Some prose under the front matter.' ) ~= nil, true, 'merge keeps the body' )
eq( merged:match( '^%-%-%-\n' ) ~= nil, true, 'merge still opens with front matter' )

-- Key order is the file's own, so the diff stays small.
eq( merged:match( '\nsort_by:.*\nfeatured:' ) ~= nil, true, 'merge preserves key order' )

-- An empty field means "leave it alone", never "delete it": the dialog prefills
-- from the file, so clearing one there must not silently drop it here.
local kept = FrontMatter.merge( EXISTING, { title = 'X' } )
eq( kept:match( '\ndescription: (.-)\n' ), 'A curated set of favorites.', 'merge never deletes' )
eq( kept:match( '\ndate: (.-)\n' ), '2026-08-25', 'merge leaves an empty date alone' )

-- A file with no resources block does get one, since there is nothing to lose.
local bare = FrontMatter.merge( '---\ntitle: Bare\n---\n', { cover = 'bare-01.jpg' } )
eq( bare:match( 'resources:\n  %- src: (.-)\n' ), 'bare-01.jpg', 'merge adds resources when absent' )

eq( FrontMatter.merge( 'no front matter here\n', { title = 'X' } ), nil, 'merge refuses a file it cannot parse' )
eq( FrontMatter.parse( '---\ntitle: Unclosed\n' ), nil, 'parse refuses unterminated front matter' )

-- Prefilling the dialog ---------------------------------------------------------

local values = FrontMatter.readValues( [[
---
date: 2026-05-02
title: "Brussels & Co: \"day one\""
categories: ["travel", "2026"]
lat: 45.4408
lng: 12.3155
description: A trip.
---
]] )
eq( values.date, '2026-05-02', 'readValues: date' )
eq( values.title, 'Brussels & Co: "day one"', 'readValues: unquotes and unescapes the title' )
eq( values.categories, 'travel, 2026', 'readValues: categories become the dialog string' )
eq( values.lat, 45.4408, 'readValues: lat' )
eq( values.lng, 12.3155, 'readValues: lng' )
eq( values.description, 'A trip.', 'readValues: unquoted scalar' )
eq( values.hasResources, false, 'readValues: reports a missing resources block' )


-- Blocks the merge must not touch ----------------------------------------------
--
-- This is the failure the merge exists to prevent, and it used to be the one it
-- caused: a folded scalar came back from readValues as ">" and merge replaced
-- all three lines with `description: ">"`.

local FOLDED = '---\ntitle: Old\ndescription: >\n  a long description that\n  runs over two lines.\n---\n'

local foldedOut, foldedSkipped = FrontMatter.merge( FOLDED, {
	title = 'New', description = 'typed in the dialog',
} )
eq( foldedOut:match( 'description: >\n  a long description that\n  runs over two lines.\n' ) ~= nil,
	true, 'multi-line: a folded scalar survives byte for byte' )
eq( foldedOut:match( '\ntitle: (.-)\n' ), '"New"', 'multi-line: single-line keys are still updated' )
eq( table.concat( foldedSkipped, ',' ), 'description', 'multi-line: merge reports what it left alone' )

local foldedValues = FrontMatter.readValues( FOLDED )
eq( foldedValues.description, nil, 'multi-line: readValues hands the dialog nil, never ">"' )
eq( foldedValues.unmanaged.description, true, 'multi-line: readValues names the unmanaged key' )
eq( foldedValues.title, 'Old', 'multi-line: neighbouring single-line keys still read' )

-- A block-scalar header with nothing under it: #lines is 1, so only the header
-- pattern catches it.
local bareHeader = FrontMatter.merge( '---\ndescription: >\n---\n', { description = 'x' } )
eq( bareHeader:match( '\ndescription: (.-)\n' ), '>', 'multi-line: a bare > header is left alone' )
eq( FrontMatter.merge( '---\ndescription: |-\n  kept\n---\n', { description = 'x' } )
	:match( 'description: |%-\n  kept\n' ) ~= nil, true, 'multi-line: literal block with chomp' )

-- List-form categories are a multi-line block like any other.
local listCats = FrontMatter.merge( '---\ncategories:\n  - travel\n  - 2026\n---\n',
	{ categories = { 'other' } } )
eq( listCats:match( 'categories:\n  %- travel\n  %- 2026\n' ) ~= nil, true,
	'multi-line: list-form categories survive' )

eq( select( 2, FrontMatter.merge( '---\ndescription: one line\n---\n', { description = 'two' } ) )[ 1 ],
	nil, 'multi-line: a single-line block is still replaced, and not reported as skipped' )

-- Line endings ------------------------------------------------------------------
--
-- Stripping the \r instead of writing it back would rewrite every line in the
-- file, turning an export into a whole-file diff on a Windows contributor's repo.

local CRLF = '---\r\ntitle: T\r\ndescription: old\r\n---\r\n\r\nBody text.\r\n'
eq( FrontMatter.parse( CRLF ) ~= nil, true, 'CRLF: parses at all' )
local crlfOut = FrontMatter.merge( CRLF, { title = 'T', description = 'new' } )
eq( select( 2, crlfOut:gsub( '[^\r]\n', '' ) ), 0, 'CRLF: no lone LF anywhere in the output' )
eq( crlfOut:match( 'Body text.' ) ~= nil, true, 'CRLF: the body survives' )
eq( crlfOut:match( 'description: (.-)\r' ), '"new"', 'CRLF: the value is still updated' )
eq( FrontMatter.merge( '---\ntitle: T\n---\n', { title = 'T' } ):find( '\r' ), nil,
	'CRLF: an LF file stays an LF file' )

-- sort_by ------------------------------------------------------------------------

eq( FrontMatter.merge( '---\ntitle: B\n---\n', { title = 'B' } ):match( 'sort_by: Name' ) ~= nil,
	true, 'sort_by is added when absent - the filenames exist to be the running order' )

-- Repeated top-level keys ---------------------------------------------------------

local dup = FrontMatter.merge( '---\ntitle: A\ndescription: x\ntitle: B\n---\n', { title = 'C' } )
eq( select( 2, dup:gsub( 'title:', '' ) ), 2, 'duplicate keys: still exactly two title lines out' )
eq( dup:match( '\ntitle: (.-)\n' ), '"C"', 'duplicate keys: the first one is the one updated' )
eq( dup:match( 'title: B' ) ~= nil, true, 'duplicate keys: the repeat is preserved where it was' )

-- FrontMatter.plan ------------------------------------------------------------------
--
-- The decision that can destroy a hand-written file, table-driven.

local function planOf( existing, album )
	local action, contents = FrontMatter.plan( existing, album or { title = 'X', date = '2026-01-01' } )
	return action, contents
end

eq( planOf( nil ), 'write', 'plan: no album yet -> render a fresh index.md' )
eq( planOf { indexExists = false }, 'write', 'plan: folder without an index.md -> render one' )
eq( planOf { indexExists = true, index = nil }, 'leave',
	'plan: index.md exists but could not be read -> touch nothing' )
eq( planOf { indexExists = true, index = 'no front matter here\n' }, 'leave',
	'plan: unparseable index.md -> touch nothing' )
eq( planOf { indexExists = true, index = '---\ntitle: Old\n---\n' }, 'merge',
	'plan: a real index.md -> merge' )

local _, planned = FrontMatter.plan( { indexExists = true, index = FOLDED }, { title = 'New' } )
eq( planned:match( 'runs over two lines' ) ~= nil, true, 'plan: merge output carries the fix through' )

local _, _, unreadableNotes = FrontMatter.plan( { indexExists = true, index = nil }, {} )
eq( unreadableNotes[ 1 ]:match( 'could not be read' ) ~= nil, true, 'plan: says why it did nothing' )

local _, _, skipNotes = FrontMatter.plan( { indexExists = true, index = FOLDED }, { title = 'N' } )
eq( #skipNotes, 2, 'plan: a skipped block earns its own summary line' )

--------------------------------------------------------------------------------

io.write( '\n', failures == 0 and 'all tests passed\n' or ( failures .. ' FAILURES\n' ) )
os.exit( failures == 0 and 0 or 1 )
