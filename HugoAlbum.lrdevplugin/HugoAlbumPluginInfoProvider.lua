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
		},

		{
			title = 'Export',

			f:row {
				f:static_text { title = 'Long edge:', alignment = 'right', width = share 'w' },
				f:edit_field {
					value = pref 'longEdge',
					immediate = true,
					width_in_chars = 6,
					tooltip = 'Pixels. hugo-theme-gallery never serves more than 1600px, so 2048 '
						.. 'is invisible on the page while leaving headroom - and small enough '
						.. 'that the photos can live in git.',
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
				title = 'Exports the selected photos into your Hugo site as an album bundle,\n'
					.. 'with a ready-made index.md. Nothing is pushed: on a git-deployed site\n'
					.. 'pushing is the deploy, and that stays a deliberate act.',
				height_in_lines = 3,
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
