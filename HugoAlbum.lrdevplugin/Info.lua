--[[
Hugo Album - exports the selected photos straight into a Hugo site built on
hugo-theme-gallery, as an album bundle with a ready-made index.md.

See ../README.md for installation and configuration.
]]

return {
	LrSdkVersion = 6.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = 'com.giagoulas.hugoalbum',
	LrPluginName = 'Hugo Album Export',

	LrExportServiceProvider = {
		title = 'Hugo Album',
		file = 'HugoAlbumExportServiceProvider.lua',
	},

	-- Shown in the Plug-in Manager: LrPluginInfoUrl becomes the "Plug-in author
	-- site" link, LrPluginInfoProvider supplies the panel above it.
	LrPluginInfoUrl = 'https://github.com/agiagoulas/hugo-gallery-lightroom-export-plugin',
	LrPluginInfoProvider = 'HugoAlbumPluginInfoProvider.lua',

	VERSION = { major = 0, minor = 1, revision = 0, build = 1 },
}
