local real_dofile = dofile
local test_folder = assert(debug.getinfo(1, 'S').source:match('^@(.*/)'), 'Run this test from its saved file')
local root = test_folder .. '../../../'
local automation = root .. 'payload/NIGHTRIDERCO/07_AUTOMATION/'
local provider = real_dofile(automation .. 'nrc-displays.lua')
local inventory, fail_inventory
provider.list = function() if fail_inventory then error('inventory unavailable') end; return inventory end
dofile = function(path) if path:match('nrc%-displays.lua$') then return provider end; return real_dofile(path) end
local mac = {id=1,uuid='mac-new',name='Built-in Retina Display',builtin=true}
local studio = {id=2,uuid='studio-new',name='Studio Display',builtin=false}
local tests, passed = 0,0
local function test(name,callback)
 tests=tests+1;local ok,problem=xpcall(callback,debug.traceback)
 if ok then passed=passed+1;print('PASS '..name) else print('FAIL '..name..'\n'..problem) end
end
local function setup(options)
 options=options or {};inventory=options.displays or {mac,studio};fail_inventory=false
 local m=real_dofile(test_folder .. 'mock_obs.lua')
 obslua=m
 function script_path() return automation end
 local s=m.obs_data_create();s.instance_id='test-owner';s.desktop_source='Mac';s.studio_source='Studio';s.webcam_source='';s.managed_scene='Desktop Auto';s.asset_folder=root..'payload/NIGHTRIDERCO/03_OBS/display-layouts';s.animated=true;s.enabled=false;s.use_stinger=options.wipe or false;s.use_studio=options.studio or false;s.chat_enabled=false
 m.allowed_owner=s.instance_id
 local a=m.new_source('Mac','screen_capture',3024,1964);a.settings.display_uuid='old-mac';a.settings.hide_obs=true
 local b=m.new_source('Studio','screen_capture',5120,2880);b.settings.display_uuid='old-studio'
 m.capture_updates=0;m.property_refreshes=0
 local update=m.obs_source_update
 m.obs_source_update=function(source,data)
  if source==a or source==b then
   assert(data.display_uuid=='mac-new' or data.display_uuid=='studio-new' or data.display_uuid=='studio-reconnected')
   m.capture_updates=m.capture_updates+1
  else update(source,data) end
 end
 m.obs_source_properties=function(source) assert(source==a or source==b);m.property_refreshes=m.property_refreshes+1;return {} end
 m.obs_properties_destroy=function() end
 real_dofile(automation..'nightriderco-desktop-auto.lua')
 script_defaults(s);script_update(s);script_load(s);create_or_update_button()
 local scene=assert(m.sources['Desktop Auto']).scene
 local roles={};for _,item in ipairs(scene.items) do roles[item.private.nrc_desktop_role]=item end
 local function tick(n)for _=1,(n or 1) do m.advance_ms(500);poll_capture() end end
 local function metadata()return roles.background.source.settings.nrc_desktop_dock end
 local function close()script_unload();m.obs_data_release(s);m.assert_no_leaks();assert(next(m.hotkeys)==nil);assert(next(m.timers)==nil)end
 return m,s,a,b,roles,tick,metadata,close
end

