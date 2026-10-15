-- Start the existing NIGHTRIDERCO local services whenever this scene collection loads.
local obs = obslua
local folder = script_path()
local status_path = folder .. "obs-status.json"
local waiting = false
local checks = 0

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function newly_started(services, name)
    if not services then return false end
    local service = obs.obs_data_get_obj(services, name)
    if not service then return false end
    local started = obs.obs_data_get_bool(service, "started")
        and obs.obs_data_get_bool(service, "ready")
    obs.obs_data_release(service)
    return started
end

local function refresh_started_sources(assets, chat)
    if not assets and not chat then return end
    local sources = obs.obs_enum_sources()
    if not sources then return end
    for _, source in ipairs(sources) do
        if obs.obs_source_get_id(source) == "browser_source" then
            local settings = obs.obs_source_get_settings(source)
            local url = obs.obs_data_get_string(settings, "url")
            local local_file = obs.obs_data_get_bool(settings, "is_local_file")
            local port = url:match("^http://127%.0%.0%.1:(%d+)/")
                or url:match("^http://localhost:(%d+)/")
            if not local_file and ((assets and port == "8765") or (chat and port == "3377")) then
                local properties = obs.obs_source_properties(source)
                if properties then
                    local refresh = obs.obs_properties_get(properties, "refreshnocache")
                    if refresh then
                        obs.obs_property_button_clicked(refresh, source)
                        obs.script_log(obs.LOG_INFO, "Refreshed " .. obs.obs_source_get_name(source))
                    end
                    obs.obs_properties_destroy(properties)
                end
            end
            obs.obs_data_release(settings)
        end
    end
    obs.source_list_release(sources)
end

local function check_status()
    checks = checks + 1
    local file = io.open(status_path, "r")
    if file then
        local json = file:read("*a")
        file:close()
        local status = obs.obs_data_create_from_json(json)
        if status then
            local state = obs.obs_data_get_string(status, "state")
            if state == "ready" or state == "error" then
                waiting = false
                obs.timer_remove(check_status)
                local services = obs.obs_data_get_obj(status, "services")
                refresh_started_sources(newly_started(services, "assets"), newly_started(services, "chat"))
                if services then obs.obs_data_release(services) end
                local level = obs.obs_data_get_bool(status, "ok") and obs.LOG_INFO or obs.LOG_ERROR
                obs.script_log(level, obs.obs_data_get_string(status, "message"))
                -- Persist the newly added script without closing OBS or interrupting a stream.
                obs.obs_frontend_save()
            end
            obs.obs_data_release(status)
        end
    end
    if waiting and checks >= 40 then
        waiting = false
        obs.timer_remove(check_status)
        obs.script_log(obs.LOG_ERROR, "Local server startup timed out. See " .. folder .. "logs/startup.log")
    end
end

local function start_services()
    if waiting then return false end
    os.remove(status_path)
    local command = "/usr/bin/python3 -B " .. shell_quote(folder .. "start-services.py")
        .. " --status-file " .. shell_quote(status_path)
        .. " >> " .. shell_quote(folder .. "obs-startup.log") .. " 2>&1 < /dev/null &"
    os.execute(command)
    waiting = true
    checks = 0
    obs.timer_add(check_status, 1000)
    obs.script_log(obs.LOG_INFO, "Checking NIGHTRIDERCO servers on 127.0.0.1 ports 8765, 3377, 17642 and 17643")
    return false
end

function script_description()
    return "NIGHTRIDERCO Local Servers\n\nAutomatically starts assets (8765), chat (3377), secure docks (17642), and resolution (17643) when this OBS scene collection loads. Existing servers are reused. All four services stay local to this Mac.\n\nNo Terminal window is required. Open Chat Studio at http://127.0.0.1:3377. Open Husky Typist separately for the live typing buddy.\n\nUse Start / check servers if a server is stopped while OBS is open. See the Script Log for the result."
end

function script_properties()
    local properties = obs.obs_properties_create()
    obs.obs_properties_add_button(properties, "start_services", "Start / check servers", start_services)
    return properties
end

function script_load(settings)
    start_services()
end

function script_unload()
    obs.timer_remove(check_status)
    waiting = false
    -- Keep the local servers available to other OBS collections and browser previews.
end
