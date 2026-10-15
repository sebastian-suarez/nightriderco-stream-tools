/* Local OBS layout controller. Production authentication comes from the local Keychain helper. */
(function (root) {
  'use strict';
  const SCENES = ['Workshop', 'Gameplay'];
  const PRESETS = {
    camera: {
      'top-left': { positionX: 52, positionY: 202 },
      'top-right': { positionX: 1932, positionY: 202 },
      'bottom-left': { positionX: 52, positionY: 992 },
      'bottom-right': { positionX: 1932, positionY: 992 }
    },
    chat: {
      'top-left': { positionX: 60, positionY: 210 },
      'top-right': { positionX: 2024, positionY: 210 },
      'bottom-left': { positionX: 60, positionY: 680 },
      'bottom-right': { positionX: 2024, positionY: 680 }
    }
  };
  const ALLOWED = new Set(['GetPersistentData', 'GetCurrentProgramScene', 'GetSceneItemList', 'GetGroupSceneItemList', 'GetVideoSettings', 'GetHotkeyList', 'GetStreamStatus', 'GetRecordStatus', 'SetSceneItemTransform', 'SetSceneItemEnabled', 'TriggerHotkeyByName']);
  async function makeAuthentication(password, salt, challenge, cryptoApi) {
    const api = cryptoApi || root.crypto;
    if (!api || !api.subtle) throw new Error('Secure hashing is unavailable. Open this local dock in OBS.');
    async function hash(value) {
      const bytes = new Uint8Array(await api.subtle.digest('SHA-256', new TextEncoder().encode(value)));
      return btoa(String.fromCharCode(...bytes));
    }
    return hash(await hash(password + salt) + challenge);
  }
  function unique(items, name) {
    const matches = items.filter(item => item.sourceName === name);
    return matches.length === 1 ? matches[0] : null;
  }
  function targetNames(scene) { return { camera: 'NRC Camera · ' + scene, chat: '[HTML] Chat Minimal' }; }
  function presetFor(kind, transform, factor = 1) {
    return Object.keys(PRESETS[kind]).find(key => {
      const p = PRESETS[kind][key];
      return Math.abs(transform.positionX - p.positionX * factor) < 1 && Math.abs(transform.positionY - p.positionY * factor) < 1;
    }) || null;
  }
  function overlaps(observed) {
    if (!observed || !observed.camera.visible || !observed.chat.visible) return false;
    const a = observed.camera.transform, b = observed.chat.transform;
    return a.positionX < b.positionX + b.width && a.positionX + a.width > b.positionX && a.positionY < b.positionY + b.height && a.positionY + a.height > b.positionY;
  }
  class LayoutClient {
    constructor(options = {}) {
      this.WebSocket = options.WebSocket || root.WebSocket; this.crypto = options.crypto || root.crypto;
      this.onState = options.onState || function () {}; this.timeoutMs = options.timeoutMs || 4000; this.pollMs = options.pollMs || 800;
      this.ws = null; this.identified = false; this.authenticate = null; this.releaseAuthentication = null; this.generation = 0; this.selection = 0; this.serial = 0; this.requests = new Map(); this.polling = null; this.timer = null; this.helloTimer = null;
      this.state = { connection: 'offline', sceneChoice: 'auto', sceneName: null, activeScene: null, busy: false, ready: false, missing: false, error: '', message: 'Connect to OBS to control your layout.', observed: null };
    }
    emit(patch = {}) { Object.assign(this.state, patch); this.onState({ ...this.state }); }
    disconnect() {
      ++this.generation; ++this.selection; clearTimeout(this.timer); clearTimeout(this.helloTimer);
      this.timer = this.helloTimer = null; this.polling = null;
      for (const request of this.requests.values()) { clearTimeout(request.timer); request.reject(new Error('Disconnected from OBS.')); }
      this.requests.clear();
      const ws = this.ws; this.ws = null; this.identified = false;
      if (this.releaseAuthentication) this.releaseAuthentication();
      this.authenticate = this.releaseAuthentication = null;
      if (ws) ws.close();
      this.emit({ connection: 'offline', busy: false, ready: false, missing: false, observed: null, error: '', message: 'Connect to OBS to control your layout.' });
    }
    connect({ port = 4455, authenticate, password = '' } = {}) {
      if (!/^\d{1,5}$/.test(String(port)) || Number(port) < 1 || Number(port) > 65535) throw new Error('Enter a port from 1 to 65535.');
      this.disconnect(); const generation = this.generation;
      if (authenticate !== undefined && typeof authenticate !== 'function') throw new Error('Invalid authentication provider.');
      // Legacy programmatic callers may supply a one-use password; the dock UI never does.
      let oneShotPassword = authenticate ? '' : String(password);
      password = '';
      this.releaseAuthentication = () => { oneShotPassword = ''; };
      this.authenticate = authenticate || (async (salt, challenge) => {
        let value = oneShotPassword; oneShotPassword = '';
        try { return await makeAuthentication(value, salt, challenge, this.crypto); } finally { value = ''; }
      });
      this.emit({ connection: 'connecting', error: '', message: 'Connecting to local OBS…' });
      try { this.ws = new this.WebSocket('ws://127.0.0.1:' + Number(port), 'obswebsocket.json'); }
      catch (_) { this.fail('Cannot open the local OBS connection.', generation); return; }
      this.helloTimer = setTimeout(() => this.fail('OBS did not finish connecting. Check the port and password.', generation), 45000);
      this.ws.onmessage = event => { if (generation === this.generation) this.receive(event.data, generation).catch(error => this.fail(error.message, generation)); };
      this.ws.onerror = () => this.fail('Cannot reach OBS. Enable its WebSocket server in Tools.', generation);
      this.ws.onclose = event => this.fail(event.code === 4009 ? 'OBS password was refused. Re-enter its WebSocket password.' : 'Connection closed. Reconnect to OBS; no commands were queued.', generation);
    }
    fail(message, generation) { if (generation !== this.generation) return; this.disconnect(); this.emit({ error: message }); }
    async receive(raw, generation) {
      const message = JSON.parse(raw), d = message.d;
      if (!d) throw new Error('Invalid response from OBS.');
      if (message.op === 0) {
        if (this.identifySent === generation || this.identified || d.rpcVersion < 1) throw new Error('Unexpected OBS handshake.');
        this.identifySent = generation;
        const identify = { rpcVersion: 1, eventSubscriptions: 0 };
        if (d.authentication) {
          if (typeof d.authentication.salt !== 'string' || typeof d.authentication.challenge !== 'string') throw new Error('Invalid OBS authentication challenge.');
          const authenticate = this.authenticate, release = this.releaseAuthentication;
          this.authenticate = this.releaseAuthentication = null;
          if (!authenticate) throw new Error('Authentication provider is unavailable. Reconnect.');
          try { identify.authentication = await authenticate(d.authentication.salt, d.authentication.challenge); }
          finally { if (release) release(); }
          if (typeof identify.authentication !== 'string' || !identify.authentication) throw new Error('Invalid OBS authentication response.');
        }
        if (generation !== this.generation) return;
        if (this.releaseAuthentication) this.releaseAuthentication();
        this.authenticate = this.releaseAuthentication = null;
        if (generation === this.generation && this.ws) this.ws.send(JSON.stringify({ op: 1, d: identify }));
      } else if (message.op === 2) {
        if (this.identifySent !== generation || this.identified || d.negotiatedRpcVersion !== 1) throw new Error('Unexpected identification response.');
        clearTimeout(this.helloTimer); this.identified = true; this.emit({ connection: 'online', message: 'Reading scene layout…' });
        await this.refresh(); this.schedule(generation);
      } else if (message.op === 7) {
        const request = this.requests.get(d.requestId); if (!request) return;
        clearTimeout(request.timer); this.requests.delete(d.requestId);
        if (d.requestType !== request.type || !d.requestStatus || !d.requestStatus.result) request.reject(new Error('OBS could not complete ' + request.type + '. ' + (d.requestStatus?.comment || 'Refresh the connection.')));
        else request.resolve(d.responseData || {});
      }
    }
    request(type, data = {}) {
      if (!ALLOWED.has(type)) return Promise.reject(new Error('Unsupported layout request.'));
      if (!this.identified || !this.ws || this.ws.readyState !== 1) return Promise.reject(new Error('Connect to OBS first.'));
      if (type === 'TriggerHotkeyByName' && data.hotkeyName !== 'nrc_layout.setup') return Promise.reject(new Error('Unsupported setup command.'));
      if (type.startsWith('SetSceneItem') && !SCENES.includes(data.sceneName)) return Promise.reject(new Error('Choose Workshop or Gameplay.'));
      const id = 'nrc-layout-' + (++this.serial);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { this.requests.delete(id); reject(new Error('OBS request timed out. Refresh before trying again.')); }, this.timeoutMs);
        this.requests.set(id, { resolve, reject, timer, type });
        try { this.ws.send(JSON.stringify({ op: 6, d: { requestType: type, requestId: id, requestData: data } })); }
        catch (_) { clearTimeout(timer); this.requests.delete(id); reject(new Error('OBS connection closed.')); }
      });
    }
    schedule(generation) {
      clearTimeout(this.timer);
      if (generation !== this.generation || !this.identified) return;
      this.timer = setTimeout(async () => { if (!this.state.busy) await this.refresh({ clearError: false }); this.schedule(generation); }, this.pollMs);
    }
    async selectScene(choice) {
      if (!['auto', ...SCENES].includes(choice) || this.state.busy) return;
      ++this.selection; this.emit({ sceneChoice: choice, ready: false, observed: null, error: '' });
      return this.refresh();
    }
    async inspect(sceneName) {
      const result = await this.request('GetSceneItemList', { sceneName });
      if (!Array.isArray(result.sceneItems)) throw new Error('OBS did not return scene items.');
      const names = targetNames(sceneName);
      const group = unique(result.sceneItems, names.camera);
      const direct = unique(result.sceneItems, 'Camera Switch');
      const camera = group || direct, chat = unique(result.sceneItems, names.chat);
      if (!camera || !chat) return { missing: true, observed: null };
      if (group && direct) throw new Error('Camera Switch is present both inside and outside its layout group. Keep one instance.');
      if (group) {
        if (!group.isGroup) throw new Error('The layout wrapper must be an OBS group. Run setup to repair it.');
        const children = await this.request('GetGroupSceneItemList', { sceneName: names.camera });
        const component = unique(children.sceneItems || [], 'Camera Switch');
        if (!component || component.isGroup || component.sourceType !== 'OBS_SOURCE_TYPE_SCENE') throw new Error('The camera group must contain the Camera Switch scene. Run setup to repair it.');
        if (!component.sceneItemEnabled) throw new Error('Enable Camera Switch inside its group, then use this dock to hide the group.');
        if (children.sceneItems.some(i => i.sourceName === 'Webcam' || i.sourceName.startsWith('NRC Camera Frame'))) throw new Error('Remove the old Webcam and frame from this group; Camera Switch already contains them.');
      } else if (direct.isGroup || direct.sourceType !== 'OBS_SOURCE_TYPE_SCENE') {
        throw new Error('Camera Switch must be a nested scene.');
      }
      // Internal camera/buddy visibility belongs to the Camera Switch dock.
      // Layout only reads and mutates this local instance (or its wrapper).
      const observed = {};
      for (const [kind, item] of Object.entries({ camera, chat })) {
        const t = item.sceneItemTransform;
        if (!Number.isFinite(t?.positionX) || !Number.isFinite(t?.positionY)) throw new Error('OBS returned an invalid layout transform.');
        observed[kind] = { id: item.sceneItemId, visible: item.sceneItemEnabled, transform: t, preset: presetFor(kind, t, this.factor || 1) };
      }
      return { missing: false, observed };
    }
    refresh({ clearError = true } = {}) {
      if (!this.identified) return Promise.resolve();
      if (clearError) this.emit({ error: '' });
      const generation = this.generation, selection = this.selection;
      // Chain a fresh read after an older scene-selection read, never reuse its result.
      const previous = this.polling || Promise.resolve();
      const operation = previous.catch(() => {}).then(async () => {
        if (generation !== this.generation || selection !== this.selection) return;
        try {
          const [current, video] = await Promise.all([this.request('GetCurrentProgramScene'), this.request('GetVideoSettings')]);
          if (!((video.baseWidth === 2560 && video.baseHeight === 1440) || (video.baseWidth === 1920 && video.baseHeight === 1080))) throw new Error('Choose an FHD or 2K canvas.');
          this.factor = video.baseWidth / 2560;
          this.emit({ canvasWidth: video.baseWidth, canvasHeight: video.baseHeight });
          const sceneName = this.state.sceneChoice === 'auto' ? current.currentProgramSceneName : this.state.sceneChoice;
          if (!SCENES.includes(sceneName)) {
            if (generation === this.generation && selection === this.selection) this.emit({ activeScene: current.currentProgramSceneName, sceneName: null, ready: false, missing: false, observed: null, message: 'Select Workshop or Gameplay, or switch to one in OBS.' });
            return;
          }
          const layout = await this.inspect(sceneName);
          if (generation !== this.generation || selection !== this.selection) return;
          const warning = overlaps(layout.observed);
          this.emit({ activeScene: current.currentProgramSceneName, sceneName, ...layout, ready: !layout.missing, message: layout.missing ? 'Load the layout setup script, then Prepare scenes.' : warning ? 'Camera and chat overlap. Pick a different corner to separate them.' : 'Layout confirmed by OBS. Positions and visibility are saved in this scene.' });
        } catch (error) {
          if (generation === this.generation && selection === this.selection) this.emit({ ready: false, observed: null, error: error.message });
        }
      });
      this.polling = operation;
      operation.finally(() => { if (this.polling === operation) this.polling = null; });
      return operation;
    }
    async change(kind, mutation) {
      if (!['camera', 'chat'].includes(kind)) throw new Error('Choose camera or chat.');
      if (!this.identified || !this.state.ready || this.state.busy || !SCENES.includes(this.state.sceneName)) throw new Error('Wait until the scene layout is ready.');
      const generation = this.generation, selection = this.selection, sceneName = this.state.sceneName, auto = this.state.sceneChoice === 'auto';
      this.emit({ busy: true, error: '' });
      try {
        // Re-resolve IDs before every mutation, and never retarget a click after a scene switch.
        if (this.polling) await this.polling;
        const current = await this.request('GetCurrentProgramScene');
        if (auto && current.currentProgramSceneName !== sceneName) throw new Error('Active scene changed. Review its layout and try again.');
        const [lock, video] = await Promise.all([
          this.request('GetPersistentData', {realm:'OBS_WEBSOCKET_DATA_REALM_GLOBAL',slotName:'nrc_resolution_lock_until'}),
          this.request('GetVideoSettings')]);
        if (Number(lock.slotValue) * 1000 > Date.now()) throw new Error('Resolution switch in progress. Please wait.');
        if (!((video.baseWidth === 1920 && video.baseHeight === 1080) || (video.baseWidth === 2560 && video.baseHeight === 1440))) throw new Error('Choose an FHD or 2K canvas.');
        this.factor = video.baseWidth / 2560;
        const layout = await this.inspect(sceneName);
        if (generation !== this.generation || selection !== this.selection) return;
        if (layout.missing) throw new Error('A managed source was removed. Prepare the scenes again.');
        await mutation({ sceneName, sceneItemId: layout.observed[kind].id }, layout.observed[kind]);
        if (generation === this.generation) await this.refresh();
      } catch (error) { if (generation === this.generation) this.emit({ error: error.message }); }
      finally { if (generation === this.generation) this.emit({ busy: false }); }
    }
    move(kind, preset) {
      if (!PRESETS[kind]?.[preset]) return Promise.reject(new Error('Choose a predefined position.'));
      return this.change(kind, (target, observed) => {
        const p = PRESETS[kind][preset], f = this.factor || 1;
        // Preserve actual group/widget size; normalize only its canvas position.
        return this.request('SetSceneItemTransform', { ...target, sceneItemTransform: {
          positionX:p.positionX*f, positionY:p.positionY*f,
          alignment:5, rotation:0
        }});
      });
    }
    setVisible(kind, visible) {
      if (typeof visible !== 'boolean') return Promise.reject(new Error('Choose Show or Hide.'));
      return this.change(kind, target => this.request('SetSceneItemEnabled', { ...target, sceneItemEnabled: visible }));
    }
    async prepare() {
      if (!this.identified || this.state.busy) throw new Error('Connect to OBS first.');
      const generation = this.generation; this.emit({ busy: true, error: '' });
      try {
        const [keys, stream, record] = await Promise.all([this.request('GetHotkeyList'), this.request('GetStreamStatus'), this.request('GetRecordStatus')]);
        if (stream.outputActive || record.outputActive) throw new Error('Stop streaming and recording before first-time scene setup.');
        if (!keys.hotkeys?.includes('nrc_layout.setup')) throw new Error('Add nightriderco-layout-setup.lua in OBS → Tools → Scripts first.');
        await this.request('TriggerHotkeyByName', { hotkeyName: 'nrc_layout.setup' });
        if (generation === this.generation) await this.refresh();
      } catch (error) { if (generation === this.generation) this.emit({ error: error.message }); }
      finally { if (generation === this.generation) this.emit({ busy: false }); }
    }
  }
  const api = { LayoutClient, PRESETS, makeAuthentication, presetFor, overlaps };
  root.NRCLayout = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
