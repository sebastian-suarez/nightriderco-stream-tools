export const MODES = { fhd: [1920,1080], qhd: [2560,1440] };
export const LOCK_SLOT = { realm: 'OBS_WEBSOCKET_DATA_REALM_GLOBAL', slotName: 'nrc_resolution_lock_until' };
const FIELDS = ['positionX','positionY','rotation','scaleX','scaleY','alignment','boundsType','boundsAlignment','boundsWidth','boundsHeight','cropLeft','cropRight','cropTop','cropBottom','cropToBounds'];
export const transformOnly = t => Object.fromEntries(FIELDS.filter(k => k in t).map(k => [k,t[k]]));
const videoOnly = v => Object.fromEntries(['baseWidth','baseHeight','outputWidth','outputHeight'].map(k => [k,v[k]]));
export function writableTransform(t) {
  const result = {...t};
  // OBS returns zero-size unused bounds, but its setter rejects values below one.
  if (result.boundsType === 'OBS_BOUNDS_NONE') {
    delete result.boundsWidth; delete result.boundsHeight;
  }
  return result;
}
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
export function resizeTransform(before, after, factor) {
  const t = transformOnly(before);
  const rx = before.sourceWidth > 0 && after.sourceWidth > 0 ? after.sourceWidth / before.sourceWidth : 1;
  const ry = before.sourceHeight > 0 && after.sourceHeight > 0 ? after.sourceHeight / before.sourceHeight : 1;
  t.positionX *= factor; t.positionY *= factor;
  t.boundsWidth *= factor; t.boundsHeight *= factor;
  t.scaleX = before.scaleX * factor / rx; t.scaleY = before.scaleY * factor / ry;
  for (const k of ['cropLeft','cropRight']) t[k] = Math.round(before[k] * rx);
  for (const k of ['cropTop','cropBottom']) t[k] = Math.round(before[k] * ry);
  return t;
}
export function fullFrame(input) {
  const { width, height } = input.size;
  return (input.kind === 'browser_source' || input.kind.startsWith('color_source')) &&
    ((width === 1920 && height === 1080) || (width === 2560 && height === 1440));
}
export class ResolutionEngine {
  constructor(obs, store) { this.obs = obs; this.store = store; this.busy = false; this.message = ''; }
  call(type,data) { return this.obs.call(type,data); }
  async context() {
    const [collections, profiles] = await Promise.all([this.call('GetSceneCollectionList'),this.call('GetProfileList')]);
    return { collection: collections.currentSceneCollectionName, profile: profiles.currentProfileName };
  }
  async outputs() {
    const names = ['Stream','Record','ReplayBuffer','VirtualCam'];
    const states = await Promise.all(names.map(async n => {
      try { return await this.call(`Get${n}Status`); }
      catch (error) {
        if (['ReplayBuffer','VirtualCam'].includes(n) && error.obsCode === 604) return {outputActive:false};
        throw error;
      }
    }));
    const extra = await this.call('GetOutputList');
    return [...new Set([...names.filter((_,i) => states[i].outputActive), ...extra.outputs.filter(o => o.outputActive).map(o => o.outputName)])];
  }
  async assertIdle() {
    const active = await this.outputs();
    if (active.length) throw new Error(`Stop ${active.join(', ')} before switching resolution.`);
  }
  async assertContext(snapshot) {
    const now = await this.context();
    if (now.collection !== snapshot.context.collection || now.profile !== snapshot.context.profile)
      throw new Error('OBS profile or scene collection changed. Return to the saved profile and collection first.');
  }
  async inspect() {
    const [video, active, context, saved] = await Promise.all([this.call('GetVideoSettings'),this.outputs(),this.context(),this.store.read()]);
    const mode = Object.keys(MODES).find(k => MODES[k][0] === video.baseWidth && MODES[k][1] === video.baseHeight) || 'custom';
    return { connected: true, video, active, context, mode, busy: this.busy, message: this.message,
      canUndo: !!saved?.snapshot && saved.snapshot.context.collection === context.collection && saved.snapshot.context.profile === context.profile,
      recovery: saved?.phase === 'pending' || saved?.phase === 'recovery', lastSwitch: saved?.at };
  }
  async capture() {
    const context = await this.context();
    const [video, inputList, sceneList, groupList] = await Promise.all([
      this.call('GetVideoSettings'),this.call('GetInputList'),this.call('GetSceneList'),this.call('GetGroupList')]);
    const inputs = [];
    for (const i of inputList.inputs) {
      const kind = i.unversionedInputKind || i.inputKind;
      if (kind !== 'browser_source' && !kind.startsWith('color_source')) continue;
      const { inputSettings: s } = await this.call('GetInputSettings', { inputName: i.inputName });
      if (Number.isFinite(s.width) && Number.isFinite(s.height)) inputs.push({name:i.inputName,uuid:i.inputUuid,kind,size:{width:s.width,height:s.height}});
    }
    const containers = [];
    for (const name of groupList.groups) {
      const { sceneItems } = await this.call('GetGroupSceneItemList', { sceneName: name });
      containers.push({ name, group:true, items:sceneItems });
    }
    for (const s of sceneList.scenes) {
      const { sceneItems } = await this.call('GetSceneItemList', { sceneName:s.sceneName });
      containers.push({ name:s.sceneName, uuid:s.sceneUuid, group:false, items:sceneItems });
    }
    const parameters = [];
    for (const parameterName of ['RescaleRes','RecRescaleRes','FFRescaleRes']) {
      const p = await this.call('GetProfileParameter', { parameterCategory:'AdvOut',parameterName });
      if (p.parameterValue != null) parameters.push({parameterCategory:'AdvOut',parameterName,parameterValue:p.parameterValue});
    }
    const snapshot = { context, video:videoOnly(video), inputs, containers, parameters };
    await this.assertContext(snapshot);
    return snapshot;
  }
  async validateTargets(snapshot) {
    await this.assertContext(snapshot);
    const { inputs } = await this.call('GetInputList');
    for (const i of snapshot.inputs.filter(fullFrame)) {
      if (!inputs.some(n => n.inputName === i.name && (!i.uuid || n.inputUuid === i.uuid))) throw new Error(`Source changed: ${i.name}.`);
    }
    for (const c of snapshot.containers) {
      const { sceneItems } = await this.call(c.group ? 'GetGroupSceneItemList':'GetSceneItemList',{sceneName:c.name});
      for (const i of c.items) {
        if (!sceneItems.some(n => n.sceneItemId === i.sceneItemId && n.sourceName === i.sourceName && (!i.sourceUuid || n.sourceUuid === i.sourceUuid)))
          throw new Error(`Scene items changed in ${c.name}. Restore the saved collection before recovery.`);
      }
    }
  }
  async lock(snapshot, value) {
    await this.call('SetPersistentData', { ...LOCK_SLOT, slotValue:value });
    for (const i of snapshot.inputs.filter(i => i.name.endsWith(' | NRC Auto Background'))) {
      await this.call('SetInputSettings',{ inputName:i.name,inputSettings:{nrc_resolution_lock_until:value},overlay:true });
    }
  }
  async ensureIntegration(snapshot) {
    if (snapshot.containers.some(c => c.items.some(i => i.sourceName.endsWith(" | NRC Auto Display Wipe") && i.sceneItemEnabled))) throw new Error("Wait for the display transition to finish before switching resolution.");
    for (const i of snapshot.inputs.filter(i => i.name.endsWith(' | NRC Auto Background'))) {
      const { inputSettings } = await this.call('GetInputSettings',{inputName:i.name});
      let m; try { m = JSON.parse(inputSettings.nrc_desktop_dock); } catch { continue; }
      if (m.enabled && !m.resolution_aware) throw new Error('Reload nightriderco-desktop-auto.lua in Tools → Scripts, or restart OBS, to activate FHD support for Desktop Switch.');
    }
  }
  orderedContainers(snapshot) {
    const groups = new Map(snapshot.containers.filter(c => c.group).map(c => [c.name,c]));
    const out = [], visited = new Set(), visiting = new Set();
    const visit = c => {
      if (visited.has(c.name)) return;
      if (visiting.has(c.name)) throw new Error('Recursive group found. Fix the group nesting first.');
      visiting.add(c.name);
      for (const i of c.items) if (i.isGroup && groups.has(i.sourceName)) visit(groups.get(i.sourceName));
      visiting.delete(c.name); visited.add(c.name); out.push(c);
    };
    for (const c of groups.values()) visit(c);
    return [...out, ...snapshot.containers.filter(c => !c.group)];
  }
  async apply(snapshot, width, height, restore = false) {
    await this.assertContext(snapshot); await this.assertIdle();
    const factor = width / snapshot.video.baseWidth;
    await this.call('SetVideoSettings', restore ? snapshot.video : {baseWidth:width,baseHeight:height,outputWidth:width,outputHeight:height});
    for (const p of snapshot.parameters) await this.call('SetProfileParameter', restore ? p : {...p,parameterValue:`${width}x${height}`});
    for (const i of snapshot.inputs.filter(fullFrame)) {
      await this.call('SetInputSettings',{inputName:i.name,inputSettings:restore ? i.size : {width,height},overlay:true});
    }
    // Browser source dimensions update on OBS's video thread.
    await delay(350);
    for (const c of this.orderedContainers(snapshot)) {
      await this.assertContext(snapshot); await this.assertIdle();
      for (const i of c.items) {
        const target = {sceneName:c.name,sceneItemId:i.sceneItemId};
        const { sceneItemTransform:current } = await this.call('GetSceneItemTransform',target);
        // Groups keep their internal coordinate space. The enclosing item scales once.
        const transform = restore ? transformOnly(i.sceneItemTransform) : resizeTransform(i.sceneItemTransform,current,c.group ? 1 : factor);
        await this.call('SetSceneItemTransform',{...target,sceneItemTransform:writableTransform(transform)});
      }
    }
  }
  async verify(snapshot, width, height, restore = false) {
    await this.assertContext(snapshot);
    const expected = restore ? snapshot.video : {baseWidth:width,baseHeight:height,outputWidth:width,outputHeight:height};
    const video = await this.call('GetVideoSettings');
    for (const k of Object.keys(expected)) if (video[k] !== expected[k]) throw new Error('OBS did not retain the requested canvas and output size.');
    for (const i of snapshot.inputs.filter(fullFrame)) {
      const { inputSettings:s } = await this.call('GetInputSettings',{inputName:i.name});
      const size = restore ? i.size : {width,height};
      if (s.width !== size.width || s.height !== size.height) throw new Error(`Browser or background size did not apply: ${i.name}.`);
    }
    for (const c of snapshot.containers) {
      const {sceneItems} = await this.call(c.group ? 'GetGroupSceneItemList':'GetSceneItemList',{sceneName:c.name});
      for (const i of c.items) {
        const current = sceneItems.find(x => x.sceneItemId === i.sceneItemId)?.sceneItemTransform;
        if (!current) throw new Error(`Missing item during verification: ${i.sourceName}.`);
        const expectedTransform = restore ? transformOnly(i.sceneItemTransform) : resizeTransform(i.sceneItemTransform,current,c.group ? 1 : width / snapshot.video.baseWidth);
        for (const k of ['positionX','positionY','cropLeft','cropRight','cropTop','cropBottom', ...(current.boundsType === 'OBS_BOUNDS_NONE' ? [] : ['boundsWidth','boundsHeight'])]) {
          if (Math.abs(current[k]-expectedTransform[k]) > 1) throw new Error(`Layout changed during switch: ${c.name} / ${i.sourceName}.`);
        }
        if (current.boundsType !== expectedTransform.boundsType) throw new Error(`Bounds changed: ${i.sourceName}.`);
        if (current.boundsType === 'OBS_BOUNDS_NONE') for (const k of ['scaleX','scaleY']) {
          if (Math.abs(current[k]-expectedTransform[k]) > .002) throw new Error(`Scale did not apply: ${c.name} / ${i.sourceName}.`);
        }
      }
    }
    for (const p of snapshot.parameters) {
      const now = await this.call('GetProfileParameter',{parameterCategory:p.parameterCategory,parameterName:p.parameterName});
      if (now.parameterValue !== (restore ? p.parameterValue : `${width}x${height}`)) throw new Error('Output rescale setting did not apply.');
    }
  }
  async switch(mode) {
    if (!MODES[mode]) throw new Error('Choose FHD or 2K.');
    if (this.busy) throw new Error('A resolution change is already running.');
    this.busy = true; this.message = ""; let snapshot, mutated = false;
    try {
      await this.assertIdle();
      const previous = await this.store.read();
      if (previous && ['pending','recovery'].includes(previous.phase)) throw new Error('Restore the saved state before starting another switch.');
      snapshot = await this.capture();
      if (!Object.values(MODES).some(([w,h]) => w === snapshot.video.baseWidth && h === snapshot.video.baseHeight)) throw new Error('This dock supports FHD and 2K 16:9 canvases only.');
      await this.ensureIntegration(snapshot); await this.validateTargets(snapshot);
      const [w,h] = MODES[mode];
      const record = {at:new Date().toISOString(),phase:'pending',mode,snapshot};
      await this.store.write(record); // Durable recovery point before any OBS changes.
      mutated = true;
      await this.lock(snapshot,Math.floor(Date.now()/1000)+120);
      await this.apply(snapshot,w,h);
      await this.verify(snapshot,w,h);
      await this.store.write({...record,phase:'complete'});
      this.message = `${mode === 'fhd' ? 'FHD' : '2K'} applied to canvas, output, full-frame browsers and every scene.`;
    } catch (error) {
      if (snapshot && mutated) {
        try {
          await this.validateTargets(snapshot); await this.apply(snapshot,0,0,true); await this.verify(snapshot,0,0,true);
          await this.store.write({at:new Date().toISOString(),phase:'rolled-back',snapshot});
          this.message = 'The change failed. Previous resolution and layouts were restored.';
        } catch (rollbackError) {
          await this.store.write({at:new Date().toISOString(),phase:'recovery',snapshot});
          this.message = `Recovery needed: ${rollbackError.message}`;
        }
      }
      throw new Error(`${error.message}${this.message ? ' '+this.message : ''}`);
    } finally {
      if (snapshot && mutated) await this.lock(snapshot,0).catch(() => {});
      this.busy = false;
    }
    return this.inspect();
  }
  async undo() {
    if (this.busy) throw new Error('A resolution change is already running.');
    this.busy = true;
    let snapshot, locked = false;
    try {
      await this.assertIdle();
      const saved = await this.store.read(); snapshot = saved?.snapshot;
      if (!snapshot) throw new Error('No previous resolution saved.');
      await this.validateTargets(snapshot);
      await this.store.write({...saved,phase:'pending'});
      locked = true;
      await this.lock(snapshot,Math.floor(Date.now()/1000)+120);
      await this.apply(snapshot,0,0,true); await this.verify(snapshot,0,0,true);
      await this.store.clear(); this.message = 'Previous resolution and source framing restored.';
    } finally {
      if (snapshot && locked) await this.lock(snapshot,0).catch(() => {});
      this.busy = false;
    }
    return this.inspect();
  }
}
