--[[
The Plug-in Manager panel: where the site is configured, plus what the plug-in
is and where it came from.

These settings live here rather than in the Export dialog because they are
properties of the machine and the site, not of an album - set once per clone,
then never touched again.
]]

local LrDialogs = import 'LrDialogs'
local LrHttp    = import 'LrHttp'
local LrTasks   = import 'LrTasks'
local LrView    = import 'LrView'

local Prefs = require 'HugoAlbumPrefs'
local Repo  = require 'HugoAlbumRepo'
local log   = require 'HugoAlbumLog'

local PROJECT_URL = 'https://github.com/agiagoulas/hugo-gallery-lightroom-export-plugin'
local THEME_URL   = 'https://github.com/nicokaiser/hugo-theme-gallery'

local Info = {}

-- Repo.validatePaths stats the file system, which can yield, so it is never
-- called straight from an observer - see HugoAlbumExportDialogSections for the
-- longer version of why.
local function refreshStatus( propertyTable )
	LrTasks.startAsyncTask( function()
		local path = Repo.configuredPath()
		if path == '' then
			propertyTable.repoStatus = 'No site folder set - exporting is disabled until there is one.'
			return
		end
		local problem = Repo.validatePaths { slug = '' }
		propertyTable.repoStatus = problem
			or ( 'Looks good: albums go to ' .. path .. '/' .. Prefs.get( 'albumsFolder' ) .. '/' )
		log:info( 'site status: ' .. propertyTable.repoStatus )
	end )
end

function Info.sectionsForTopOfDialog( f, propertyTable )
	local bind = LrView.bind
	local share = LrView.share
	local prefs = Prefs.raw()

	local function pref( key )
		return bind { key = key, bind_to_object = prefs }
	end

	propertyTable.repoStatus = ''
	refreshStatus( propertyTable )
	for _, key in ipairs { 'repoPath', 'albumsFolder' } do
		prefs:addObserver( key, function() refreshStatus( propertyTable ) end )
	end

	local function link( title, url )
		return f:push_button {
			title = title,
			-- Opening a browser yields, so it needs a task of its own.
			action = function()
				LrTasks.startAsyncTask( function() LrHttp.openUrlInBrowser( url ) end )
			end,
		}
	end

	return {
		{
			title = 'Hugo site',

			f:row {
				f:static_text { title = 'Site folder:', alignment = 'right', width = share 'w' },
				f:edit_field {
					-- Bound straight to the preference, so it is stored the
					-- moment it is typed - there is no OK button here to save on.
					value = pref 'repoPath',
					immediate = true,
					fill_horizontal = 1,
					tooltip = 'The working copy of your Hugo site.',
				},
				f:push_button {
					title = 'Choose...',
					action = function()
						-- Modal panels yield too.
						LrTasks.startAsyncTask( function()
							local chosen = LrDialogs.runOpenPanel {
								title = 'Choose your Hugo site folder',
								canChooseFiles = false,
								canChooseDirectories = true,
								allowsMultipleSelection = false,
							}
							if chosen and chosen[ 1 ] then
								prefs.repoPath = chosen[ 1 ]
							end
						end )
					end,
				},
			},

			f:row {
				f:static_text { title = 'Albums in:', alignment = 'right', width = share 'w' },
				f:edit_field {
					value = pref 'albumsFolder',
					immediate = true,
					width_in_chars = 20,
					tooltip = 'Relative to the site folder, forward slashes. '
						.. '"content" if albums sit at the content root, "content/albums" if they '
						.. 'are grouped in a section.',
				},
				f:static_text { title = 'each album becomes <this>/<slug>/index.md' },
			},

			f:row {
				f:static_text { title = '', width = share 'w' },
				f:static_text { title = bind 'repoStatus', fill_horizontal = 1, height_in_lines = 2 },
			},

			f:row {
				f:static_text { title = '', width = share 'w' },
				f:push_button {
					title = 'Test git',
					-- Runs the two command shapes the plug-in builds and shows both
					-- verbatim. Mainly there so a Windows tester can confirm the
					-- quoting without a debugger - see docs/windows-port.md.
					action = function()
						LrTasks.startAsyncTask( function()
							local ok, report = Repo.diagnose()
							log:info( 'git diagnostics:\n' .. report )
							LrDialogs.message(
								ok and 'git works' or 'git did not run cleanly',
								report, ok and 'info' or 'critical' )
						end )
					end,
				},
				f:static_text { title = 'Checks that git can be run and that paths are quoted correctly.' },
			},
		},

		{
			title = 'Export',

			f:row {
				f:static_text { title = 'Long edge:', alignment = 'right', width = share 'w' },
				f:edit_field {
					value = pref 'longEdge',
					immediate = true,
					width_in_chars = 6,
					tooltip = 'Pixels, 240-10000. hugo-theme-gallery never serves more than '
						.. '1600px, so 2048 is invisible on the page while leaving headroom - '
						.. 'and small enough that the photos can live in git.',
				},
				f:static_text { title = 'px' },
				f:static_text { title = 'Quality:' },
				f:edit_field { value = pref 'jpegQuality', immediate = true, width_in_chars = 4 },
				f:static_text { title = '(1-100)' },
			},

			f:row {
				f:static_text { title = '', width = share 'w' },
				f:checkbox {
					title = 'Write lat/lng into the front matter',
					value = pref 'writeCoordinates',
				},
			},
			f:row {
				f:static_text { title = '', width = share 'w' },
				f:static_text {
					title = 'Only useful if your site has a map layout reading those keys.\n'
						.. 'They are not part of hugo-theme-gallery, so this is off by default.',
					height_in_lines = 2,
				},
			},
		},

		{
			title = 'About',

			f:static_text {
				title = 'Turns a Lightroom selection into a finished album on a Hugo site. It\n'
					.. 'exports the photos at the right size, names them in order, and writes\n'
					.. 'the front matter - the manual steps between "the edit is done" and\n'
					.. '"the album is on the site".',
				height_in_lines = 4,
			},

			f:spacer { height = 8 },

			f:static_text {
				title = 'An album titled Venice becomes venice/, holding venice-01.jpg through\n'
					.. 'venice-42.jpg and an index.md carrying the title, date, categories,\n'
					.. 'description and which photo is the cover. Filenames are zero-padded, so\n'
					.. 'the theme\'s sort_by: Name still orders them correctly past nine, and the\n'
					.. 'photos keep the EXIF the lightbox captions are built from.',
				height_in_lines = 5,
			},

			f:spacer { height = 8 },

			f:static_text {
				title = 'Your RAWs are untouched - these are exports like any other. And nothing\n'
					.. 'is pushed: on a git-deployed site pushing is the deploy, so that stays a\n'
					.. 'deliberate act in a terminal. The most this will do is create a branch\n'
					.. 'and commit, and only if you ask it to.',
				height_in_lines = 4,
			},

			f:spacer { height = 8 },

			f:static_text {
				title = 'Needs a Hugo site built on hugo-theme-gallery, in a git working copy.\n'
					.. 'Set the site folder above; everything else already has a sensible default.',
				height_in_lines = 2,
			},

			f:spacer { height = 8 },

			f:static_text { title = '© 2026 Alexander Giagoulas - MIT Licence' },

			f:spacer { height = 8 },

			f:row {
				link( 'Source and documentation', PROJECT_URL ),
				link( 'hugo-theme-gallery', THEME_URL ),
			},
		},
	}
end

return Info
