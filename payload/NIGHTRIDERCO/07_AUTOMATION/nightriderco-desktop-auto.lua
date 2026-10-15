-- NIGHTRIDERCO Desktop Auto | OBS Studio Lua, no external dependencies.
-- One managed scene adapts to the dimensions of a capture YOU select.
-- macOS displays are matched to their existing capture sources; scenes/video settings stay intact.
-- Official API: https://docs.obsproject.com/scripting
--               https://docs.obsproject.com/reference-scenes
--               https://docs.obsproject.com/reference-sources

obs = obslua

local WIDTH, HEIGHT = 2560, 1440
local OWNER_KEY, ROLE_KEY = "nrc_desktop_owner", "nrc_desktop_role"
local POLL_MS, STABLE_SAMPLES = 500, 3
local config = nil
local status = "Choose an existing capture, then click Create / Update."
local timer_running = false
local frontend_registered = false
local candidate, candidate_count, applied = "", 0, ""
local last_status = ""
local setup_error = nil
local add_source_choices
local active_studio = nil
local hotkey_ids = {macbook = nil, studio = nil, detect = nil}
local display_state = {mac = {available = false, message = "Detecting display..."}, studio = {available = false, message = "Detecting display..."}}
local display_provider, detection_error, next_detection = nil, nil, 0
local detect_displays
local wipe_state, wipe_timer_running = nil, false
local cleanup_wipe
local WIPE_TICK_MS, WIPE_CUT_MS, WIPE_LAST_CUT_MS = 25, 600, 750
local LOADING_SAMPLE_MS, LOADING_SETTLE_MS, LOADING_TIMEOUT_MS = 100, 100, 12000
local managed_roles = {
    background = true, desktop = true, desktop_studio = true, webcam = true,
    mac = true, studio = true, shield = true, hold = true,
    display_wipe = true, chat_mac = true, chat_studio = true
}

local function hotkey_name(role)
    local instance = config and obs.obs_data_get_string(config, "instance_id") or ""
    return "nrc_desktop_auto." .. instance .. "." .. role
end

local function set_status(message)
    status = message
    if message ~= last_status then
        obs.script_log(obs.LOG_INFO, "[NRC Desktop Auto] " .. message)
        last_status = message
    end
end

local function setting(key)
    return config and obs.obs_data_get_string(config, key) or ""
end

local function yes(key)
    return config and obs.obs_data_get_bool(config, key) or false
end

local function using_studio()
    return active_studio == true and setting("studio_source") ~= ""
end

local function active_capture_name()
    return setting(using_studio() and "studio_source" or "desktop_source")
end

local function active_capture_label()
    return using_studio() and "Studio Display" or "MacBook Pro / primary"
end

local function trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

