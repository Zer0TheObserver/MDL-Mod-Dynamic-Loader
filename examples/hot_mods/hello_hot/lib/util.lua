local util = {}
function util.message(style)
    if style == 'long' then return 'heartbeat from a hot-loaded mod at ' .. os.date('%H:%M:%S') end
    return 'heartbeat'
end
return util
