-- Camera Switch-aware layout preparation. Loading only registers the hotkey.
local obs = obslua
local COMPONENT, CHAT = "Camera Switch", "[HTML] Chat Minimal"
local status, hotkey_id = "Ready. Layout controls each scene's Camera Switch instance.", nil
local specs = {"Workshop", "Gameplay"}
local function vec(x,y) local v=obs.vec2(); v.x=x; v.y=y; return v end
local function name(item) return obs.obs_source_get_name(obs.obs_sceneitem_get_source(item)) end
local function find(scene, wanted)
    local found, count = nil, 0
    local items=obs.obs_scene_enum_items(scene)
    if items then
        for _,item in ipairs(items) do if name(item)==wanted then found=item; count=count+1 end end
        obs.sceneitem_list_release(items)
    end
    assert(count<2, "Duplicate "..wanted..". Keep one instance in the scene.")
    return found
end
local function transform(item,x,y,width,height,crop)
    obs.obs_sceneitem_defer_update_begin(item)
    local c=obs.obs_sceneitem_crop();c.left=crop or 0;c.right=crop or 0;c.top=0;c.bottom=0
    obs.obs_sceneitem_set_crop(item,c)
    obs.obs_sceneitem_set_pos(item,vec(x,y));obs.obs_sceneitem_set_scale(item,vec(1,1))
    obs.obs_sceneitem_set_alignment(item,5);obs.obs_sceneitem_set_bounds_alignment(item,0)
    obs.obs_sceneitem_set_rot(item,0);obs.obs_sceneitem_set_bounds_type(item,obs.OBS_BOUNDS_STRETCH)
    obs.obs_sceneitem_set_bounds(item,vec(width,height))
    obs.obs_sceneitem_defer_update_end(item)
end
local function setup()
    local refs={}
    local function hold(n) local s=obs.obs_get_source_by_name(n);if s then refs[#refs+1]=s end;return s end
    local ok,problem=pcall(function()
        assert(not obs.obs_frontend_streaming_active() and not obs.obs_frontend_recording_active(),"Stop streaming and recording before preparing scenes.")
        local component=hold(COMPONENT)
        assert(component and obs.obs_scene_from_source(component),"Create the Camera Switch utility scene first.")
        local chat=hold(CHAT);assert(chat,"Missing source: "..CHAT)
        local video=obs.obs_video_info();assert(obs.obs_get_video_info(video),"OBS video is not ready.")
        local f=video.base_width/2560
        local crop=math.max(0,math.floor((obs.obs_source_get_width(component)-obs.obs_source_get_height(component)*576/331)/2+0.5))
        local plans={}
        -- Validate all target scenes before changing anything.
        for _,scene_name in ipairs(specs) do
            local source=hold(scene_name);local scene=source and obs.obs_scene_from_source(source)
            assert(scene,"Missing scene: "..scene_name)
            assert(not find(scene,"Webcam"),"Migrate the direct Webcam in "..scene_name.." to Camera Switch first.")
            local group=find(scene,"NRC Camera · "..scene_name)
            local direct=find(scene,COMPONENT)
            assert(not(group and direct),"Keep only one Camera Switch instance in "..scene_name..".")
            local child
            if group then
                assert(obs.obs_sceneitem_is_group(group),"NRC Camera must be a layout group.")
                local inside=obs.obs_sceneitem_group_get_scene(group)
                assert(not find(inside,"Webcam") and not find(inside,"NRC Camera Frame · "..scene_name),"Migrate the old camera group in "..scene_name.." first.")
                child=find(inside,COMPONENT)
            end
            plans[#plans+1]={scene=scene,name=scene_name,group=group,direct=direct,child=child,chat=find(scene,CHAT)}
        end
        for _,p in ipairs(plans) do
            -- Existing instances are already ready. Never reset their placement,
            -- visibility, size, or the globally selected camera/buddy mode.
            if not p.group and not p.direct then
                p.group=obs.obs_scene_add_group2(p.scene,"NRC Camera · "..p.name,true)
                assert(p.group,"Could not create the layout group.")
                local settings=obs.obs_source_get_private_settings(obs.obs_sceneitem_get_source(p.group))
                obs.obs_data_set_string(settings,"nrc_layout_owner","nightriderco-layout-v2")
                obs.obs_data_release(settings)
                obs.obs_sceneitem_set_pos(p.group,vec(52*f,992*f))
                obs.obs_sceneitem_set_scale(p.group,vec(f,f))
            end
            if p.group and not p.child then
                local info=obs.obs_transform_info();obs.obs_sceneitem_get_info2(p.group,info)
                local crop_before=obs.obs_sceneitem_crop();obs.obs_sceneitem_get_crop(p.group,crop_before)
                local visible=obs.obs_sceneitem_visible(p.group)
                obs.obs_sceneitem_defer_group_resize_begin(p.group)
                local item=obs.obs_scene_add(obs.obs_sceneitem_group_get_scene(p.group),component)
                assert(item,"Could not add Camera Switch.")
                transform(item,0,0,576,331,crop);obs.obs_sceneitem_set_visible(item,true)
                obs.obs_sceneitem_defer_group_resize_end(p.group)
                obs.obs_sceneitem_set_info2(p.group,info);obs.obs_sceneitem_set_crop(p.group,crop_before)
                obs.obs_sceneitem_set_visible(p.group,visible)
            end
            if not p.chat then
                local item=obs.obs_scene_add(p.scene,chat)
                assert(item,"Could not add the chat source.")
                obs.obs_sceneitem_set_pos(item,vec(2024*f,680*f));obs.obs_sceneitem_set_scale(item,vec(0.7*f,0.7*f))
            end
        end
    end)
    for i=#refs,1,-1 do obs.obs_source_release(refs[i]) end
    status=ok and "Ready. Scene Layout moves/hides local Camera Switch instances; the Camera Switch dock selects their shared content." or tostring(problem)
    obs.script_log(ok and obs.LOG_INFO or obs.LOG_WARNING,"[NRC Layout] "..status)
end
local function hotkey(pressed) if pressed then setup() end end
function script_description() return "<b>NIGHTRIDERCO Scene Layout · Camera Switch</b><br>Prepares local Camera Switch instances in Workshop and Gameplay. Existing positions and visibility stay unchanged. Webcam/Typing buddy selection belongs to the Camera Switch dock. Loading does not change scenes." end
function script_properties()
    local p=obs.obs_properties_create()
    obs.obs_properties_add_button(p,"prepare","Prepare Workshop + Gameplay",function(props) setup();local info=obs.obs_properties_get(props,"status");if info then obs.obs_property_set_description(info,status) end;return true end)
    obs.obs_properties_add_text(p,"status",status,obs.OBS_TEXT_INFO);return p
end
function script_load(settings)
    hotkey_id=obs.obs_hotkey_register_frontend("nrc_layout.setup","NIGHTRIDERCO: Prepare Workshop + Gameplay layout",hotkey)
    local bindings=obs.obs_data_get_array(settings,"setup_hotkey");obs.obs_hotkey_load(hotkey_id,bindings);obs.obs_data_array_release(bindings)
end
function script_save(settings)
    if hotkey_id then local b=obs.obs_hotkey_save(hotkey_id);obs.obs_data_set_array(settings,"setup_hotkey",b);obs.obs_data_array_release(b) end
end
function script_unload() if hotkey_id then obs.obs_hotkey_unregister(hotkey) end;hotkey_id=nil end
