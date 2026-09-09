--[[
Hugo Gallery Export Plugin - exports the selected photos straight into a Hugo
site built on hugo-theme-gallery, as an album bundle with a ready-made index.md.

See ../README.md for installation and configuration.
]]

return {
	LrSdkVersion = 6.0,
	LrSdkMinimumVersion = 6.0,

	-- Lightroom's key for this plug-in's stored preferences. Changing it orphans
	-- them, so it is settled once and then left alone.
	LrToolkitIdentifier = 'com.giagoulas.hugoGalleryExportPlugin',
	LrPluginName = 'Hugo Gallery Export Plugin',

	LrExportServiceProvider = {
		title = 'Hugo Gallery',
		file = 'HugoGalleryExportServiceProvider.lua',
	},

	-- Shown in the Plug-in Manager: LrPluginInfoUrl becomes the "Plug-in author
	-- site" link, LrPluginInfoProvider supplies the panel above it.
	LrPluginInfoUrl = 'https://github.com/agiagoulas/hugo-gallery-lightroom-export-plugin',
	LrPluginInfoProvider = 'HugoGalleryPluginInfoProvider.lua',

	VERSION = { major = 0, minor = 1, revision = 0, build = 1 },
}