local function join(folder, file)
    return folder:gsub("[/\\]+$", "") .. "/" .. file
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function html_escape(value)
    return (value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function update_status_property(properties)
    if not properties then return end
    local property = obs.obs_properties_get(properties, "_status_info")
    if property then
        -- A button's true return refreshes these existing properties; it does
        -- not call script_properties again. Update the visible value directly.
        obs.obs_property_set_description(property, html_escape(setup_error or status))
    end
    local active = obs.obs_properties_get(properties, "_active_display_info")
    if active then
        obs.obs_property_set_description(active, html_escape("Active capture / Captura activa: " .. active_capture_label() .. " — " .. active_capture_name()))
    end
    local switch = obs.obs_properties_get(properties, "switch_display")
    if switch then
        obs.obs_property_set_enabled(switch, yes("enabled") and display_state[using_studio() and "mac" or "studio"].available and not wipe_state)
        obs.obs_property_set_description(switch, using_studio() and "Switch to MacBook Pro / Cambiar a MacBook Pro" or "Switch to Studio Display / Cambiar a Studio Display")
    end
end

local function private_value(source, key)
    local data = obs.obs_source_get_private_settings(source)
    if not data then return "" end
    local value = obs.obs_data_get_string(data, key)
    obs.obs_data_release(data)
    return value
end

local function mark_source(source, role)
    local data = obs.obs_source_get_private_settings(source)
    obs.obs_data_set_string(data, OWNER_KEY, setting("instance_id"))
    obs.obs_data_set_string(data, ROLE_KEY, role)
    obs.obs_data_release(data)
end

local function mark_item(item, role)
    local data = obs.obs_sceneitem_get_private_settings(item)
    obs.obs_data_set_string(data, OWNER_KEY, setting("instance_id"))
    obs.obs_data_set_string(data, ROLE_KEY, role)
    obs.obs_data_release(data)
    obs.obs_sceneitem_set_locked(item, true)
end

local function item_marker(item, key)
    local data = obs.obs_sceneitem_get_private_settings(item)
    local value = obs.obs_data_get_string(data, key)
    obs.obs_data_release(data)
    return value
end

local function uuid(source)
    if obs.obs_source_get_uuid then return obs.obs_source_get_uuid(source) or "" end
    return ""
end

local function owned_input(item, role, suffix, source_type)
    local source = item and obs.obs_sceneitem_get_source(item) -- borrowed
    if source and obs.obs_source_get_id(source) == source_type and
        obs.obs_source_get_name(source) == setting("built_scene") .. " | NRC Auto " .. suffix and
        private_value(source, OWNER_KEY) == setting("instance_id") and
        private_value(source, ROLE_KEY) == role then return source end
    return nil
end

local function is_video_input(source)
    if obs.obs_source_get_type(source) ~= obs.OBS_SOURCE_TYPE_INPUT then return false end
    local flag = obs.OBS_SOURCE_VIDEO
    return obs.obs_source_get_output_flags(source) % (flag * 2) >= flag
end

local function resolution_locked()
    local source = obs.obs_get_source_by_name(setting("built_scene") .. " | NRC Auto Background")
    if not source then return false end
    local data = obs.obs_source_get_settings(source)
    local until_time = obs.obs_data_get_int(data, "nrc_resolution_lock_until")
    obs.obs_data_release(data)
    obs.obs_source_release(source)
    return until_time > os.time()
end

local function canvas_factor()
    local info = obs.obs_video_info()
    if obs.obs_get_video_info(info) then return info.base_width / WIDTH end
    return 1
end

local function canvas_ok()
    local info = obs.obs_video_info()
    if not obs.obs_get_video_info(info) then return false, "OBS video is not ready." end
    if not ((info.base_width == 2560 and info.base_height == 1440) or (info.base_width == 1920 and info.base_height == 1080)) then
        return false, string.format("Choose a 1920x1080 or 2560x1440 OBS canvas. Current: %dx%d. Output resolution is not changed.", info.base_width, info.base_height)
    end
    return true
end

local function configuration_key(template_override)
    local key = table.concat({setting("managed_scene"), setting("desktop_source"),
        setting("webcam_source"), setting("asset_folder"), yes("animated") and "html" or "png"}, "\n")
    -- Preserve the old key exactly for existing single-capture installations.
    if setting("studio_source") ~= "" then key = key .. "\nStudio: " .. setting("studio_source") end
    if yes("use_stinger") then key = key .. "\nNative display wipe: 60fps" end
    if yes("chat_enabled") then key = key .. "\nChat template: " .. (template_override or setting("chat_template_source")) end
    return key
end

local function built_chat_template()
    return setting("built_key"):match("\nChat template: ([^\n]*)$")
end

local function recover_implicit_template()
    if not config or not yes("chat_enabled") or obs.obs_data_has_user_value(config, "chat_template_source") then return end
    local built_template = built_chat_template()
    -- Restore only a default omitted by OBS JSON serialization, and only if
    -- this is the sole effective key difference. Explicit selections, including
    -- an empty selection, are user changes and must never be silently replaced.
    if built_template and built_template ~= "" and configuration_key(built_template) == setting("built_key") then
        obs.obs_data_set_string(config, "chat_template_source", built_template)
    end
end

local function configuration_mismatch_message(fallback)
    local built_template = built_chat_template()
    if yes("chat_enabled") and built_template and setting("chat_template_source") ~= built_template and
        configuration_key(built_template) == setting("built_key") then
        return "Chat template changed from '" .. built_template .. "' to '" .. setting("chat_template_source") ..
            "'. Restore '" .. built_template .. "' and refresh, or rebuild off program if this template change was intentional. Both displays were already configured."
    end
    return fallback
end

local function materialize_configuration(settings)
    -- OBS serializes user values, not defaults. Save every effective key input
    -- explicitly so source availability and default paths cannot alter a built
    -- setup after restarting OBS.
    for _, key in ipairs({"managed_scene", "desktop_source", "studio_source", "webcam_source", "asset_folder", "chat_template_source"}) do
        obs.obs_data_set_string(settings, key, setting(key))
    end
    for _, key in ipairs({"animated", "use_stinger", "chat_enabled", "enabled"}) do
        obs.obs_data_set_bool(settings, key, yes(key))
    end
    obs.obs_data_set_bool(settings, "use_studio", using_studio())
end

local function reset_samples()
    candidate, candidate_count, applied = "", 0, ""
end

local function vec(x, y)
    local value = obs.vec2()
    value.x, value.y = x, y
    return value
end

local function fit(item, x, y, width, height, native_coordinates)
    if not item then return end
    if not native_coordinates then
        local factor = canvas_factor()
        x, y, width, height = x * factor, y * factor, width * factor, height * factor
    end
    if obs.obs_sceneitem_defer_update_begin then obs.obs_sceneitem_defer_update_begin(item) end
    local crop = obs.obs_sceneitem_crop()
    crop.left, crop.top, crop.right, crop.bottom = 0, 0, 0, 0
    obs.obs_sceneitem_set_crop(item, crop)
    obs.obs_sceneitem_set_rot(item, 0)
    obs.obs_sceneitem_set_scale(item, vec(1, 1))
    -- Public OBS alignment bit flags: LEFT=1, TOP=4; Lua exports vary by build.
    obs.obs_sceneitem_set_alignment(item, 5)
    -- Center is the absence of alignment flags (0); OBS's Lua module does not
    -- export an OBS_ALIGN_CENTER constant on every supported build.
    obs.obs_sceneitem_set_bounds_alignment(item, 0)
    obs.obs_sceneitem_set_bounds_type(item, obs.OBS_BOUNDS_SCALE_INNER)
    obs.obs_sceneitem_set_bounds(item, vec(width, height))
    if obs.obs_sceneitem_set_bounds_crop then obs.obs_sceneitem_set_bounds_crop(item, false) end
    obs.obs_sceneitem_set_pos(item, vec(x, y))
    obs.obs_sceneitem_set_locked(item, true)
    if obs.obs_sceneitem_defer_update_end then obs.obs_sceneitem_defer_update_end(item) end
end

local function ensure_visibility(item, visible)
    if item and obs.obs_sceneitem_visible(item) ~= visible then
        obs.obs_sceneitem_set_visible(item, visible)
    end
end

local function select_capture_items(items, studio)
    -- Disable standby first so even a covered switch never activates both
    -- captures together (display captures can include audio).
    if studio then
        ensure_visibility(items.desktop, false)
        ensure_visibility(items.desktop_studio, true)
    else
        ensure_visibility(items.desktop_studio, false)
        ensure_visibility(items.desktop, true)
    end
end

local function arrange_generated_layout(items)
    -- Only our generated visual layers move. User-added items keep their own
    -- identity, state and order relative to each other above this layout.
    local position = 0
    for _, role in ipairs({"background", "desktop", "desktop_studio", "webcam", "mac", "studio", "chat_mac", "chat_studio"}) do
        local item = items[role]
        if item then
            if obs.obs_sceneitem_get_order_position(item) ~= position then
                obs.obs_sceneitem_set_order_position(item, position)
            end
            position = position + 1
        end
    end
end

-- Returns borrowed scene items, valid while the caller holds the scene source.
-- Unmarked user additions are allowed and remain completely user-controlled.
-- Foreign/tampered Desktop Auto markers are rejected rather than overwritten.
local function scene_items(scene)
    local items = obs.obs_scene_enum_items(scene)
    local by_role, problem, user_items = {}, nil, {}
    if items then
        for _, item in ipairs(items) do
            local role = item_marker(item, ROLE_KEY)
            local owner = item_marker(item, OWNER_KEY)
            if owner == "" and role == "" then
                user_items[#user_items + 1] = item
            elseif owner ~= setting("instance_id") or not managed_roles[role] then
                problem = "A Desktop Auto item has a foreign or changed owner/role marker. Restore that managed item, or choose a new managed scene name."
            elseif by_role[role] then
                problem = "The managed scene contains duplicate Desktop Auto items. Restore the managed items, or choose a new scene name."
            else
                by_role[role] = item
            end
        end
        obs.sceneitem_list_release(items)
    end
    return by_role, problem, user_items
end

-- Adopt only a completed, marked replacement of this script's own webcam item.
-- Preserve unrelated settings and never change another scene's sources here.
local function adopt_camera_switch()
    if not config or setting("webcam_source") ~= "Webcam" or setting("built_scene") == "" then return end
    local source = obs.obs_get_source_by_name(setting("built_scene"))
    if not source then return end
    local scene = obs.obs_scene_from_source(source)
    local items, issue
    if scene then items, issue = scene_items(scene) end
    if items and not issue and items.webcam then
        local component = obs.obs_sceneitem_get_source(items.webcam)
        local marker = item_marker(items.webcam, "nrc_camera_switch_migrated")
        if obs.obs_source_get_name(component) == "Camera Switch" and
            obs.obs_source_get_type(component) == obs.OBS_SOURCE_TYPE_SCENE and marker == "v1" then
            local was_current = setting("built_key") == configuration_key()
            obs.obs_data_set_string(config, "webcam_source", "Camera Switch")
            obs.obs_data_set_string(config, "built_webcam_uuid", uuid(component))
            if was_current then obs.obs_data_set_string(config, "built_key", configuration_key()) end
        end
    end
    obs.obs_source_release(source)
end

local function publish_dock_metadata()
    if not config or setting("built_scene") == "" then return end
    local scene_source = obs.obs_get_source_by_name(setting("built_scene"))
    if not scene_source then return end
    local source_settings, metadata, background_source = nil, nil, nil
    local ok, problem = pcall(function()
        local scene = obs.obs_scene_from_source(scene_source)
        if not scene or private_value(scene_source, OWNER_KEY) ~= setting("instance_id") then return end
        local items, issue = scene_items(scene)
        local roles_complete = issue == nil
        for _, role in ipairs({"background", "desktop", "mac", "studio", "hold", "shield"}) do
            if not items[role] then roles_complete = false end
        end
        if setting("studio_source") ~= "" and not items.desktop_studio then roles_complete = false end
        if setting("webcam_source") ~= "" and not items.webcam then roles_complete = false end
        if yes("use_stinger") and not owned_input(items.display_wipe, "display_wipe", "Display Wipe", "ffmpeg_source") then roles_complete = false end
        if yes("chat_enabled") and (not owned_input(items.chat_mac, "chat_mac", "Chat Community", "browser_source") or
            not owned_input(items.chat_studio, "chat_studio", "Chat Minimal", "browser_source")) then roles_complete = false end
        -- A changed background item marker must not leave stale ready metadata.
        -- The actual input is still accepted only by its strict private owner,
        -- role, native Color type and reserved name below.
        background_source = obs.obs_get_source_by_name(setting("built_scene") .. " | NRC Auto Background")
        local source = background_source
        if not source or obs.obs_source_get_id(source) ~= "color_source_v3" or
            obs.obs_source_get_name(source) ~= setting("built_scene") .. " | NRC Auto Background" or
            private_value(source, OWNER_KEY) ~= setting("instance_id") or private_value(source, ROLE_KEY) ~= "background" then return end
        metadata = obs.obs_data_create()
        obs.obs_data_set_int(metadata, "schema", 1)
        obs.obs_data_set_bool(metadata, "resolution_aware", true)
        for _, field in ipairs({
            {"instance_id", setting("instance_id")}, {"scene_name", setting("built_scene")},
            {"primary_source", setting("desktop_source")}, {"studio_source", setting("studio_source")},
            {"mac_hotkey", hotkey_name("macbook")}, {"studio_hotkey", hotkey_name("studio")}, {"detect_hotkey", hotkey_name("detect")}
        }) do obs.obs_data_set_string(metadata, field[1], field[2]) end
        for _, role in ipairs({"mac", "studio"}) do
            obs.obs_data_set_bool(metadata, role .. "_available", display_state[role].available)
            obs.obs_data_set_string(metadata, role .. "_display_status", display_state[role].message)
        end
        obs.obs_data_set_string(metadata, "detection_error", detection_error or "")
        obs.obs_data_set_bool(metadata, "enabled", yes("enabled"))
        obs.obs_data_set_bool(metadata, "configured", roles_complete and setting("built_key") == configuration_key() and setting("desktop_source") ~= "" and setting("studio_source") ~= "")
        local json = obs.obs_data_get_json(metadata)
        source_settings = obs.obs_source_get_settings(source)
        if source_settings and obs.obs_data_get_string(source_settings, "nrc_desktop_dock") ~= json then
            -- This owned Color Source is the dock's discovery record. Preserve
            -- its complete existing settings, including width, height and color.
            -- Existing capture/webcam sources are never updated here.
            obs.obs_data_set_string(source_settings, "nrc_desktop_dock", json)
            obs.obs_source_update(source, source_settings)
        end
    end)
    if source_settings then obs.obs_data_release(source_settings) end
    if metadata then obs.obs_data_release(metadata) end
    if background_source then obs.obs_source_release(background_source) end
    obs.obs_source_release(scene_source)
    if not ok then obs.script_log(obs.LOG_WARNING, "[NRC Desktop Auto] Could not publish dock metadata: " .. tostring(problem)) end
end

local function hold(items)
    -- The selected capture stays active UNDER the opaque hold page so macOS can
    -- initialize it. No capture target is changed or activated in other scenes.
    -- A native opaque color shield also covers Chromium page startup/failure.
    if items.shield then
        local info = obs.obs_video_info()
        local width, height = WIDTH, HEIGHT
        if obs.obs_get_video_info(info) and info.base_width > 0 and info.base_height > 0 then
            width, height = info.base_width, info.base_height
        end
        fit(items.shield, 0, 0, width, height, true)
        -- Remain opaque across the entire canvas even if video settings were
        -- changed to an unsupported canvas aspect ratio after setup.
        obs.obs_sceneitem_set_bounds_type(items.shield, obs.OBS_BOUNDS_STRETCH)
        ensure_visibility(items.shield, true)
        obs.obs_sceneitem_set_order(items.shield, obs.OBS_ORDER_MOVE_TOP)
    end
    if items.hold then
        ensure_visibility(items.hold, true)
        obs.obs_sceneitem_set_order(items.hold, obs.OBS_ORDER_MOVE_TOP)
    end
    ensure_visibility(items.mac, false)
    ensure_visibility(items.studio, false)
    ensure_visibility(items.chat_mac, false)
    ensure_visibility(items.chat_studio, false)
    -- Webcam sources may also carry microphone audio. Keep them active under
    -- the opaque cover instead of interrupting audio while checking a display.
    ensure_visibility(items.webcam, true)
    -- Only the chosen capture initializes under the cover; standby stays hidden.
    select_capture_items(items, using_studio())
end

local function with_managed_scene(callback)
    local source = obs.obs_get_source_by_name(setting("built_scene"))
    if not source then return false, "Managed scene not found. Click Create / Update." end
    local scene = obs.obs_scene_from_source(source)
    if not scene or private_value(source, OWNER_KEY) ~= setting("instance_id") then
        obs.obs_source_release(source)
        return false, "Scene ownership does not match. Click Create / Update with a new scene name."
    end
    local ok, result, detail = pcall(callback, scene)
    obs.obs_source_release(source)
    if not ok then return false, tostring(result) end
    return result, detail
end

local function show_hold()
    with_managed_scene(function(scene)
        local items = scene_items(scene)
        -- Even if extra items were added, use our own opaque hold if available.
        hold(items)
        return true
    end)
end

-- Only the two configured, identity-checked capture sources may be rebound.
-- Query CoreGraphics/AppKit instead of OBS capture properties: failed macOS
-- list serialization in obs-websocket can crash on null property strings.
detect_displays = function(force)
    if not config or not yes("enabled") or configuration_key() ~= setting("built_key") or resolution_locked() then return end
    local time = obs.os_gettime_ns() / 1000000
    if not force and time < next_detection then return end
    next_detection = time + 2000
    if not display_provider then
        local ok, provider = pcall(dofile, join(script_path(), "nrc-displays.lua"))
        if ok then display_provider = provider else detection_error = tostring(provider) end
    end
    local ok, displays = false, detection_error
    if display_provider then ok, displays = pcall(display_provider.list) end
    if ok then detection_error = nil else detection_error = "Display detection failed. Press Detect / Refresh displays. " .. tostring(displays) end
    for _, role in ipairs({"mac", "studio"}) do
        local previous = display_state[role]
        local state = {available = false, message = detection_error or "Not connected / No conectada"}
        local name = setting(role == "studio" and "studio_source" or "desktop_source")
        local source = obs.obs_get_source_by_name(name)
        if source then
            local expected = setting(role == "studio" and "built_studio_uuid" or "built_desktop_uuid")
            if expected == "" or uuid(source) ~= expected or private_value(source, OWNER_KEY) ~= "" then
                state.message = "Capture source changed. Check Tools → Scripts."
            elseif obs.obs_source_get_id(source) ~= "screen_capture" then
                -- Keep support for manually selected window/other input kinds.
                state.available = obs.obs_source_get_width(source) > 0 and obs.obs_source_get_height(source) > 0
                state.message = state.available and "Capture available" or "Capture unavailable"
            elseif ok then
                local data = obs.obs_source_get_settings(source)
                local current = obs.obs_data_get_string(data, "display_uuid")
                if obs.obs_data_get_int(data, "type") ~= 0 then
                    state.message = "Choose Display Capture for this source."
                else
                    local display = display_provider.match(displays, role, current)
                    if display then
                        state.available, state.uuid = true, display.uuid
                        state.message = (display.name ~= "" and display.name or (role == "mac" and "MacBook Pro" or "Studio Display")) .. " · Connected"
                        local changed = current ~= display.uuid or not previous.available or previous.uuid ~= display.uuid
                        -- Restart once on reconnect (even with the same UUID),
                        -- or explicitly on refresh. Never restart every poll.
                        if changed or force then
                            if wipe_state then cleanup_wipe(nil, true) end
                            if (role == "studio") == using_studio() then show_hold(); reset_samples() end
                            obs.obs_data_set_string(data, "display_uuid", display.uuid)
                            -- Refresh ScreenCaptureKit's cached shareable content locally.
                            -- Do not serialize its property list through obs-websocket.
                            local properties = obs.obs_source_properties(source)
                            if properties then
                                local restart = obs.obs_properties_get(properties, "reactivate_capture")
                                if restart and obs.obs_property_enabled(restart) then obs.obs_property_button_clicked(restart, source) end
                                obs.obs_properties_destroy(properties)
                            end
                            obs.obs_source_update(source, data)
                        end
                    end
                end
                obs.obs_data_release(data)
            end
            obs.obs_source_release(source)
        else
            state.message = name == "" and "Capture not configured" or "Capture source missing"
        end
        display_state[role] = state
    end
    if wipe_state and (not display_state[wipe_state.target_studio and "studio" or "mac"].available or
        not display_state[wipe_state.old_studio and "studio" or "mac"].available) then
        cleanup_wipe(nil, true)
    end
    local current = using_studio() and "studio" or "mac"
    local fallback = using_studio() and "mac" or "studio"
    if not display_state[current].available then
        if wipe_state then cleanup_wipe(nil, true) end
        if display_state[fallback].available then
            active_studio = fallback == "studio"
            obs.obs_data_set_bool(config, "use_studio", active_studio)
            setup_error = nil
            reset_samples()
            show_hold()
            set_status("Active display disconnected. Switched to " .. active_capture_label() .. ".")
        else
            show_hold()
            reset_samples()
            set_status(detection_error or "No configured display is connected. Waiting for a display; use Detect / Refresh displays to check again.")
        end
    end
end

local function classify(width, height)
    if width <= 0 or height <= 0 then return nil, "Capture unavailable. Preview the managed scene; check the selected capture and macOS screen-recording permission." end
    local ratio = width / height
    -- Mac captures can omit the notch/menu area or use a scaled 16:10 desktop.
    -- These are shape families, not automatic display-identity detection.
    if ratio >= 1.45 and ratio <= 1.68 then return "mac" end
    if ratio >= 1.70 and ratio <= 1.86 then return "studio" end
    return nil, string.format("Unsupported capture shape: %dx%d (%.3f). Keep a full MacBook or 16:9 display/window capture.", width, height, ratio)
end

local function complete_items(items)
    if not items.desktop or not items.mac or not items.studio or not items.hold or not items.shield or not items.background then
        return false, "A managed item is missing. Click Create / Update to restore it."
    end
    if setting("webcam_source") ~= "" and not items.webcam then
        return false, "The managed webcam item is missing. Click Create / Update to restore it."
    end
    if setting("studio_source") ~= "" and not items.desktop_studio then
        return false, "The Studio Display capture item is missing. Select another program scene, then click Create / Update."
    end
    if yes("use_stinger") and not items.display_wipe then return false, "The native display wipe item is missing. Rebuild off program once to add it." end
    if yes("chat_enabled") and (not items.chat_mac or not items.chat_studio) then return false, "The managed chat items are missing. Rebuild off program once to add them." end
    if yes("use_stinger") and not owned_input(items.display_wipe, "display_wipe", "Display Wipe", "ffmpeg_source") then
        return false, "The native display wipe source has changed. Rebuild off program to restore it."
    end
    if yes("chat_enabled") and (not owned_input(items.chat_mac, "chat_mac", "Chat Community", "browser_source") or
        not owned_input(items.chat_studio, "chat_studio", "Chat Minimal", "browser_source")) then
        return false, "A managed chat source has changed. Rebuild off program to restore it."
    end
    return true
end

local function apply_layout(items, kind, selected_studio, keep_cover)
    local valid, problem = complete_items(items)
    if not valid then hold(items); return false, problem end
    arrange_generated_layout(items)
    if selected_studio == nil then selected_studio = using_studio() end
    local capture = items.desktop
    if selected_studio then capture = items.desktop_studio end
    if kind == "mac" then
        fit(capture, 40, 96, 1922, 1248)
        fit(items.webcam, 2000, 190, 520, 292.5)
    else
        fit(capture, 0, 0, WIDTH, HEIGHT)
        fit(items.webcam, 60, 1030, 560, 315)
    end
    fit(items.chat_mac, 2000, 550, 520, 794)
    fit(items.chat_studio, 1960, 544, 560, 800)
    ensure_visibility(items.background, true)
    select_capture_items(items, selected_studio)
    ensure_visibility(items.webcam, true)
    ensure_visibility(items.mac, kind == "mac")
    ensure_visibility(items.studio, kind == "studio")
    ensure_visibility(items.chat_mac, kind == "mac")
    ensure_visibility(items.chat_studio, kind == "studio")
    -- Hold is hidden last, once the correct transforms/overlay are in place.
    ensure_visibility(items.hold, false)
    ensure_visibility(items.shield, keep_cover == true)
    return true
end

local function poll_impl(force)
    if resolution_locked() then return end
    if not config or not yes("enabled") then return end
    if configuration_key() ~= setting("built_key") then
        show_hold()
        set_status(configuration_mismatch_message("Settings changed. Click Create / Update before using the managed scene."))
        return
    end
    detect_displays(false)
    if wipe_state or not display_state[using_studio() and "studio" or "mac"].available then return end
    local valid, error_message = canvas_ok()
    if not valid then
        show_hold()
        reset_samples()
        set_status(error_message)
        return
    end
    local desktop = obs.obs_get_source_by_name(active_capture_name())
    if not desktop then
        show_hold()
        reset_samples()
        set_status("Selected capture no longer exists. Select it again and click Create / Update.")
        return
    end
    local width, height = obs.obs_source_get_width(desktop), obs.obs_source_get_height(desktop)
    local identity = uuid(desktop)
    obs.obs_source_release(desktop)
    local expected_uuid = setting(using_studio() and "built_studio_uuid" or "built_desktop_uuid")
    if expected_uuid ~= "" and identity ~= expected_uuid then
        show_hold()
        reset_samples()
        set_status("The selected capture was replaced. Select the intended source and click Create / Update.")
        return
    end
    local kind, reason = classify(width, height)
    if not kind then
        show_hold()
        reset_samples()
        set_status(reason)
        return
    end
    if setting("webcam_source") ~= "" then
        local webcam = obs.obs_get_source_by_name(setting("webcam_source"))
        local webcam_ok = webcam ~= nil
        if webcam and setting("built_webcam_uuid") ~= "" then webcam_ok = uuid(webcam) == setting("built_webcam_uuid") end
        if webcam then obs.obs_source_release(webcam) end
        if not webcam_ok then
            show_hold()
            reset_samples()
            set_status("Selected webcam no longer matches. Select it again, or choose None, and click Create / Update.")
            return
        end
    end
    local signature = table.concat({identity, kind, tostring(width), tostring(height)}, ":")
    if force then candidate, candidate_count = signature, STABLE_SAMPLES end
    if signature ~= candidate then
        candidate, candidate_count = signature, 1
        applied = ""
        show_hold()
    elseif not force then
        candidate_count = math.min(candidate_count + 1, STABLE_SAMPLES)
    end
    if candidate_count < STABLE_SAMPLES then
        set_status(string.format("Measuring selected capture: %dx%d. Please wait...", width, height))
        return
    end
    if applied == signature and not force then
        -- Detect removal/collision of managed items without rewriting stable
        -- transforms on every poll.
        local healthy, problem = with_managed_scene(function(scene)
            local items, issue = scene_items(scene)
            if issue then hold(items); return false, issue end
            local complete, missing = complete_items(items)
            if not complete then hold(items) else arrange_generated_layout(items) end
            return complete, missing
        end)
        if not healthy then
            applied = ""
            show_hold()
            set_status(problem or "Managed scene needs repair. Click Create / Update.")
        end
        return
    end
    local success, message = with_managed_scene(function(scene)
        local items, problem = scene_items(scene)
        if problem then hold(items); return false, problem end
        return apply_layout(items, kind)
    end)
    if success then
        applied = signature
        set_status(string.format("Ready: %s (%s), %s layout, %dx%d. Managed scene: %s.",
            active_capture_label(), active_capture_name(), kind == "mac" and "MacBook" or "16:9 / Studio", width, height, setting("managed_scene")))
    else
        show_hold()
        set_status(message or "Could not apply the managed layout.")
    end
end

function poll_capture()
    local ok, message = pcall(poll_impl, false)
    if not ok then
        if cleanup_wipe then cleanup_wipe(nil, true) end
        show_hold()
        if timer_running then obs.timer_remove(poll_capture); timer_running = false end
        if config then obs.obs_data_set_bool(config, "enabled", false) end
        publish_dock_metadata()
        set_status("Automation stopped safely: " .. tostring(message) .. ". Check the Script Log, then click Create / Update.")
    end
    publish_dock_metadata()
end

local function update_timer()
    if timer_running then obs.timer_remove(poll_capture); timer_running = false end
    if yes("enabled") then obs.timer_add(poll_capture, POLL_MS); timer_running = true end
end

local function now_ms()
    return obs.os_gettime_ns() / 1000000
end

local function capture_snapshot(studio)
    if not display_state[studio and "studio" or "mac"].available then return nil, "The display is not connected.", true end
    local name = setting(studio and "studio_source" or "desktop_source")
    local source = obs.obs_get_source_by_name(name)
    if not source then return nil, "The selected capture is unavailable.", true end
    local identity = uuid(source)
    local width, height = obs.obs_source_get_width(source), obs.obs_source_get_height(source)
    local expected = setting(studio and "built_studio_uuid" or "built_desktop_uuid")
    local valid = is_video_input(source) and private_value(source, OWNER_KEY) == "" and
        (not obs.obs_source_get_uuid or (expected ~= "" and identity == expected))
    obs.obs_source_release(source)
    if not valid then return nil, "The selected capture was replaced. Rebuild off program with the intended source.", true end
    local kind, problem = classify(width, height)
    if not kind then return nil, problem, false end
    return {kind = kind, width = width, height = height,
        signature = table.concat({identity, kind, tostring(width), tostring(height)}, ":")}
end

local function owned_wipe_source(item)
    return owned_input(item, "display_wipe", "Display Wipe", "ffmpeg_source")
end

local function transition_health()
    if not yes("enabled") or configuration_key() ~= setting("built_key") then
        return false, configuration_mismatch_message("Settings changed. Rebuild off program before switching.")
    end
    local valid, problem = canvas_ok()
    if not valid then return false, problem end
    if setting("webcam_source") ~= "" then
        local source = obs.obs_get_source_by_name(setting("webcam_source"))
        local matches = source and (not obs.obs_source_get_uuid or uuid(source) == setting("built_webcam_uuid"))
        if source then obs.obs_source_release(source) end
        if not matches then return false, "The selected webcam no longer matches. Rebuild off program." end
    end
    return with_managed_scene(function(scene)
        local items, issue = scene_items(scene)
        if issue then return false, issue end
        local complete, missing = complete_items(items)
        if not complete then return false, missing end
        return true, obs.obs_source_showing(obs.obs_scene_get_source(scene))
    end)
end

local function loading_cover(items, studio)
    -- The browser hold stays hidden: this loading view is the native ice wipe
    -- over an opaque backdrop, including every transparent head/tail of a loop.
    fit(items.shield, 0, 0, WIDTH, HEIGHT)
    ensure_visibility(items.shield, true)
    obs.obs_sceneitem_set_order(items.shield, obs.OBS_ORDER_MOVE_TOP)
    ensure_visibility(items.hold, false)
    select_capture_items(items, studio)
    ensure_visibility(items.webcam, true)
end

local function start_loading_movie(scene, items)
    local source = owned_wipe_source(items.display_wipe)
    if not source then return false, "The owned loading movie is unavailable." end
    -- Upgrade the existing 1.5 source in place, once. Capture settings and the
    -- original chat template are never updated by this runtime change.
    local original = obs.obs_source_get_settings(source)
    local looping = original and obs.obs_data_get_bool(original, "looping")
    if not looping then
        local data = obs.obs_data_create()
        if original then obs.obs_data_apply(data, original) end
        obs.obs_data_set_bool(data, "looping", true)
        local ok, problem = pcall(obs.obs_source_update, source, data)
        obs.obs_data_release(data)
        if original then obs.obs_data_release(original); original = nil end
        if not ok then return false, tostring(problem) end
    end
    if original then obs.obs_data_release(original) end
    fit(items.display_wipe, 0, 0, WIDTH, HEIGHT)
    obs.obs_sceneitem_set_order(items.display_wipe, obs.OBS_ORDER_MOVE_TOP)
    ensure_visibility(items.display_wipe, true)
    obs.obs_source_media_restart(source)
    return true
end

local function record_ready_selection(studio, snapshot)
    active_studio = studio
    obs.obs_data_set_bool(config, "use_studio", using_studio())
    candidate, candidate_count, applied = snapshot.signature, STABLE_SAMPLES, snapshot.signature
    setup_error = nil
    set_status(string.format("Ready: %s (%s), %s layout, %dx%d. Managed scene: %s.",
        active_capture_label(), active_capture_name(), snapshot.kind == "mac" and "MacBook" or "16:9 / Studio",
        snapshot.width, snapshot.height, setting("managed_scene")))
end

cleanup_wipe = function(message, emergency)
    local previous = wipe_state
    wipe_state = nil
    if wipe_timer_running then obs.timer_remove(poll_wipe); wipe_timer_running = false end
    local restored = previous == nil or previous.revealed
    with_managed_scene(function(scene)
        local items, issue = scene_items(scene)
        if previous and not previous.revealed then
            -- Cancellation restores the previous committed display using its
            -- current geometry before any cover can be removed.
            active_studio = previous.old_studio
            obs.obs_data_set_bool(config, "use_studio", using_studio())
            local snapshot = capture_snapshot(previous.old_studio)
            local complete = complete_items(items)
            if snapshot and not issue and complete and not emergency then
                local success = apply_layout(items, snapshot.kind, previous.old_studio, false)
                if success then record_ready_selection(previous.old_studio, snapshot); restored = true end
            end
        end
        if emergency or not restored then hold(items) end
        local media = owned_wipe_source(items.display_wipe)
        if media then
            obs.obs_source_media_stop(media)
            ensure_visibility(items.display_wipe, false)
        end
        return true
    end)
    if emergency or not restored then reset_samples() end
    if message then setup_error = message; set_status(message) end
    return previous
end

local function stage_target(state, snapshot)
    local success, reason = with_managed_scene(function(scene)
        local items, issue = scene_items(scene)
        if issue then return false, issue end
        return apply_layout(items, snapshot.kind, state.target_studio, true)
    end)
    if success then
        state.staged_at = now_ms()
        state.snapshot = snapshot
    end
    return success, reason
end

local function reveal_target(state, snapshot)
    if not state.ready or not state.snapshot or snapshot.signature ~= state.snapshot.signature then return false, "The target capture changed before reveal." end
    local success, reason = with_managed_scene(function(scene)
        local items, issue = scene_items(scene)
        if issue then return false, issue end
        local complete, missing = complete_items(items)
        if not complete then return false, missing end
        -- Geometry has already been stable and shown under cover for 100 ms.
        -- Remove only our cover; user sources remain active throughout.
        ensure_visibility(items.hold, false)
        ensure_visibility(items.shield, false)
        return true
    end)
    if success then
        state.revealed = true
        state.revealed_at = now_ms()
        record_ready_selection(state.target_studio, snapshot)
    end
    return success, reason
end

local function wipe_tick_impl()
    local state = wipe_state
    if not state then return end
    local healthy, showing_or_problem = transition_health()
    if not healthy then cleanup_wipe(showing_or_problem or "Managed layout needs checking.", true); return end
    local showing, time = showing_or_problem, now_ms()
    if state.revealed then
        local snapshot, reason = capture_snapshot(state.target_studio)
        if not snapshot or snapshot.signature ~= applied then cleanup_wipe(reason or "The active capture changed. Checking its layout.", true); return end
        if not showing then cleanup_wipe(nil, false); return end
        -- A stalled decoder tail must not leave the dock busy forever after
        -- the validated target is already revealed and safe to keep on screen.
        if time - state.revealed_at >= 3000 then cleanup_wipe(nil, false); return end
    elseif time - state.started >= LOADING_TIMEOUT_MS then
        cleanup_wipe("The target display did not become ready within 12 seconds. Restored the previous display where available.", false)
        return
    end
    if not state.revealed then
        local snapshot, problem, permanent = capture_snapshot(state.target_studio)
        if not snapshot then
            if permanent then cleanup_wipe(problem, false); return end
            state.target_signature, state.samples, state.staged_at, state.ready = "", 0, nil, false
        else
            if not state.last_sample or time - state.last_sample >= LOADING_SAMPLE_MS then
                state.last_sample = time
                if snapshot.signature ~= state.target_signature then
                    state.target_signature, state.samples, state.staged_at, state.ready = snapshot.signature, 1, nil, false
                else state.samples = math.min(state.samples + 1, STABLE_SAMPLES) end
                if state.samples >= STABLE_SAMPLES and not state.staged_at then
                    local staged, reason = stage_target(state, snapshot)
                    if not staged then cleanup_wipe(reason or "Could not stage the target layout.", true); return end
                end
            end
            -- Detect changes between the scheduled samples too. They must not
            -- inherit readiness from an earlier geometry or capture identity.
            if snapshot.signature ~= state.target_signature then
                state.target_signature, state.samples, state.staged_at, state.ready = "", 0, nil, false
            elseif state.staged_at and time - state.staged_at >= LOADING_SETTLE_MS then state.ready = true end
            if state.ready and not showing then
                local revealed, reason = reveal_target(state, snapshot)
                cleanup_wipe(revealed and nil or reason, not revealed)
                return
            end
        end
    end
    if not showing then
        -- Do not play the movie offscreen. The target continues its short
        -- covered warmup and commits directly once its geometry is ready.
        if state.media_started then
            with_managed_scene(function(scene)
                local items = scene_items(scene)
                local media = owned_wipe_source(items.display_wipe)
                if media then obs.obs_source_media_stop(media); ensure_visibility(items.display_wipe, false) end
                return true
            end)
            state.media_started, state.fresh_seen, state.last_media = false, false, nil
            state.playback_confirmed, state.media_requested_at = false, nil
        end
        return
    end
    if not state.media_started then
        local started, reason = with_managed_scene(function(scene)
            local items, issue = scene_items(scene)
            if issue then return false, issue end
            return start_loading_movie(scene, items)
        end)
        if not started then cleanup_wipe(reason or "Could not start the loading movie.", false); return end
        state.media_started, state.fresh_seen, state.last_media = true, false, nil
        state.playback_confirmed, state.media_requested_at = false, now_ms()
    end
    local clock, media_state
    local readable, reason = with_managed_scene(function(scene)
        local items = scene_items(scene)
        local media = owned_wipe_source(items.display_wipe)
        if not media then return false, "The owned loading movie is unavailable." end
        clock, media_state = obs.obs_source_media_get_time(media), obs.obs_source_media_get_state(media)
        return true
    end)
    if not readable or type(clock) ~= "number" then cleanup_wipe(reason or "The loading movie clock is unavailable.", false); return end
    if not state.playback_confirmed then
        -- Restart queues a native media action for the next video tick. The
        -- immediate getter can still report the previous STOPPED/NONE/ENDED
        -- state and clock tail; none of those proves this restart has failed.
        if media_state == obs.OBS_MEDIA_STATE_PLAYING and clock >= 0 and clock < 300 then
            state.playback_confirmed, state.fresh_seen, state.last_media = true, true, clock
        elseif time - state.media_requested_at >= 3000 then
            cleanup_wipe("The native loading movie did not start within 3 seconds. Keeping a verified layout where available.", false)
            return
        else return end
    end
    if state.revealed and media_state == obs.OBS_MEDIA_STATE_ENDED then cleanup_wipe(nil, false); return end
    if media_state == obs.OBS_MEDIA_STATE_ERROR or media_state == obs.OBS_MEDIA_STATE_STOPPED or media_state == obs.OBS_MEDIA_STATE_NONE or media_state == obs.OBS_MEDIA_STATE_ENDED then
        cleanup_wipe("The loading movie stopped unexpectedly. Keeping a verified layout where available.", false); return
    end
    if state.revealed then
        if clock >= 1100 or (state.last_media and clock < state.last_media) then cleanup_wipe(nil, false)
        else state.last_media = clock end
        return
    end
    -- Native loop clocks wrap to their beginning. A fresh <300 ms observation
    -- is required for every cycle; late windows simply wait for the next one.
    if state.last_media and clock < state.last_media then state.fresh_seen = false end
    if not state.fresh_seen and clock >= 0 and clock < 300 then state.fresh_seen = true end
    state.last_media = clock
    if state.ready and state.fresh_seen and clock >= WIPE_CUT_MS and clock <= WIPE_LAST_CUT_MS then
        local snapshot, problem = capture_snapshot(state.target_studio)
        if not snapshot or snapshot.signature ~= state.target_signature then
            if not snapshot then state.target_signature, state.samples, state.staged_at, state.ready = "", 0, nil, false end
            return
        end
        local revealed, failure = reveal_target(state, snapshot)
        if not revealed then cleanup_wipe(failure, true) end
    end
end

function poll_wipe()
    local ok, problem = pcall(wipe_tick_impl)
    if not ok then cleanup_wipe("Display loading stopped safely: " .. tostring(problem), false) end
end

local function begin_native_switch(target_studio)
    local healthy, showing_or_problem = transition_health()
    if not healthy then show_hold(); reset_samples(); return false, showing_or_problem end
    local state = {target_studio = target_studio, old_studio = using_studio(), started = now_ms(),
        samples = 0, target_signature = "", ready = false, revealed = false, media_started = false}
    wipe_state = state
    local covered, reason = with_managed_scene(function(scene)
        local items, issue = scene_items(scene)
        if issue then return false, issue end
        -- Always cover before enabling the target or updating/restarting media.
        loading_cover(items, target_studio)
        if showing_or_problem then
            local started, problem = start_loading_movie(scene, items)
            if not started then return false, problem end
            state.media_started = true
            state.playback_confirmed, state.media_requested_at = false, now_ms()
        end
        return true
    end)
    if not covered then cleanup_wipe(reason or "Could not cover the display switch.", false); return false, reason end
    obs.timer_add(poll_wipe, WIPE_TICK_MS)
    wipe_timer_running = true
    set_status("Loading the target display under the looping native ice wipe...")
    poll_wipe()
    return true
end

local function source_type_available(id)
    -- obs_enum_input_types exposes a C char** argument in OBS Lua; it is not a
    -- one-argument enumeration helper. Probe only the source types we need.
    local name = obs.obs_source_get_display_name(id)
    return name ~= nil and name ~= ""
end

local function chat_url_for(url, theme)
    local before_hash, fragment = url:match("^(.-)(#.*)$")
    before_hash, fragment = before_hash or url, fragment or ""
    local base, query = before_hash:match("^(.-)%?(.*)$")
    if not base or (base ~= "http://127.0.0.1:3377/overlay.html" and base ~= "http://localhost:3377/overlay.html") then return nil end
    local parts, has_theme, has_font = {}, false, false
    for part in query:gmatch("[^&]+") do
        local key = part:match("^([^=]+)")
        if key == "theme" then
            if not has_theme then parts[#parts + 1] = "theme=" .. theme end
            has_theme = true
        elseif key == "fontSize" then
            if not has_font then parts[#parts + 1] = "fontSize=24" end
            has_font = true
        else parts[#parts + 1] = part end
    end
    if not has_theme then return nil end
    if not has_font then parts[#parts + 1] = "fontSize=24" end
    return base .. "?" .. table.concat(parts, "&") .. fragment
end

local function read_chat_template()
    local source = obs.obs_get_source_by_name(setting("chat_template_source"))
    if not source then return nil, "Choose the existing local chat Browser Source as the template." end
    local data, result, problem
    if obs.obs_source_get_id(source) == "browser_source" and private_value(source, OWNER_KEY) == "" then
        data = obs.obs_source_get_settings(source)
        local url = data and obs.obs_data_get_string(data, "url") or ""
        if chat_url_for(url, "panel") then result = {url = url} end
    end
    if data then obs.obs_data_release(data) end
    obs.obs_source_release(source)
    if not result then problem = "The chat template must be a local chat Browser Source at port 3377, /overlay.html, with its theme query parameter. Its URL is not logged." end
    return result, problem
end

local function source_plan()
    local prefix = setting("managed_scene") .. " | NRC Auto "
    local extension = yes("animated") and ".html" or ".png"
    local overlay_type = yes("animated") and "browser_source" or "image_source"
    local plan = {
        -- Native shield must exist before any capture is added or rebuilt.
        {role = "shield", name = prefix .. "Opaque Shield", type = "color_source_v3"},
        {role = "background", name = prefix .. "Background", type = "color_source_v3"},
        {role = "mac", name = prefix .. "MacBook " .. (yes("animated") and "HTML" or "PNG"), type = overlay_type, file = join(setting("asset_folder"), (yes("chat_enabled") and "macbook-full-display-chat" or "macbook-full-display") .. extension)},
        {role = "studio", name = prefix .. "Studio " .. (yes("animated") and "HTML" or "PNG"), type = overlay_type, file = join(setting("asset_folder"), "studio-display" .. extension)},
        {role = "hold", name = prefix .. "Hold", type = "browser_source", file = join(script_path(), "capture-hold.html")}
    }
    if yes("use_stinger") then
        plan[#plan + 1] = {role = "display_wipe", name = prefix .. "Display Wipe", type = "ffmpeg_source", file = join(setting("asset_folder"), "../transitions/nightriderco-ice-wipe-QHD-60fps-alpha.mov")}
    end
    if yes("chat_enabled") then
        local template = read_chat_template()
        if template then
            plan[#plan + 1] = {role = "chat_mac", name = prefix .. "Chat Community", type = "browser_source", url = chat_url_for(template.url, "panel"), width = 520, height = 794}
            plan[#plan + 1] = {role = "chat_studio", name = prefix .. "Chat Minimal", type = "browser_source", url = chat_url_for(template.url, "minimal"), width = 560, height = 800}
        end
    end
    return plan
end

local function source_settings(plan)
    local data = obs.obs_data_create()
    if plan.url then
        local template = obs.obs_get_source_by_name(setting("chat_template_source"))
        if template then
            local original = obs.obs_source_get_settings(template)
            if original then obs.obs_data_apply(data, original); obs.obs_data_release(original) end
            obs.obs_source_release(template)
        end
    end
    if plan.type == "color_source_v3" then
        obs.obs_data_set_int(data, "width", WIDTH)
        obs.obs_data_set_int(data, "height", HEIGHT)
        -- OBS color-source settings use 0xAABBGGRR: opaque #0B1118.
        obs.obs_data_set_int(data, "color", 0xFF18110B)
    elseif plan.type == "ffmpeg_source" then
        obs.obs_data_set_bool(data, "is_local_file", true)
        obs.obs_data_set_string(data, "local_file", plan.file)
        obs.obs_data_set_bool(data, "looping", false)
        obs.obs_data_set_bool(data, "restart_on_activate", false)
        obs.obs_data_set_bool(data, "close_when_inactive", false)
        obs.obs_data_set_bool(data, "clear_on_media_end", true)
        obs.obs_data_set_bool(data, "hw_decode", false)
        obs.obs_data_set_bool(data, "full_decode", false)
        obs.obs_data_set_int(data, "speed_percent", 100)
    elseif plan.type == "browser_source" then
        obs.obs_data_set_bool(data, "is_local_file", plan.url == nil)
        if plan.url then obs.obs_data_set_string(data, "url", plan.url) else obs.obs_data_set_string(data, "local_file", plan.file) end
        obs.obs_data_set_int(data, "width", plan.width or WIDTH)
        obs.obs_data_set_int(data, "height", plan.height or HEIGHT)
        obs.obs_data_set_bool(data, "fps_custom", true)
        obs.obs_data_set_int(data, "fps", 60)
        obs.obs_data_set_bool(data, "reroute_audio", plan.url ~= nil)
        obs.obs_data_set_bool(data, "shutdown", false)
        obs.obs_data_set_bool(data, "restart_when_active", false)
        if not plan.url then obs.obs_data_set_string(data, "css", "body { background-color: rgba(0,0,0,0); margin: 0; overflow: hidden; }") end
    else
        obs.obs_data_set_string(data, "file", plan.file)
        obs.obs_data_set_bool(data, "unload", false)
    end
    return data
end

local function preflight()
    local valid, message = canvas_ok()
    if not valid then return nil, message end
    if trim(setting("managed_scene")) == "" then return nil, "Enter a managed scene name." end
    if setting("desktop_source") == "" then return nil, "Choose an existing display/window capture source." end
    if setting("desktop_source") == setting("webcam_source") then return nil, "Capture and webcam must be different sources." end
    if setting("studio_source") ~= "" and setting("studio_source") == setting("desktop_source") then return nil, "MacBook / primary and Studio Display captures must be different sources." end
    if setting("studio_source") ~= "" and setting("studio_source") == setting("webcam_source") then return nil, "Studio Display capture and webcam must be different sources." end
    if yes("chat_enabled") then
        if setting("chat_template_source") == setting("desktop_source") or setting("chat_template_source") == setting("studio_source") or setting("chat_template_source") == setting("webcam_source") then
            return nil, "Choose a separate existing chat Browser Source, not a display or webcam capture."
        end
        local template, chat_problem = read_chat_template()
        if not template then return nil, chat_problem end
    end
    local desktop = obs.obs_get_source_by_name(setting("desktop_source"))
    if not desktop then return nil, "Selected capture was not found. Refresh the source lists." end
    local desktop_ok = is_video_input(desktop) and private_value(desktop, OWNER_KEY) == ""
    obs.obs_source_release(desktop)
    if not desktop_ok then return nil, "Choose an existing, non-managed video input as the capture." end
    if setting("studio_source") ~= "" then
        local studio = obs.obs_get_source_by_name(setting("studio_source"))
        if not studio then return nil, "Selected Studio Display capture was not found. Refresh the source lists." end
        local studio_ok = is_video_input(studio) and private_value(studio, OWNER_KEY) == ""
        obs.obs_source_release(studio)
        if not studio_ok then return nil, "Choose an existing, non-managed video input for the Studio Display capture." end
    end
    if setting("webcam_source") ~= "" then
        local webcam = obs.obs_get_source_by_name(setting("webcam_source"))
        if not webcam then return nil, "Selected webcam was not found. Refresh the source lists." end
        local webcam_ok = (is_video_input(webcam) or (obs.obs_source_get_type(webcam) == obs.OBS_SOURCE_TYPE_SCENE and obs.obs_source_get_name(webcam) == "Camera Switch")) and private_value(webcam, OWNER_KEY) == ""
        obs.obs_source_release(webcam)
        if not webcam_ok then return nil, "Choose Camera Switch or an existing non-managed video input." end
    end
    local source = obs.obs_get_source_by_name(setting("managed_scene"))
    if source then
        local scene = obs.obs_scene_from_source(source)
        local owned = scene and private_value(source, OWNER_KEY) == setting("instance_id")
        local problem
        if owned then local ignored; ignored, problem = scene_items(scene) end
        local in_use = false
        if owned then
            -- obs_scene_add is not atomic from Lua. Rebuild only off program,
            -- including a managed scene nested inside another active scene.
            in_use = obs.obs_source_active and obs.obs_source_active(source) or false
            if obs.obs_frontend_get_current_scene then
                local current = obs.obs_frontend_get_current_scene()
                if current then
                    in_use = in_use or obs.obs_source_get_name(current) == setting("managed_scene")
                    obs.obs_source_release(current)
                end
            end
        end
        obs.obs_source_release(source)
        if not owned then return nil, "That scene/source name already exists and is not owned by this script. Choose a new managed scene name." end
        if problem then return nil, problem end
        if in_use then return nil, "To rebuild safely, select another program scene that does not use Desktop Auto (for example BRB), then click Create / Update. Automatic layout changes still work on air; only rebuilding needs this step." end
    end
    local plan = source_plan()
    for _, item in ipairs(plan) do
        if not source_type_available(item.type) then return nil, "Required OBS source type is unavailable: " .. item.type .. ". Enable OBS Browser / Image / Color Source support." end
        if item.file and not file_exists(item.file) then return nil, "Required file is missing: " .. item.file .. ". Keep 07_AUTOMATION beside 03_OBS, or choose the display-layouts folder." end
        local existing = obs.obs_get_source_by_name(item.name)
        if existing then
            local owned = private_value(existing, OWNER_KEY) == setting("instance_id") and private_value(existing, ROLE_KEY) == item.role
            local same_type = obs.obs_source_get_id(existing) == item.type
            obs.obs_source_release(existing)
            if not owned or not same_type then return nil, "An unrelated or incompatible source already uses the reserved name: " .. item.name .. ". Choose a new managed scene name." end
        end
    end
    -- Animated layouts reference these shared pack files locally.
    if yes("animated") then
        for _, file in ipairs({"display-layouts.css", "display-layouts.js", "../config.js"}) do
            if not file_exists(join(setting("asset_folder"), file)) then return nil, "Animated layout dependency is missing: " .. join(setting("asset_folder"), file) end
        end
    end
    return plan
end

local function build_scene()
    local plan, problem = preflight()
    if not plan then return false, problem end
    local held_sources, created_scene, scene_source = {}, nil, obs.obs_get_source_by_name(setting("managed_scene"))
    local function retain(source)
        held_sources[#held_sources + 1] = source
        return source
    end
    if scene_source then retain(scene_source) end
    local ok, message = pcall(function()
        if not scene_source then
            created_scene = obs.obs_scene_create(setting("managed_scene"))
            if not created_scene then error("OBS could not create the managed scene.") end
            scene_source = obs.obs_scene_get_source(created_scene)
            mark_source(scene_source, "scene")
        end
        local scene = obs.obs_scene_from_source(scene_source)
        local previous = scene_items(scene)
        local kept_shield, kept_hold = previous.shield, previous.hold
        hold(previous)
        local function add(source, role, below_cover)
            local item = obs.obs_scene_add(scene, source)
            if not item then error("Could not add managed item: " .. role) end
            -- Rebuilding is refused while this scene is on program. Keep every
            -- new item under the retained cover as well, including on failure.
            if below_cover then obs.obs_sceneitem_set_order(item, obs.OBS_ORDER_MOVE_BOTTOM) end
            mark_item(item, role)
            return item
        end
        local owned_sources = {}
        -- Create all resources before removing any old managed scene items.
        for _, item in ipairs(plan) do
            local source = obs.obs_get_source_by_name(item.name)
            if source then retain(source) end
            local data = source_settings(item)
            local action_ok, result = pcall(function()
                if source then obs.obs_source_update(source, data); return source end
                return obs.obs_source_create(item.type, item.name, data, nil)
            end)
            obs.obs_data_release(data)
            if not action_ok then error(result) end
            if not source then source = result; if source then retain(source) end end
            if not source then error("Could not create OBS source: " .. item.name) end
            mark_source(source, item.role)
            if item.role == "chat_mac" or item.role == "chat_studio" or item.role == "display_wipe" then
                -- Only these independent owned sources are muted. Shared chat
                -- templates, captures, webcams and user audio remain untouched.
                obs.obs_source_set_muted(source, true)
            end
            owned_sources[item.role] = source
            if item.role == "shield" then
                if not kept_shield then kept_shield = add(source, "shield", false) end
                fit(kept_shield, 0, 0, WIDTH, HEIGHT)
                ensure_visibility(kept_shield, true)
                obs.obs_sceneitem_set_order(kept_shield, obs.OBS_ORDER_MOVE_TOP)
                if kept_hold then obs.obs_sceneitem_set_order(kept_hold, obs.OBS_ORDER_MOVE_TOP) end
            end
        end
        local desktop = retain(obs.obs_get_source_by_name(setting("desktop_source")))
        if not desktop then error("Selected capture disappeared during setup.") end
        local studio
        if setting("studio_source") ~= "" then
            studio = retain(obs.obs_get_source_by_name(setting("studio_source")))
            if not studio then error("Selected Studio Display capture disappeared during setup.") end
        end
        local webcam
        if setting("webcam_source") ~= "" then
            webcam = retain(obs.obs_get_source_by_name(setting("webcam_source")))
            if not webcam then error("Selected webcam disappeared during setup.") end
        end
        local old = obs.obs_scene_enum_items(scene)
        if old then
            for _, item in ipairs(old) do
                local role = item_marker(item, ROLE_KEY)
                if item_marker(item, OWNER_KEY) == setting("instance_id") and role ~= "shield" and role ~= "hold" then
                    obs.obs_sceneitem_remove(item)
                end
            end
            obs.sceneitem_list_release(old)
        end
        -- Add upper content first and move each addition to the bottom. This
        -- produces background > desktop > webcam > overlays beneath the cover.
        local items = {}
        items.shield = kept_shield
        items.hold = kept_hold or add(owned_sources.hold, "hold", false)
        if owned_sources.display_wipe then
            items.display_wipe = add(owned_sources.display_wipe, "display_wipe", true)
            ensure_visibility(items.display_wipe, false)
            obs.obs_source_media_stop(owned_sources.display_wipe)
        end
        if owned_sources.chat_studio then items.chat_studio = add(owned_sources.chat_studio, "chat_studio", true) end
        if owned_sources.chat_mac then items.chat_mac = add(owned_sources.chat_mac, "chat_mac", true) end
        items.studio = add(owned_sources.studio, "studio", true)
        items.mac = add(owned_sources.mac, "mac", true)
        if webcam then items.webcam = add(webcam, "webcam", true) end
        if studio then items.desktop_studio = add(studio, "desktop_studio", true) end
        items.desktop = add(desktop, "desktop", true)
        items.background = add(owned_sources.background, "background", true)
        for _, role in ipairs({"background", "mac", "studio", "shield", "hold", "display_wipe"}) do fit(items[role], 0, 0, WIDTH, HEIGHT) end
        fit(items.chat_mac, 2000, 550, 520, 794)
        fit(items.chat_studio, 1960, 544, 560, 800)
        fit(items.desktop, 0, 0, WIDTH, HEIGHT)
        fit(items.desktop_studio, 0, 0, WIDTH, HEIGHT)
        hold(items)
        obs.obs_data_set_string(config, "built_scene", setting("managed_scene"))
        obs.obs_data_set_string(config, "built_key", configuration_key())
        obs.obs_data_set_string(config, "built_desktop_uuid", uuid(desktop))
        obs.obs_data_set_string(config, "built_studio_uuid", studio and uuid(studio) or "")
        obs.obs_data_set_string(config, "built_webcam_uuid", webcam and uuid(webcam) or "")
        obs.obs_data_set_bool(config, "enabled", true)
        materialize_configuration(config)
    end)
    if not ok and scene_source then
        pcall(function()
            local scene = obs.obs_scene_from_source(scene_source)
            if scene then local items = scene_items(scene); hold(items) end
        end)
    end
    for _, source in ipairs(held_sources) do obs.obs_source_release(source) end
    if created_scene then obs.obs_scene_release(created_scene) end
    if not ok then return false, tostring(message) end
    reset_samples()
    publish_dock_metadata()
    update_timer()
    return true
end

function create_or_update_button(properties, property)
    setup_error = nil
    if wipe_state then
        setup_error = "A display switch is in progress. Wait for it to finish before rebuilding."
        set_status(setup_error)
        update_status_property(properties)
        return true
    end
    local ok, success, message = pcall(build_scene)
    if not ok then success, message = false, tostring(success) end
    if success then
        set_status("Managed scene ready. Select or preview '" .. setting("managed_scene") .. "'; its layout adapts after 3 stable measurements.")
    else
        setup_error = message or "Setup could not be completed."
        if config and setting("built_scene") == "" then
            -- Nothing has ever been configured: stop the empty monitor instead
            -- of immediately replacing this useful error with "Settings changed".
            -- Existing valid automation continues after a rebuild refusal.
            obs.obs_data_set_bool(config, "enabled", false)
            update_timer()
        end
        set_status(setup_error)
    end
    update_status_property(properties)
    return true
end

function apply_now_button(properties, property)
    setup_error = nil
    if not yes("enabled") then
        set_status("Automation is disabled. Click Create / Update to enable it.")
    else
        if wipe_state then cleanup_wipe(nil, false) end
        reset_samples()
        show_hold()
        -- Still uses the normal stability delay; this button never bypasses it.
        poll_capture()
    end
    update_status_property(properties)
    return true
end

local function select_capture(target_studio, properties)
    local function refuse(message)
        setup_error = message
        set_status(message)
        update_status_property(properties)
        return true
    end
    if resolution_locked() then return refuse("Resolution switch in progress. Please wait.") end
    if wipe_state then return refuse("A display switch is already in progress. Wait for it to finish.") end
    if not yes("enabled") then return refuse("Automation is disabled. Click Create / Update before switching displays.") end
    if target_studio and setting("studio_source") == "" then return refuse("Choose an existing Studio Display capture, select another program scene, then click Create / Update once to add both captures.") end
    if setting("built_scene") == "" or configuration_key() ~= setting("built_key") then
        return refuse(configuration_mismatch_message("Both captures must be configured first. Select another program scene, then click Create / Update. After that, this switch works while on air."))
    end
    detect_displays(false)
    if not display_state[target_studio and "studio" or "mac"].available then
        return refuse(display_state[target_studio and "studio" or "mac"].message .. ". Display switching is disabled until detected.")
    end
    local target_name = setting(target_studio and "studio_source" or "desktop_source")
    local target = obs.obs_get_source_by_name(target_name)
    if not target then return refuse("The target capture is missing: " .. target_name .. ". Refresh the source lists and rebuild off program.") end
    local expected = setting(target_studio and "built_studio_uuid" or "built_desktop_uuid")
    local identity_ok = not obs.obs_source_get_uuid or (expected ~= "" and uuid(target) == expected)
    local target_ok = is_video_input(target) and private_value(target, OWNER_KEY) == "" and identity_ok
    obs.obs_source_release(target)
    if not target_ok then return refuse("The target capture was replaced or is not a supported input. Select the intended source and rebuild off program.") end
    local healthy, problem = with_managed_scene(function(scene)
        local items, issue = scene_items(scene)
        if issue then return false, issue end
        return complete_items(items)
    end)
    if not healthy then return refuse(problem or "The managed scene needs repair before switching. Click Create / Update off program.") end
    if target_studio == using_studio() then
        -- Explicit dock/hotkey commands are idempotent. Repeated dispatch must
        -- not toggle away or keep restarting the stability delay.
        setup_error = nil
        set_status("Selected capture remains " .. active_capture_label() .. " (" .. active_capture_name() .. ").")
        update_status_property(properties)
        return true
    end
    if yes("use_stinger") then
        setup_error = nil
        local started, reason = begin_native_switch(target_studio)
        if not started then return refuse(reason or "Wait until the current display layout is ready before switching.") end
        update_status_property(properties)
        return true
    end
    -- Both capture references already exist. Only the chosen item's visibility
    -- and layout change; no source settings or frontend scene are changed.
    active_studio = target_studio
    obs.obs_data_set_bool(config, "use_studio", active_studio)
    setup_error = nil
    reset_samples()
    show_hold()
    set_status("Switching to " .. active_capture_label() .. " (" .. active_capture_name() .. "). Checking capture dimensions...")
    poll_capture()
    update_status_property(properties)
    return true
end

function switch_display_button(properties, property)
    return select_capture(not using_studio(), properties)
end

function show_macbook_hotkey(pressed)
    if pressed then select_capture(false, nil) end
end

function show_studio_hotkey(pressed)
    if pressed then select_capture(true, nil) end
end

function detect_displays_hotkey(pressed)
    if not pressed then return end
    if wipe_state then return end
    setup_error = nil
    next_detection = 0
    detect_displays(true)
    poll_capture()
end

function refresh_button(properties, property)
    if not wipe_state then detect_displays(true) end
    if properties then
        for _, choice in ipairs({{"desktop_source", false}, {"studio_source", true}, {"webcam_source", true}, {"chat_template_source", true, true}}) do
            local list = obs.obs_properties_get(properties, choice[1])
            if list then
                obs.obs_property_list_clear(list)
                add_source_choices(list, choice[2], setting(choice[1]), choice[3], choice[1] == "webcam_source")
            end
        end
    end
    if yes("enabled") then poll_capture() end
    publish_dock_metadata()
    update_status_property(properties)
    return true
end

add_source_choices = function(property, optional, selected_name, browsers_only, allow_camera_switch)
    obs.obs_property_list_add_string(property, optional and "None / Ninguna" or "Choose a capture / Elegir captura", "")
    local sources = obs.obs_enum_sources()
    local names = {}
    if sources then
        for _, source in ipairs(sources) do
            if is_video_input(source) and private_value(source, OWNER_KEY) == "" and
                (not browsers_only or obs.obs_source_get_id(source) == "browser_source") then
                names[#names + 1] = obs.obs_source_get_name(source)
            end
        end
        obs.source_list_release(sources)
    end
    if allow_camera_switch then
        local component = obs.obs_get_source_by_name("Camera Switch")
        if component then
            if obs.obs_source_get_type(component) == obs.OBS_SOURCE_TYPE_SCENE then
                local found = false
                for _, name in ipairs(names) do if name == "Camera Switch" then found = true end end
                if not found then names[#names + 1] = "Camera Switch" end
            end
            obs.obs_source_release(component)
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do obs.obs_property_list_add_string(property, name, name) end
    -- Preserve a saved selection if its source was deleted/renamed. OBS would
    -- otherwise silently choose the first entry while rebuilding the dropdown.
    if selected_name and selected_name ~= "" then
        local found = false
        for _, name in ipairs(names) do if name == selected_name then found = true; break end end
        if not found then
            obs.obs_property_list_add_string(property, "Missing / No disponible: " .. selected_name, selected_name)
        end
    end
end

function script_description()
    return [[<b>NIGHTRIDERCO Desktop Auto 1.7.0</b><br>
    One managed QHD scene automatically fits your chosen capture and selects the matching MacBook or 16:9 overlay.
    Add both existing display captures once, then switch between them here or through the Desktop Auto dock while on air.<br>
    Una escena QHD ajusta tu captura. Añade ambas pantallas una vez y cambia entre ellas aquí durante el directo.<br><br>
    Use FHD (1920×1080) or 2K (2560×1440). Choose existing MacBook / primary and optional Studio Display captures plus an optional webcam, then click Create / Update.
    Keep this folder beside 03_OBS. Select the managed scene yourself.<br><br>
    To rebuild later, first select another program scene that does not use Desktop Auto. Normal capture-size changes still adapt while on air.<br><br>
    Add your own Overlays scene, Music, alerts or other sources directly to Desktop Auto. Their visibility, transforms, audio settings and order relative to each other stay under your control.<br>
    Añade tus propias escenas, música y alertas; sus ajustes y audio se conservan.<br><br>
    Version 1.7.0 detects connected MacBook and Studio displays every two seconds, repairs their capture targets, disables unavailable switches, and falls back to a connected display. Use Detect / Refresh displays in the dock to retry immediately.<br>
    La versión 1.6.2 conserva la configuración al reiniciar OBS y actualiza el estado del dock. Los cambios explícitos de plantilla se respetan; recarga el script.<br><br>
    The native loading wipe starts immediately and repeats while the target display warms up. A stable layout is revealed during the next opaque part of the wipe.<br><br>
    Optional Community chat on MacBook / Minimal chat on Studio uses independent owned sources. Enable new options and rebuild once off program to add their sources. The existing chat template stays unchanged.<br><br>
    Ready layouts are reused when you return to this scene. Changed or unavailable captures still use the holding screen. User additions and webcam audio remain active during display checks.<br><br>
    The script does not change capture targets, stream/output settings, other scenes, or the scene on air.
    A holding screen covers unavailable/unsupported captures. This is layout automation, not a privacy detector.]]
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "managed_scene", "NRC | Desktop Auto")
    obs.obs_data_set_default_string(settings, "desktop_source", "")
    obs.obs_data_set_default_string(settings, "studio_source", "")
    obs.obs_data_set_default_bool(settings, "use_studio", false)
    obs.obs_data_set_default_string(settings, "webcam_source", "")
    obs.obs_data_set_default_string(settings, "asset_folder", join(script_path(), "../03_OBS/display-layouts"))
    obs.obs_data_set_default_bool(settings, "animated", true)
    obs.obs_data_set_default_bool(settings, "use_stinger", false)
    obs.obs_data_set_default_bool(settings, "chat_enabled", false)
    -- Sources can load after scripts at OBS startup. Keep this default stable;
    -- a missing source remains a visible missing selection until it is loaded.
    obs.obs_data_set_default_string(settings, "chat_template_source", "[HTML] Chat Community")
    obs.obs_data_set_default_bool(settings, "enabled", false)
end

function script_properties()
    local properties = obs.obs_properties_create()
    obs.obs_properties_add_text(properties, "managed_scene", "Managed scene / Escena automática", obs.OBS_TEXT_DEFAULT)
    local desktop = obs.obs_properties_add_list(properties, "desktop_source", "MacBook Pro / Primary capture / Captura principal", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    add_source_choices(desktop, false, setting("desktop_source"))
    local studio = obs.obs_properties_add_list(properties, "studio_source", "Studio Display capture (optional) / Captura opcional", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    add_source_choices(studio, true, setting("studio_source"))
    local webcam = obs.obs_properties_add_list(properties, "webcam_source", "Camera Switch / camera source", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    add_source_choices(webcam, true, setting("webcam_source"), false, true)
    obs.obs_properties_add_path(properties, "asset_folder", "display-layouts folder / Carpeta", obs.OBS_PATH_DIRECTORY, nil, nil)
    obs.obs_properties_add_bool(properties, "animated", "Animated EN/ES overlays / Diseños animados EN/ES")
    obs.obs_properties_add_bool(properties, "use_stinger", "Native ice wipe between displays / Transición de hielo entre pantallas")
    obs.obs_properties_add_bool(properties, "chat_enabled", "Community / Minimal chat by display / Chat por pantalla")
    local chat = obs.obs_properties_add_list(properties, "chat_template_source", "Existing local chat template / Plantilla de chat local existente", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    add_source_choices(chat, true, setting("chat_template_source"), true)
    obs.obs_properties_add_text(properties, "_chat_template_info", "One template creates BOTH Community (MacBook) and Minimal (Studio). This is not the active display style. / Una plantilla crea ambos estilos; no selecciona el estilo activo.", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_bool(properties, "enabled", "Monitor managed scene / Supervisar escena")
    obs.obs_properties_add_button(properties, "refresh_sources", "Detect / Refresh displays / Detectar pantallas", refresh_button)
    obs.obs_properties_add_button(properties, "create_update", "Create / Update managed scene / Crear o actualizar", create_or_update_button)
    obs.obs_properties_add_button(properties, "apply_now", "Recheck layout now / Revisar diseño", apply_now_button)
    obs.obs_properties_add_button(properties, "switch_display", "Switch display / Cambiar pantalla", switch_display_button)
    obs.obs_properties_add_text(properties, "_active_display_info", "Active capture / Captura activa", obs.OBS_TEXT_INFO)
    local info = obs.obs_properties_add_text(properties, "_status_info", "Status (Refresh to update) / Estado", obs.OBS_TEXT_INFO)
    obs.obs_property_set_description(info, html_escape(setup_error or status))
    update_status_property(properties)
    return properties
end

function script_update(settings)
    next_detection = 0
    if wipe_state then cleanup_wipe(nil, false) end
    setup_error = nil
    obs.obs_data_addref(settings)
    if config then obs.obs_data_release(config) end
    config = settings
    -- This selection is controlled by the Switch button, not a settings field.
    -- Keep it authoritative across UI updates that may carry an older snapshot.
    if active_studio == nil then active_studio = obs.obs_data_get_bool(settings, "use_studio") end
    if setting("studio_source") == "" then active_studio = false end
    obs.obs_data_set_bool(config, "use_studio", active_studio)
    if setting("instance_id") == "" then
        obs.obs_data_set_string(config, "instance_id", "nrc-desktop-v1-" .. tostring(os.time()) .. "-" .. tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999)))
    end
    recover_implicit_template()
    adopt_camera_switch()
    reset_samples()
    if yes("enabled") then
        show_hold()
        if configuration_key() ~= setting("built_key") then
            set_status(configuration_mismatch_message("Choose sources and click Create / Update to apply these settings."))
        end
    else
        set_status("Automation disabled. The last layout stays in place. Click Create / Update to enable.")
    end
    if yes("use_stinger") then
        -- A reload can recover a movie/cover saved in the middle of a loading
        -- cycle. Clear only our owned media after the normal safety cover is up.
        cleanup_wipe(nil, false)
    end
    publish_dock_metadata()
    update_timer()
end

function on_frontend_event(event)
    -- At OBS startup, scripts can load before their scene sources. Retry
    -- discovery once the collection is ready, including when monitoring is off.
    if obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED and event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED then
        next_detection = 0
        adopt_camera_switch()
        publish_dock_metadata()
        if yes("use_stinger") and not yes("enabled") then cleanup_wipe(nil, false) end
    end
    if not yes("enabled") then return end
    local getter
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then getter = obs.obs_frontend_get_current_scene end
    if obs.OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED and event == obs.OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED then
        getter = obs.obs_frontend_get_current_preview_scene
    end
    if getter then
        local source = getter()
        local entering = source and obs.obs_source_get_name(source) == setting("built_scene")
        if source then obs.obs_source_release(source) end
        if entering then
            -- Monitoring continues offscreen. Reuse an already verified layout
            -- instead of adding a holding screen to every normal scene return.
            -- The regular poll still covers and debounces actual changes or
            -- failed capture/canvas/managed-item integrity checks.
            poll_capture()
        end
    elseif obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED and event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED then
        if wipe_state then cleanup_wipe(nil, true) end
        reset_samples()
        show_hold()
        if yes("use_stinger") then cleanup_wipe(nil, false) end
    end
end

local function valid_hotkey_id(id)
    -- The injected helper can return -1 for the invalid uint64 ID, while the
    -- exported constant may be represented as a large positive Lua number.
    return type(id) == "number" and id >= 0 and id ~= obs.OBS_INVALID_HOTKEY_ID
end

local function register_dock_hotkeys()
    if not obs.obs_hotkey_register_frontend then return end
    for _, spec in ipairs({
        {role = "macbook", callback = show_macbook_hotkey, label = "Show MacBook Pro", bindings = "hotkey_macbook_bindings"},
        {role = "studio", callback = show_studio_hotkey, label = "Show Studio Display", bindings = "hotkey_studio_bindings"},
        {role = "detect", callback = detect_displays_hotkey, label = "Detect / Refresh displays", bindings = "hotkey_detect_bindings"}
    }) do
        if not valid_hotkey_id(hotkey_ids[spec.role]) then
            local ok, id = pcall(obs.obs_hotkey_register_frontend, hotkey_name(spec.role),
                "NIGHTRIDERCO Desktop Auto | " .. setting("managed_scene") .. " | " .. spec.label, spec.callback)
            if ok and valid_hotkey_id(id) then
                hotkey_ids[spec.role] = id
                local bindings = obs.obs_data_get_array(config, spec.bindings)
                if bindings then
                    local loaded, problem = pcall(obs.obs_hotkey_load, id, bindings)
                    obs.obs_data_array_release(bindings)
                    if not loaded then obs.script_log(obs.LOG_WARNING, "[NRC Desktop Auto] Could not restore optional keyboard shortcut: " .. tostring(problem)) end
                end
            else
                obs.script_log(obs.LOG_WARNING, "[NRC Desktop Auto] Could not register the " .. spec.label .. " dock command: " .. tostring(id))
            end
        end
    end
end

local function save_hotkey_bindings(settings)
    if not obs.obs_hotkey_save then return end
    for _, spec in ipairs({
        {role = "macbook", key = "hotkey_macbook_bindings"},
        {role = "studio", key = "hotkey_studio_bindings"},
        {role = "detect", key = "hotkey_detect_bindings"}
    }) do
        if valid_hotkey_id(hotkey_ids[spec.role]) then
            local ok, bindings = pcall(obs.obs_hotkey_save, hotkey_ids[spec.role])
            if ok and bindings then
                local saved, problem = pcall(obs.obs_data_set_array, settings, spec.key, bindings)
                obs.obs_data_array_release(bindings)
                if not saved then obs.script_log(obs.LOG_WARNING, "[NRC Desktop Auto] Could not save optional keyboard shortcut: " .. tostring(problem)) end
            end
        end
    end
end

function script_load(settings)
    -- OBS normally calls script_update first; tolerate other callback ordering.
    if not config then script_update(settings) end
    if obs.obs_frontend_add_event_callback then
        obs.obs_frontend_add_event_callback(on_frontend_event)
        frontend_registered = true
    end
    register_dock_hotkeys()
    if yes("use_stinger") then
        if yes("enabled") then show_hold() end
        cleanup_wipe(nil, false)
    end
    publish_dock_metadata()
    update_timer()
end

function script_save(settings)
    if not config then return end
    materialize_configuration(settings)
    -- Persist button-created state and ownership as well as normal UI values.
    for _, key in ipairs({"instance_id", "built_scene", "built_key", "built_desktop_uuid", "built_studio_uuid", "built_webcam_uuid"}) do
        obs.obs_data_set_string(settings, key, setting(key))
    end
    obs.obs_data_set_bool(settings, "enabled", yes("enabled"))
    obs.obs_data_set_bool(settings, "use_studio", using_studio())
    save_hotkey_bindings(settings)
end

function script_unload()
    if wipe_state then cleanup_wipe(nil, false) end
    if timer_running then obs.timer_remove(poll_capture); timer_running = false end
    if frontend_registered and obs.obs_frontend_remove_event_callback then
        obs.obs_frontend_remove_event_callback(on_frontend_event)
        frontend_registered = false
    end
    if obs.obs_hotkey_unregister then
        -- OBS's injected Lua helper expects the callback, not its numeric ID.
        if valid_hotkey_id(hotkey_ids.macbook) then obs.obs_hotkey_unregister(show_macbook_hotkey) end
        if valid_hotkey_id(hotkey_ids.studio) then obs.obs_hotkey_unregister(show_studio_hotkey) end
        if valid_hotkey_id(hotkey_ids.detect) then obs.obs_hotkey_unregister(detect_displays_hotkey) end
    end
    hotkey_ids.macbook, hotkey_ids.studio, hotkey_ids.detect = nil, nil, nil
    -- Keep the last scene/layout intact. Removing the script removes automation,
    -- not user-visible assets or shared capture/webcam sources.
    if config then obs.obs_data_release(config); config = nil end
end
