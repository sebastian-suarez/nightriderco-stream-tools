-- Native macOS inventory. Never asks a failed OBS capture for its properties.
local M = {}
function M.match(displays, role, remembered)
    local candidates = {}
    for _, display in ipairs(displays) do
        if (role == 'mac' and display.builtin) or
            (role == 'studio' and not display.builtin and display.name:lower():find('studio display', 1, true)) then
            candidates[#candidates + 1] = display
        end
    end
    for _, display in ipairs(candidates) do if display.uuid == remembered then return display end end
    if #candidates == 1 then return candidates[1] end
    -- Preserve a previously assigned external display when its name is unavailable.
    if role == 'studio' then
        for _, display in ipairs(displays) do
            if not display.builtin and display.uuid == remembered then return display end
        end
    end
    return nil
end

local native
local function initialize()
    local ffi = require('ffi')
    if ffi.os ~= 'OSX' then error('Display detection requires macOS.') end
    ffi.cdef[[
        int CGGetActiveDisplayList(uint32_t, uint32_t *, uint32_t *);
        int CGDisplayIsBuiltin(uint32_t);
        void *CGDisplayCreateUUIDFromDisplayID(uint32_t);
        void *CFUUIDCreateString(void *, void *);
        bool CFStringGetCString(void *, char *, long, uint32_t);
        void CFRelease(void *);
        void *objc_getClass(const char *);
        void *sel_registerName(const char *);
        void objc_msgSend(void);
    ]]
    local cg = ffi.load('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    local cs = ffi.load('/System/Library/Frameworks/ColorSync.framework/ColorSync')
    local cf = ffi.load('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    local appkit = ffi.load('/System/Library/Frameworks/AppKit.framework/AppKit')
    local objc = ffi.load('/usr/lib/libobjc.A.dylib')
    local send = ffi.cast('void *(*)(void *, void *)', objc.objc_msgSend)
    local send_arg = ffi.cast('void *(*)(void *, void *, void *)', objc.objc_msgSend)
    local send_index = ffi.cast('void *(*)(void *, void *, unsigned long)', objc.objc_msgSend)
    local send_count = ffi.cast('unsigned long (*)(void *, void *)', objc.objc_msgSend)
    local send_string = ffi.cast('void *(*)(void *, void *, const char *)', objc.objc_msgSend)
    local send_utf8 = ffi.cast('const char *(*)(void *, void *)', objc.objc_msgSend)
    local function sel(name) return objc.sel_registerName(name) end
    local function names()
        local result = {}
        local pool = send(send(objc.objc_getClass('NSAutoreleasePool'), sel('alloc')), sel('init'))
        local ok, problem = pcall(function()
            local screens = send(objc.objc_getClass('NSScreen'), sel('screens'))
            local key = send_string(objc.objc_getClass('NSString'), sel('stringWithUTF8String:'), 'NSScreenNumber')
            for index = 0, tonumber(send_count(screens, sel('count'))) - 1 do
                local screen = send_index(screens, sel('objectAtIndex:'), index)
                local description = send(screen, sel('deviceDescription'))
                local number = send_arg(description, sel('objectForKey:'), key)
                local name = send_utf8(send(screen, sel('localizedName')), sel('UTF8String'))
                if name ~= nil then result[tonumber(send_count(number, sel('unsignedIntegerValue')))] = ffi.string(name) end
            end
        end)
        send(pool, sel('drain'))
        if not ok then error(problem) end
        return result
    end
    native = function()
        local ids, count = ffi.new('uint32_t[64]'), ffi.new('uint32_t[1]')
        assert(cg.CGGetActiveDisplayList(64, ids, count) == 0, 'macOS could not enumerate displays.')
        local labels, displays = names(), {}
        for index = 0, tonumber(count[0]) - 1 do
            local id = tonumber(ids[index])
            local identity = cs.CGDisplayCreateUUIDFromDisplayID(id)
            if identity ~= nil then
                local value = cf.CFUUIDCreateString(nil, identity)
                cf.CFRelease(identity)
                if value ~= nil then
                    local buffer = ffi.new('char[128]')
                    local valid = cf.CFStringGetCString(value, buffer, 128, 0x08000100)
                    cf.CFRelease(value)
                    if valid then displays[#displays + 1] = {id = id, uuid = ffi.string(buffer), name = labels[id] or '', builtin = cg.CGDisplayIsBuiltin(id) ~= 0} end
                end
            end
        end
        return displays
    end
    -- Retain libraries for the lifetime of the returned native function.
    M._libraries = {cg, cs, cf, appkit, objc}
end
function M.list()
    if not native then initialize() end
    return native()
end
return M