test('matches identities, ignores order and unrelated external monitors',function()
 local other={id=3,uuid='other',name='Unknown monitor',builtin=false}
 assert(provider.match({studio,mac},'mac','old')==mac)
 assert(provider.match({other,mac,studio},'studio','old')==studio)
 assert(provider.match({other,mac},'studio','old')==nil)
 assert(provider.match({studio,{id=4,uuid='studio2',name='Studio Display',builtin=false}},'studio','old')==nil)
end)
test('startup assigns both displays and preserves existing capture options',function()
 local m,s,a,b,r,t,meta,close=setup();t(4)
 assert(a.settings.display_uuid==mac.uuid and b.settings.display_uuid==studio.uuid)
 assert(a.settings.hide_obs==true);assert(m.capture_updates==2 and m.property_refreshes==2)
 assert(not r.hold.visible);assert(meta():find('"mac_available":true'));assert(meta():find('"studio_available":true'))
 assert(meta():find('"detection_error":""'));t(10);assert(m.capture_updates==2);close()
end)
test('missing Studio at startup falls back to Mac and rejects Studio hotkey',function()
 local m,s,a,b,r,t,meta,close=setup({studio=true,displays={mac}});t(5)
 assert(not s.use_studio and r.desktop.visible and not r.desktop_studio.visible and not r.hold.visible)
 assert(meta():find('"studio_available":false'));show_studio_hotkey(true);assert(not s.use_studio);assert(not r.hold.visible)
 local props=script_properties();assert(not props.switch_display.enabled);close()
end)
test('unplug active Studio immediately recovers to Mac and ignores stale frame size',function()
 local m,s,a,b,r,t,meta,close=setup({studio=true});t(5);assert(r.desktop_studio.visible and not r.hold.visible)
 inventory={mac};t(6);assert(b.width==5120);assert(not s.use_studio and not r.hold.visible and r.desktop.visible)
 assert(meta():find('"studio_available":false'));close()
end)
test('same UUID reconnect refreshes capture once and re-enables switching',function()
 local m,s,a,b,r,t,meta,close=setup();t(5);inventory={mac};t(4);local before=m.capture_updates
 inventory={studio,mac};t(4);assert(m.capture_updates==before+1);assert(meta():find('"studio_available":true'))
 show_studio_hotkey(true);t(3);assert(s.use_studio and not r.hold.visible);close()
end)
test('changed UUID reconnect rebinds only the correct source',function()
 local m,s,a,b,r,t,meta,close=setup();t(5);inventory={mac};t(4)
 inventory={mac,{id=5,uuid='studio-reconnected',name='Studio Display',builtin=false}};t(4)
 assert(b.settings.display_uuid=='studio-reconnected' and a.settings.display_uuid=='mac-new');close()
end)
test('no connected display remains covered with both switches unavailable, then recovers',function()
 local m,s,a,b,r,t,meta,close=setup({displays={}});t(5)
 assert(r.hold.visible);assert(meta():find('"mac_available":false') and meta():find('"studio_available":false'))
 show_macbook_hotkey(true);show_studio_hotkey(true);assert(r.hold.visible)
 inventory={mac};t(6);assert(not r.hold.visible);close()
end)
test('manual detect refresh retries immediately without rebuilding scene',function()
 local m,s,a,b,r,t,meta,close=setup({displays={mac}});t(5);inventory={mac,studio}
 local original=r.desktop;detect_displays_hotkey(true);assert(b.settings.display_uuid=='studio-new');assert(meta():find('"studio_available":true'))
 t(3);assert(r.desktop==original and not r.hold.visible);close()
end)
test('inventory failure disables switches and automatically recovers',function()
 local m,s,a,b,r,t,meta,close=setup();t(5);fail_inventory=true;t(4)
 assert(r.hold.visible);assert(meta():find('Display detection failed'));fail_inventory=false;t(6);assert(not r.hold.visible);close()
end)
test('replaced source identity is never rebound',function()
 local m,s,a,b,r,t,meta,close=setup();t(5);b.uuid='foreign-replacement';b.settings.display_uuid='unrelated';t(4)
 assert(b.settings.display_uuid=='unrelated');assert(meta():find('"studio_available":false'));close()
end)
test('disconnect during native wipe cancels loading and restores available display',function()
 local m,s,a,b,r,t,meta,close=setup({wipe=true});t(5);m.sources['Desktop Auto'].showing=true;show_studio_hotkey(true);assert(r.display_wipe.visible)
 inventory={mac};t(6);assert(not r.display_wipe.visible and not r.hold.visible and r.desktop.visible);close()
end)
print(string.format('RESULT %d/%d passed',passed,tests));assert(passed==tests)
