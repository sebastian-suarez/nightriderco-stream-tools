-- Strict scene/source mock. It verifies mutation scope and explicit source/data refs.
local M = {}
M.OBS_ALIGN_LEFT=1; M.OBS_ALIGN_TOP=4; M.OBS_ALIGN_CENTER=0
M.OBS_BOUNDS_NONE=0; M.OBS_BOUNDS_SCALE_INNER=2;M.OBS_BOUNDS_STRETCH=1
M.OBS_SOURCE_TYPE_INPUT=0; M.OBS_SOURCE_VIDEO=1;M.OBS_SOURCE_AUDIO=2
M.OBS_FRONTEND_EVENT_SCENE_CHANGED=1;M.OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED=24
M.OBS_ORDER_MOVE_TOP=2; M.OBS_ORDER_MOVE_BOTTOM=3
M.OBS_COMBO_TYPE_LIST=1;M.OBS_COMBO_FORMAT_STRING=3;M.OBS_PATH_DIRECTORY=2
M.OBS_TEXT_DEFAULT=0;M.OBS_TEXT_INFO=3
M.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED=13;M.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP=25;M.OBS_FRONTEND_EVENT_EXIT=9
M.LOG_INFO=300;M.LOG_WARNING=200;M.LOG_ERROR=100
M.sources={};M.timers={};M.events={};M.logs={};M.calls={};M.data_refs=0;M.source_refs=0;M.scene_refs=0
M.canvas_w=2560;M.canvas_h=1440;M.allowed_owner=''
local function call(name,...)
 M.calls[#M.calls+1]={name=name,args={...}}
end
local function source_owned(s)
 return s and s.private and s.private.nrc_desktop_owner and s.private.nrc_desktop_owner==M.allowed_owner
end
local function mutation(s,name,...)
 assert(source_owned(s), 'Mutation outside managed owner: '..name..' source='..tostring(s and s.name))
 call(name,s,...)
end
local function itemmutation(i,name,...)
 assert(i and i.scene, 'missing scene item for '..name)
 mutation(i.scene.source,name,i,...)
end
function M.new_source(name,id,w,h)
 local s={name=name,id=id,width=w or 0,height=h or 0,private={},settings={},refs=0,uuid=name..':'..tostring({})}
 M.sources[name]=s;return s
end
function M.new_scene(name,owned)
 local s=M.new_source(name,'scene');local sc={source=s,items={},refs=0};s.scene=sc
 if owned then s.private.nrc_desktop_owner=M.allowed_owner;s.private.nrc_desktop_role='scene' end
 return sc
end
function M.obs_data_create() local t={};M.data_refs=M.data_refs+1;t._refs=1;return t end
function M.obs_data_addref(d) d._refs=(d._refs or 0)+1;M.data_refs=M.data_refs+1 end
function M.obs_data_release(d) assert(d and d._refs and d._refs>0,'bad data release'); d._refs=d._refs-1;M.data_refs=M.data_refs-1 end
function M.obs_data_set_string(d,k,v)d[k]=v end
function M.obs_data_set_bool(d,k,v)d[k]=v end
function M.obs_data_set_int(d,k,v)d[k]=v end
function M.obs_data_set_double(d,k,v)d[k]=v end
function M.obs_data_get_string(d,k)return d[k] or '' end
function M.obs_data_get_bool(d,k)return d[k] or false end
function M.obs_data_has_user_value(d,k)return d[k]~=nil end
function M.obs_data_get_int(d,k)return d[k] or 0 end
function M.obs_data_get_double(d,k)return d[k] or 0 end
function M.obs_data_set_default_string(d,k,v)if d[k]==nil then d[k]=v end end
function M.obs_data_set_default_bool(d,k,v)if d[k]==nil then d[k]=v end end
function M.obs_data_set_default_int(d,k,v)if d[k]==nil then d[k]=v end end
function M.obs_source_get_private_settings(s)
 local d=s.private;d._refs=(d._refs or 0)+1;M.data_refs=M.data_refs+1;return d
end
function M.obs_source_get_settings(s)
 local d=s.settings;d._refs=(d._refs or 0)+1;M.data_refs=M.data_refs+1;return d
end
function M.obs_get_source_by_name(n)
 local s=M.sources[n];if s then s.refs=s.refs+1;M.source_refs=M.source_refs+1 end;return s
end
function M.obs_source_get_ref(s)
 if s then s.refs=s.refs+1;M.source_refs=M.source_refs+1 end;return s
end
function M.obs_source_release(s)
 assert(s and s.refs>0,'bad source release '..tostring(s and s.name));s.refs=s.refs-1;M.source_refs=M.source_refs-1
end
function M.obs_source_active(s)return s.active or false end
function M.obs_source_showing(s)return s.showing or s.active or false end
function M.obs_source_get_type(s)return s.id=='scene' and 3 or M.OBS_SOURCE_TYPE_INPUT end
function M.obs_source_get_output_flags(s)return s.flags or M.OBS_SOURCE_VIDEO end
function M.obs_source_get_uuid(s)return s.uuid end
function M.obs_enum_input_types(...)error('Forbidden regression: actual installed SWIG obs_enum_input_types requires char ** outpointer and cannot be enumerated with a single Lua argument')end
function M.obs_source_get_display_name(id)
 local available={color_source_v3=true,browser_source=true,image_source=true,screen_capture=true,av_capture_input=true}
 if M.unavailable_type==id then return nil end
 return available[id] and ('Mock '..id) or nil
end
function M.obs_source_get_name(s)return s.name end
function M.obs_source_get_id(s)return s.id end
function M.obs_source_get_unversioned_id(s)return s.id end
function M.obs_source_get_width(s)return s.width end
function M.obs_source_get_height(s)return s.height end
function M.obs_source_create(id,name,settings,hotkeys)
 assert(not M.sources[name],'duplicate source name '..name)
 local s=M.new_source(name,id,settings and settings.width,settings and settings.height)
 for k,v in pairs(settings or {})do if k~='_refs' then s.settings[k]=v end end
 s.refs=1;M.source_refs=M.source_refs+1;call('source_create',s);return s
end
function M.obs_source_update(s,d)
 mutation(s,'source_update',d)
 for k,v in pairs(d or {})do if k~='_refs'then s.settings[k]=v end end
 s.width=s.settings.width or s.width;s.height=s.settings.height or s.height
end
function M.obs_source_remove(s)mutation(s,'source_remove');M.sources[s.name]=nil end
function M.obs_scene_create(name)
 assert(not M.sources[name], 'scene create collision')
 local sc=M.new_scene(name);sc.refs=1;M.scene_refs=M.scene_refs+1;call('scene_create',sc);return sc
end
function M.obs_scene_get_source(sc)return sc.source end
function M.obs_scene_from_source(s)return s and s.scene or nil end
function M.obs_scene_release(sc)assert(sc.refs>0,'bad scene release');sc.refs=sc.refs-1;M.scene_refs=M.scene_refs-1 end
function M.obs_scene_find_source(sc,name)
 for _,i in ipairs(sc.items)do if i.source.name==name then return i end end
end
M.obs_scene_find_source_recursive=M.obs_scene_find_source
function M.obs_scene_add(sc,s)
 mutation(sc.source,'scene_add',s)
 local i={scene=sc,source=s,visible=true,crop={left=0,right=0,top=0,bottom=0}};sc.items[#sc.items+1]=i;return i
end
function M.obs_scene_enum_items(sc)local r={};for _,v in ipairs(sc.items)do r[#r+1]=v end;return r end
function M.sceneitem_list_release(list)end
function M.obs_sceneitem_get_source(i)return i.source end
function M.obs_sceneitem_remove(i)
 itemmutation(i,'item_remove')
 for k,v in ipairs(i.scene.items)do if v==i then table.remove(i.scene.items,k);break end end
end
M.visibility_transitions={}
function M.obs_sceneitem_set_visible(i,v)
 itemmutation(i,'visible',v)
 if i.visible~=v then M.visibility_transitions[#M.visibility_transitions+1]={item=i,from=i.visible,to=v};i.source.activation_count=(i.source.activation_count or 0)+(v and 1 or -1)end
 i.visible=v
end
function M.obs_sceneitem_visible(i)return i.visible end
function M.obs_sceneitem_set_bounds_crop(i,v)itemmutation(i,'bounds_crop',v);i.bounds_crop=v end
function M.obs_sceneitem_set_pos(i,v)itemmutation(i,'pos',v);i.pos={x=v.x,y=v.y}end
function M.obs_sceneitem_set_scale(i,v)itemmutation(i,'scale',v);i.scale={x=v.x,y=v.y}end
function M.obs_sceneitem_set_rot(i,v)itemmutation(i,'rot',v);i.rot=v end
function M.obs_sceneitem_set_alignment(i,v)itemmutation(i,'align',v);i.align=v end
function M.obs_sceneitem_set_bounds_type(i,v)itemmutation(i,'bounds_type',v);i.bounds_type=v end
function M.obs_sceneitem_set_bounds_alignment(i,v)itemmutation(i,'bounds_align',v);i.bounds_align=v end
function M.obs_sceneitem_set_bounds(i,v)itemmutation(i,'bounds',v);i.bounds={x=v.x,y=v.y}end
function M.obs_sceneitem_set_crop(i,v)itemmutation(i,'crop',v);i.crop={left=v.left,right=v.right,top=v.top,bottom=v.bottom}end
function M.obs_sceneitem_set_order(i,v)
 itemmutation(i,'order',v);i.order=v
 for k,t in ipairs(i.scene.items)do if t==i then table.remove(i.scene.items,k);break end end
 if v==M.OBS_ORDER_MOVE_BOTTOM then table.insert(i.scene.items,1,i)else i.scene.items[#i.scene.items+1]=i end
end
function M.obs_sceneitem_get_order_position(i)for k,v in ipairs(i.scene.items)do if v==i then return k-1 end end;return -1 end
function M.obs_sceneitem_set_order_position(i,position)
 itemmutation(i,'order_position',position)
 for k,v in ipairs(i.scene.items)do if v==i then table.remove(i.scene.items,k);break end end
 table.insert(i.scene.items,math.min(#i.scene.items+1,math.max(1,position+1)),i)
end
function M.obs_sceneitem_set_locked(i,v)itemmutation(i,'locked',v);i.locked=v end
function M.obs_sceneitem_set_scale_filter(i,v)itemmutation(i,'scale_filter',v);i.scale_filter=v end
function M.obs_sceneitem_get_private_settings(i)
 i.private=i.private or {};i.private._refs=(i.private._refs or 0)+1;M.data_refs=M.data_refs+1;return i.private
end
function M.obs_sceneitem_defer_update_begin(i)itemmutation(i,'defer_begin')end
function M.obs_sceneitem_defer_update_end(i)itemmutation(i,'defer_end')end
function M.vec2()return{x=0,y=0}end
function M.obs_sceneitem_crop()return{left=0,right=0,top=0,bottom=0}end
function M.obs_video_info()return{}end
function M.obs_get_video_info(vi)vi.base_width=M.canvas_w;vi.base_height=M.canvas_h;return M.video_available~=false end
function M.obs_enum_sources()local l={};for _,s in pairs(M.sources)do l[#l+1]=s end;return l end
function M.source_list_release(l)end
function M.timer_add(f,ms)assert(not M.timers[f], 'duplicate timer');M.timers[f]=ms;call('timer_add',f,ms)end
function M.timer_remove(f)M.timers[f]=nil;call('timer_remove',f)end
function M.obs_frontend_add_event_callback(f)M.events[f]=true end
function M.obs_frontend_remove_event_callback(f)M.events[f]=nil end
function M.obs_frontend_set_current_scene(s)error('Forbidden program scene switching')end
function M.obs_frontend_set_current_preview_scene(s)error('Forbidden preview scene switching')end
function M.obs_frontend_get_current_scene()return M.obs_source_get_ref(M.current_scene)end
function M.obs_frontend_get_current_preview_scene()return M.obs_source_get_ref(M.current_preview)end
function M.script_log(level,msg)M.logs[#M.logs+1]={level=level,message=msg}end
function M.obs_properties_create()return{}end
function M.obs_properties_add_list(p,n,l,t,f)local pr={name=n,description=l};p[n]=pr;return pr end
function M.obs_properties_add_path(p,n,l,t,filter,default)local pr={name=n,description=l};p[n]=pr;return pr end
function M.obs_properties_add_bool(p,n,l)local pr={name=n,description=l};p[n]=pr;return pr end
function M.obs_properties_add_text(p,n,l,t)local pr={name=n,description=l};p[n]=pr;return pr end
function M.obs_properties_add_button(p,n,l,f)local pr={name=n,description=l,callback=f};p[n]=pr;return pr end
function M.obs_property_list_add_string(p,l,v)p[#p+1]={label=l,value=v}end
function M.obs_property_set_modified_callback(p,f)p.modified=f end
function M.obs_property_set_description(p,s)p.description=s end
function M.obs_property_set_long_description(p,s)p.long_description=s end
function M.obs_property_set_enabled(p,v)p.enabled=v end
function M.obs_property_set_visible(p,v)p.visible=v end
function M.obs_property_list_clear(p)for k in pairs(p)do if type(k)=='number'then p[k]=nil end end end
function M.obs_properties_get(p,n)return p[n]end
function M.assert_no_leaks()
 assert(M.data_refs==0,'Data ref leak '..M.data_refs)
 assert(M.source_refs==0,'Source ref leak '..M.source_refs)
 assert(M.scene_refs==0,'Scene ref leak '..M.scene_refs)
end
M.OBS_INVALID_HOTKEY_ID=18446744073709551615
M.hotkeys={};M.next_hotkey_id=0;M.array_refs=0
local function copy_fields(t)local r={};for k,v in pairs(t or {})do if k~='_refs'and k~='_is_array'then r[k]=v end end;return r end
function M.obs_data_array_create()M.array_refs=M.array_refs+1;return{_refs=1,_is_array=true}end
function M.obs_data_array_release(a)assert(a and a._refs>0,'bad array release');a._refs=a._refs-1;M.array_refs=M.array_refs-1 end
function M.obs_data_array_push_back(a,d)a[#a+1]=copy_fields(d)end
function M.obs_data_array_count(a)return #a end
function M.obs_data_array_item(a,index)local d=copy_fields(a[index+1]);d._refs=1;M.data_refs=M.data_refs+1;return d end
function M.obs_data_set_array(d,k,a)d[k]=copy_fields(a)end
function M.obs_data_get_array(d,k)if not d[k]then return nil end;local a=copy_fields(d[k]);a._refs=1;a._is_array=true;M.array_refs=M.array_refs+1;return a end
local function json_string(value)
 return '"'..value:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')..'"'
end
local function json_encode(value)
 if type(value)=='string'then return json_string(value)end
 if type(value)=='number'or type(value)=='boolean'then return tostring(value)end
 if type(value)=='table'then
  local r={};for k,v in pairs(value)do if k~='_refs'and k~='_is_array'then r[#r+1]=json_string(k)..':'..json_encode(v)end end;table.sort(r);return'{'..table.concat(r,',')..'}'
 end
 return'null'
end
function M.obs_data_get_json(d)return json_encode(d)end
function M.obs_hotkey_register_frontend(name,description,callback)
 assert(type(name)=='string'and type(description)=='string'and type(callback)=='function','hotkey helper args')
 if M.hotkey_registration_failure then return M.hotkey_registration_failure end
 for _,h in pairs(M.hotkeys)do assert(h.name~=name,'duplicate hotkey name')end
 local id=M.next_hotkey_id;M.next_hotkey_id=id+1;M.hotkeys[id]={name=name,description=description,callback=callback,bindings={}}
 return id
end
function M.obs_hotkey_unregister(callback)
 assert(type(callback)=='function','Lua injected unregister expects callback, not numeric ID')
 for id,h in pairs(M.hotkeys)do if h.callback==callback then M.hotkeys[id]=nil end end
end
function M.obs_hotkey_load(id,array)assert(type(id)=='number'and M.hotkeys[id],'invalid hotkey load ID');M.hotkeys[id].bindings=copy_fields(array)end
function M.obs_hotkey_save(id)
 assert(type(id)=='number'and M.hotkeys[id],'invalid hotkey save ID')
 local a=copy_fields(M.hotkeys[id].bindings);a._refs=1;a._is_array=true;M.array_refs=M.array_refs+1;return a
end
function M.press_hotkey(name,pressed)
 for _,h in pairs(M.hotkeys)do if h.name==name then return h.callback(pressed)end end;error('unknown hotkey '..name)
end
local prior_assert=M.assert_no_leaks
function M.assert_no_leaks()prior_assert();assert(M.array_refs==0,'Array ref leak '..M.array_refs)end

for _,name in ipairs({'obs_source_set_muted','obs_source_set_volume','obs_source_set_audio_mixers','obs_source_set_monitoring_type','obs_source_media_play_pause','obs_source_media_restart','obs_source_media_stop','obs_source_media_set_time','obs_source_set_enabled'})do M[name]=function()error('Forbidden unrelated audio/media/source mutation: '..name)end end
M.OBS_MEDIA_STATE_NONE=0;M.OBS_MEDIA_STATE_PLAYING=1;M.OBS_MEDIA_STATE_OPENING=2;M.OBS_MEDIA_STATE_BUFFERING=3;M.OBS_MEDIA_STATE_PAUSED=4;M.OBS_MEDIA_STATE_STOPPED=5;M.OBS_MEDIA_STATE_ENDED=6;M.OBS_MEDIA_STATE_ERROR=7
M.now_ns=1000000000;M.media_actions={}
function M.os_gettime_ns()return M.now_ns end
function M.advance_ms(ms)M.now_ns=M.now_ns+ms*1000000 end
local old_type_probe=M.obs_source_get_display_name
function M.obs_source_get_display_name(id)if id=='ffmpeg_source'and M.unavailable_type~=id then return'Media Source'end;return old_type_probe(id)end
local old_source_create=M.obs_source_create
function M.obs_source_create(id,name,settings,hotkeys)
 local source=old_source_create(id,name,settings,hotkeys)
 if source and id=='ffmpeg_source'then source.width=2560;source.height=1440;source.media_time=0;source.media_state=M.OBS_MEDIA_STATE_STOPPED;source.duration=1200 end
 return source
end
function M.obs_data_apply(destination,source)
 local function clone(value)if type(value)~='table'then return value end;local out={};for k,v in pairs(value)do if k~='_refs'then out[k]=clone(v)end end;return out end
 for k,v in pairs(source)do if k~='_refs'then destination[k]=clone(v)end end
end
local function managed_media(source,name)
 assert(source and source.id=='ffmpeg_source'and source_owned(source)and source.private.nrc_desktop_role=='display_wipe','Media operation outside owned wipe: '..name)
 return source
end
function M.obs_source_media_restart(source)
 managed_media(source,'restart');mutation(source,'media_restart');M.media_actions[#M.media_actions+1]={name='restart',source=source}
 -- Native restart queues MEDIA_ACTION_RESTART; immediate getters retain prior state/PTS.
 source.restart_pending=true
end
function M.process_media_restart(source,state,time)
 managed_media(source,'process_video_tick_restart');assert(source.restart_pending,'No queued restart')
 source.restart_pending=false;source.media_state=state or M.OBS_MEDIA_STATE_PLAYING;source.media_time=time or 0
 M.snapshot_scene('simulated_native_video_tick')
end
function M.obs_source_media_get_time(source)return managed_media(source,'get_time').media_time end
function M.obs_source_media_get_state(source)return managed_media(source,'get_state').media_state end
function M.obs_source_media_get_duration(source)return managed_media(source,'get_duration').duration end
function M.obs_source_media_play_pause(source,pause)
 managed_media(source,'play_pause');mutation(source,'media_play_pause',pause);M.media_actions[#M.media_actions+1]={name='play_pause',source=source,pause=pause};source.media_state=pause and M.OBS_MEDIA_STATE_PAUSED or M.OBS_MEDIA_STATE_PLAYING
end
function M.obs_source_media_stop(source)
 managed_media(source,'stop');mutation(source,'media_stop');M.media_actions[#M.media_actions+1]={name='stop',source=source};source.media_state=M.OBS_MEDIA_STATE_STOPPED;source.media_time=0
end
function M.obs_source_media_set_time(source,time)managed_media(source,'set_time');mutation(source,'media_set_time',time);source.media_time=time end
function M.obs_source_set_muted(source,value)
 local role=source and source.private.nrc_desktop_role
 assert(source_owned(source)and((role=='display_wipe'and source.id=='ffmpeg_source')or((role=='chat_mac'or role=='chat_studio')and source.id=='browser_source')),'Mute outside owned wipe/chat clone')
 mutation(source,'set_muted',value);source.muted=value
end
function M.obs_source_set_volume(source,value)managed_media(source,'set_volume');mutation(source,'set_volume',value);source.volume=value end

-- Post-mutation snapshots expose transient cover/visibility states, not only endpoints.
M.scene_snapshots={}
function M.snapshot_scene(label)
 local scene
 for _,source in pairs(M.sources)do if source.scene and source_owned(source)then scene=source.scene;break end end
 if not scene then return end
 local result={event=label,now_ms=M.now_ns/1000000,roles={},indices={}}
 for index,item in ipairs(scene.items)do
  local role=item.private and item.private.nrc_desktop_role
  if role and item.private.nrc_desktop_owner==M.allowed_owner then
   result.roles[role]={visible=item.visible,pos=item.pos and{x=item.pos.x,y=item.pos.y}or nil,bounds=item.bounds and{x=item.bounds.x,y=item.bounds.y}or nil,source=item.source,media_time=item.source.media_time}
   result.indices[role]=index
  end
 end
 M.scene_snapshots[#M.scene_snapshots+1]=result
 if M.scene_observer then M.scene_observer(result)end
 return result
end
for _,name in ipairs({'obs_sceneitem_set_visible','obs_sceneitem_set_order','obs_sceneitem_set_order_position','obs_sceneitem_set_bounds','obs_sceneitem_set_pos'})do
 local original=M[name]
 M[name]=function(...)local value=original(...);M.snapshot_scene(name);return value end
end
for _,name in ipairs({'obs_source_update','obs_source_media_restart','obs_source_media_stop'})do
 local original=M[name]
 M[name]=function(...)local value=original(...);M.snapshot_scene(name);return value end
end

return M
