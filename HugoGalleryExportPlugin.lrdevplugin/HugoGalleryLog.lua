--[[
Shared logger.

On Lightroom Classic 14+ the file lands in

	~/Library/Logs/Adobe/Lightroom/LrClassicLogs/HugoGallery.log

not in ~/Documents/, which is where older tutorials point and the reason
LrLogger is so often reported as "broken". Tail it while iterating:

	tail -f ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/HugoGallery.log
]]

local LrLogger = import 'LrLogger'

local logger = LrLogger( 'HugoGallery' )
logger:enable( 'logfile' )

return logger
