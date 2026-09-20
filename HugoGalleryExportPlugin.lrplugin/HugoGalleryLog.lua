--[[
Shared logger. Log location:
	~/Library/Logs/Adobe/Lightroom/LrClassicLogs/HugoGallery.log
]]

local LrLogger = import 'LrLogger'

local logger = LrLogger( 'HugoGallery' )
logger:enable( 'logfile' )

return logger
