--[[
Shared logger.

On Lightroom Classic 14+ the file lands in

	~/Library/Logs/Adobe/Lightroom/LrClassicLogs/HugoAlbum.log

not in ~/Documents/, which is where older tutorials point and the reason
LrLogger is so often reported as "broken". Tail it while iterating:

	tail -f ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/HugoAlbum.log
]]

local LrLogger = import 'LrLogger'

local logger = LrLogger( 'HugoAlbum' )
logger:enable( 'logfile' )

return logger
