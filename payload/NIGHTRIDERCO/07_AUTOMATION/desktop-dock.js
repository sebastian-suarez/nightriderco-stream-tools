/* NIGHTRIDERCO OBS dock. Production authentication comes from the local Keychain helper. */
(function (root) {
  'use strict';
  const SUFFIX = ' | NRC Auto Background';
  const SHIELD = ' | NRC Auto Opaque Shield';
  const WIPE = ' | NRC Auto Display Wipe';
  const KEYS = ['schema', 'instance_id', 'scene_name', 'primary_source', 'studio_source', 'mac_hotkey', 'studio_hotkey', 'enabled', 'configured'];
  function validateMetadata(raw) {
    if (typeof raw !== 'string' || raw.length > 10000) throw new Error('Invalid dock metadata. Reload the updated Lua script.');
    let value;
    try { value = JSON.parse(raw); } catch (_) { throw new Error('Invalid dock metadata JSON. Reload the Lua script.'); }
    if (!value || typeof value !== 'object' || Array.isArray(value) || value.schema !== 1) throw new Error('Unsupported dock metadata. Update the dock and Lua script together.');
    for (const key of ['instance_id', 'scene_name', 'primary_source', 'studio_source', 'mac_hotkey', 'studio_hotkey']) {
      if (typeof value[key] !== 'string' || value[key].length > 512 || !value[key].trim()) throw new Error('Configure both display captures in Tools → Scripts, then Create / Update off program.');
    }
    if (typeof value.enabled !== 'boolean' || typeof value.configured !== 'boolean') throw new Error('Invalid automation status in dock metadata.');
    if (!/^[A-Za-z0-9._-]{1,160}$/.test(value.instance_id)) throw new Error('Invalid Desktop Auto identity. Reload the Lua script.');
    if (value.studio_source && value.primary_source === value.studio_source) throw new Error('Choose two different captures in the Lua script.');
    const prefix = 'nrc_desktop_auto.' + value.instance_id;
    if (value.mac_hotkey !== prefix + '.macbook' || value.studio_hotkey !== prefix + '.studio') throw new Error('Unrecognized display command names. Reload the updated Lua script.');
    if (value.configured && !value.studio_source) throw new Error('Studio Display capture is not configured.');
    const clean = {};
    for (const key of KEYS) clean[key] = value[key];
    if (value.detect_hotkey !== undefined) {
      if (value.detect_hotkey !== prefix + '.detect' ||
          typeof value.mac_available !== 'boolean' || typeof value.studio_available !== 'boolean') throw new Error('Invalid display detection metadata. Reload the Lua script.');
      clean.detect_hotkey = value.detect_hotkey;
      for (const key of ['mac_available', 'studio_available']) clean[key] = value[key];
      for (const key of ['mac_display_status', 'studio_display_status', 'detection_error']) {
        if (typeof value[key] !== 'string' || value[key].length > 2000) throw new Error('Invalid display status. Reload the Lua script.');
        clean[key] = value[key];
      }
    }
    return clean;
  }
  function displayAvailable(metadata, display) { return !!metadata && (!metadata.detect_hotkey || metadata[display + '_available'] === true); }
  function observeScene(metadata, sceneItems) {
    const invalid = error => ({ selected: null, holding: true, transitioning: false, valid: false, error });
    if (!Array.isArray(sceneItems)) return invalid('OBS did not return scene items. Refresh the connection.');
    if (!metadata.studio_source) return invalid('Choose a Studio Display capture in Tools → Scripts, then Create / Update off program.');
    function one(name) {
      const matches = sceneItems.filter(item => item && item.sourceName === name);
      return matches.length === 1 && typeof matches[0].sceneItemEnabled === 'boolean' ? matches[0] : null;
    }
    const mac = one(metadata.primary_source), studio = one(metadata.studio_source), shield = one(metadata.scene_name + SHIELD);
    if (!mac || !studio || !shield) return invalid('A capture or safety cover is missing or duplicated. Rebuild Desktop Auto off program in Tools → Scripts.');
    const wipes = sceneItems.filter(item => item && item.sourceName === metadata.scene_name + WIPE);
    if (wipes.length > 1 || (wipes.length === 1 && (typeof wipes[0].sceneItemEnabled !== 'boolean' || (Object.prototype.hasOwnProperty.call(wipes[0], 'inputKind') && wipes[0].inputKind !== 'ffmpeg_source')))) return invalid('The display wipe item is duplicated or incompatible. Rebuild Desktop Auto off program in Tools → Scripts.');
    if (mac.sceneItemEnabled && studio.sceneItemEnabled) return invalid('Both captures are enabled. Rebuild Desktop Auto off program before using these controls.');
    if (!mac.sceneItemEnabled && !studio.sceneItemEnabled) return invalid('Neither capture is enabled. Recheck or rebuild Desktop Auto off program in Tools → Scripts.');
    return { selected: studio.sceneItemEnabled ? 'studio' : 'mac', holding: shield.sceneItemEnabled, transitioning: wipes.length === 1 && wipes[0].sceneItemEnabled, valid: true, error: null };
  }
  async function makeAuthentication(password, salt, challenge, cryptoApi) {
    const api = cryptoApi || root.crypto;
    if (!api || !api.subtle || typeof api.subtle.digest !== 'function') throw new Error('Secure hashing is unavailable in this browser. Open this local dock inside OBS.');
    const encoder = new TextEncoder();
    async function digest(text) {
      const bytes = new Uint8Array(await api.subtle.digest('SHA-256', encoder.encode(text)));
      let binary = '';
      for (const byte of bytes) binary += String.fromCharCode(byte);
      return btoa(binary);
    }
    const secret = await digest(password + salt);
    return digest(secret + challenge);
  }
  class DockClient {
    constructor(options = {}) {
      this.WebSocket = options.WebSocket || root.WebSocket;
      this.crypto = options.crypto || root.crypto;
      this.onState = options.onState || function () {};
      this.requestTimeoutMs = options.requestTimeoutMs || 3000;
      this.pollMs = options.pollMs || 200;
      this.metadataMs = options.metadataMs || 2000;
      this.selectionTimeoutMs = options.selectionTimeoutMs || 15000;
      this.requests = new Map(); this.hotkeys = new Set(); this.serial = 0; this.generation = 0; this.actionError = '';
      this.ws = null; this.identified = false; this.identifySent = false; this.authenticate = null; this.releaseAuthentication = null; this.pollTimer = null; this.metadataTimer = null; this.pendingTimer = null; this.helloTimer = null;
      this.refreshBusy = false; this.pollBusy = false;
      this.state = { connection: 'offline', message: 'Choose a display here after connecting.', automations: [], selectedInstance: '', metadata: null, observed: null, ready: false, pending: null, detecting: false, error: '' };
    }
    emit(patch = {}) { Object.assign(this.state, patch); this.onState({ ...this.state }); }
    clearTimers() {
      for (const key of ['pollTimer', 'metadataTimer', 'pendingTimer', 'helloTimer']) { if (this[key]) clearTimeout(this[key]); this[key] = null; }
    }
    failRequests(message) {
      for (const request of this.requests.values()) { clearTimeout(request.timer); request.reject(new Error(message)); }
      this.requests.clear();
    }
    disconnect() {
      ++this.generation; this.clearTimers(); this.failRequests('Disconnected from OBS.');
      const socket = this.ws; this.ws = null; this.identified = false; this.identifySent = false;
      if (this.releaseAuthentication) this.releaseAuthentication();
      this.authenticate = this.releaseAuthentication = null; this.hotkeys.clear();
      this.refreshBusy = false; this.pollBusy = false;
      this.actionError = '';
      if (socket) socket.close();
      this.emit({ connection: 'offline', ready: false, pending: null, detecting: false, metadata: null, observed: null, automations: [], selectedInstance: '', error: '', message: 'Disconnected. Connect again when ready.' });
    }
    connect({ port = 4455, authenticate, password = '' } = {}) {
      const portText = String(port);
      if (!/^\d{1,5}$/.test(portText) || Number(portText) < 1 || Number(portText) > 65535) throw new Error('Enter a port from 1 to 65535.');
      if (typeof this.WebSocket !== 'function') throw new Error('WebSocket is unavailable. Open this dock in OBS.');
      this.disconnect();
      const generation = this.generation;
      if (authenticate !== undefined && typeof authenticate !== 'function') throw new Error('Invalid authentication provider.');
      // Legacy programmatic callers may supply a one-use password; the dock UI never does.
      let oneShotPassword = authenticate ? '' : String(password);
      password = '';
      this.releaseAuthentication = () => { oneShotPassword = ''; };
      this.authenticate = authenticate || (async (salt, challenge) => {
        let value = oneShotPassword; oneShotPassword = '';
        try { return await makeAuthentication(value, salt, challenge, this.crypto); } finally { value = ''; }
      });
      this.emit({ connection: 'connecting', message: 'Connecting to local OBS…', error: '' });
      let socket;
      try { socket = new this.WebSocket('ws://127.0.0.1:' + Number(portText), 'obswebsocket.json'); }
      catch (_) { this.connectionError('Could not open a local connection. Check the OBS WebSocket port.', generation); return; }
      this.ws = socket;
      this.helloTimer = setTimeout(() => this.connectionError('OBS did not finish connecting. Check WebSocket Server Settings, port, and password.', generation), 45000);
      socket.onmessage = event => { if (generation === this.generation) this.receive(event.data, generation).catch(error => this.connectionError(error.message, generation)); };
      socket.onerror = () => { if (generation === this.generation) this.connectionError('Cannot reach OBS. Enable its WebSocket server and check the port.', generation); };
      socket.onclose = event => {
        if (generation !== this.generation) return;
        const message = event && event.code === 4009 ? 'Authentication failed. Enter the WebSocket password from OBS.' : 'OBS connection closed. Reconnect manually; no commands were queued.';
        this.connectionError(message, generation);
      };
    }
    connectionError(message, generation) {
      if (generation !== this.generation) return;
      this.disconnect(); this.emit({ error: message, message: 'Offline / Sin conexión.' });
    }
    async receive(raw, generation) {
      let message;
      try { message = JSON.parse(raw); } catch (_) { throw new Error('OBS returned an unreadable message. Reconnect.'); }
      if (!message || !message.d) throw new Error('OBS returned an invalid message. Reconnect.');
      if (message.op === 0) {
        if (this.identified || this.identifySent) throw new Error('Unexpected OBS handshake. Reconnect.');
        if (!Number.isInteger(message.d.rpcVersion) || message.d.rpcVersion < 1) throw new Error('This dock needs OBS WebSocket 5.');
        this.identifySent = true;
        const data = { rpcVersion: 1, eventSubscriptions: 0 };
        if (message.d.authentication) {
          const auth = message.d.authentication;
          if (typeof auth.salt !== 'string' || typeof auth.challenge !== 'string') throw new Error('Invalid OBS authentication challenge.');
          const authenticate = this.authenticate, release = this.releaseAuthentication;
          this.authenticate = this.releaseAuthentication = null;
          if (!authenticate) throw new Error('Authentication provider is unavailable. Reconnect.');
          try { data.authentication = await authenticate(auth.salt, auth.challenge); }
          finally { if (release) release(); }
          if (typeof data.authentication !== 'string' || !data.authentication) throw new Error('Invalid OBS authentication response.');
        }
        if (generation !== this.generation || !this.ws) return;
        if (this.releaseAuthentication) this.releaseAuthentication();
        this.authenticate = this.releaseAuthentication = null;
        this.ws.send(JSON.stringify({ op: 1, d: data }));
      } else if (message.op === 2) {
        if (!this.identifySent || this.identified || message.d.negotiatedRpcVersion !== 1) throw new Error('Unexpected OBS identification response.');
        clearTimeout(this.helloTimer); this.helloTimer = null; this.identified = true;
        this.emit({ connection: 'online', message: 'Finding Desktop Auto…' });
        await this.refresh();
        if (generation !== this.generation) return;
        this.scheduleMetadata(generation); this.schedulePoll(generation);
      } else if (message.op === 7) {
        const request = this.requests.get(message.d.requestId);
        if (!request) return;
        clearTimeout(request.timer); this.requests.delete(message.d.requestId);
        if (message.d.requestType !== request.type || !message.d.requestStatus || message.d.requestStatus.result !== true) {
          request.reject(new Error('OBS could not complete ' + request.type + '. Refresh or reconnect.'));
        } else request.resolve(message.d.responseData || {});
      }
    }
    request(type, data = {}) {
      const allowed = ['GetInputList', 'GetInputSettings', 'GetHotkeyList', 'GetSceneItemList', 'TriggerHotkeyByName'];
      if (!allowed.includes(type)) return Promise.reject(new Error('Unsupported dock request.'));
      if (type === 'TriggerHotkeyByName') {
        const metadata = this.state.metadata;
        const detect = metadata && data.hotkeyName === metadata.detect_hotkey;
        const display = metadata && data.hotkeyName === metadata.mac_hotkey ? 'mac' : 'studio';
        if (!metadata || !metadata.enabled || !metadata.configured || (this.state.observed && this.state.observed.transitioning) ||
            !this.hotkeys.has(data.hotkeyName) || (detect ? !!this.state.pending :
            (!this.state.ready || ![metadata.mac_hotkey, metadata.studio_hotkey].includes(data.hotkeyName) || !displayAvailable(metadata, display)))) return Promise.reject(new Error('Unrecognized or unavailable Desktop Auto command.'));
      }
      if (!this.identified || !this.ws || this.ws.readyState !== 1) return Promise.reject(new Error('Connect to OBS first.'));
      const id = 'nrc-dock-' + (++this.serial);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { this.requests.delete(id); reject(new Error('OBS request timed out. Refresh or reconnect.')); }, this.requestTimeoutMs);
        this.requests.set(id, { resolve, reject, timer, type });
        try { this.ws.send(JSON.stringify({ op: 6, d: { requestType: type, requestId: id, requestData: data } })); }
        catch (_) { clearTimeout(timer); this.requests.delete(id); reject(new Error('OBS connection is unavailable. Reconnect.')); }
      });
    }
    scheduleMetadata(generation) {
      this.metadataTimer = setTimeout(async () => {
        this.metadataTimer = null;
        if (generation !== this.generation || !this.identified) return;
        await this.refresh({ clearError: false });
        if (generation === this.generation && this.identified) this.scheduleMetadata(generation);
      }, this.metadataMs);
    }
    schedulePoll(generation) {
      this.pollTimer = setTimeout(async () => {
        this.pollTimer = null;
        if (generation !== this.generation || !this.identified) return;
        await this.pollScene();
        if (generation === this.generation && this.identified) this.schedulePoll(generation);
      }, this.pollMs);
    }
    async refresh({ clearError = true } = {}) {
      if (clearError) { this.actionError = ''; this.emit({ error: '' }); }
      if (!this.identified || this.refreshBusy) return;
      this.refreshBusy = true;
      const generation = this.generation;
      try {
        const [list, keys] = await Promise.all([this.request('GetInputList'), this.request('GetHotkeyList')]);
        if (generation !== this.generation) return;
        if (!Array.isArray(list.inputs) || !Array.isArray(keys.hotkeys)) throw new Error('OBS returned an invalid source or hotkey list.');
        this.hotkeys = new Set(keys.hotkeys.filter(key => typeof key === 'string'));
        const backgrounds = list.inputs.filter(input => input && typeof input.inputName === 'string' && input.inputName.endsWith(SUFFIX));
        const automations = [], issues = [];
        for (const input of backgrounds) {
          try {
            const result = await this.request('GetInputSettings', { inputName: input.inputName });
            const metadata = validateMetadata(result.inputSettings && result.inputSettings.nrc_desktop_dock);
            if (input.inputName !== metadata.scene_name + SUFFIX) throw new Error('Desktop Auto source name does not match its metadata.');
            automations.push({ id: metadata.instance_id, label: metadata.scene_name, inputName: input.inputName, metadata });
          } catch (error) { issues.push(error.message); }
          if (generation !== this.generation) return;
        }
        const ids = new Set();
        for (const automation of automations) { if (ids.has(automation.id)) throw new Error('Duplicate Desktop Auto identity found. Reload only one copy of the Lua script.'); ids.add(automation.id); }
        let selected = this.state.selectedInstance;
        if (!automations.some(item => item.id === selected)) selected = automations.length === 1 ? automations[0].id : '';
        const choice = automations.find(item => item.id === selected);
        const metadata = choice ? choice.metadata : null;
        const changed = JSON.stringify(metadata) !== JSON.stringify(this.state.metadata);
        if (changed && this.state.pending) this.cancelPending('Automation settings changed during the request. Check the selected scene, then try again.');
        this.emit({ automations, selectedInstance: selected, metadata, ...(changed ? { observed: null, ready: false, error: '' } : {}) });
        if (!metadata) {
          this.emit({ ready: false, observed: null, message: automations.length > 1 ? 'Choose the Desktop Auto scene to control.' : 'Reload the updated Lua script to publish its dock connection.', error: !automations.length && issues.length ? issues[0] : '' });
        } else await this.pollScene();
      } catch (error) {
        if (generation === this.generation) this.emit({ ready: false, observed: null, error: error.message, message: 'Refresh the dock connection.' });
      } finally { if (generation === this.generation) this.refreshBusy = false; }
    }
    selectAutomation(instanceId) {
      const choice = this.state.automations.find(item => item.id === instanceId);
      this.cancelPending();
      this.emit({ selectedInstance: choice ? choice.id : '', metadata: choice ? choice.metadata : null, observed: null, ready: false, error: '', message: choice ? 'Checking selected Desktop Auto scene…' : 'Choose the Desktop Auto scene to control.' });
      if (choice) this.pollScene();
    }
    async pollScene() {
      if (!this.identified || this.pollBusy || !this.state.metadata) return;
      const metadata = this.state.metadata, generation = this.generation;
      if (!metadata.enabled || !metadata.configured) {
        this.emit({ ready: false, observed: null, message: metadata.enabled ? 'Check Desktop Auto status in Tools → Scripts. Rebuild off program if needed.' : 'Enable Desktop Auto monitoring in Tools → Scripts.', error: metadata.enabled ? 'The saved Desktop Auto setup does not match its managed scene. Check the script status in Tools → Scripts.' : 'Desktop Auto monitoring is disabled. Enable it in Tools → Scripts.' }); return;
      }
      if (!this.hotkeys.has(metadata.mac_hotkey) || !this.hotkeys.has(metadata.studio_hotkey)) {
        this.emit({ ready: false, observed: null, message: 'Reload the updated Lua script, then Refresh.', error: 'Desktop Auto display commands are not registered.' }); return;
      }
      this.pollBusy = true;
      try {
        const response = await this.request('GetSceneItemList', { sceneName: metadata.scene_name });
        if (generation !== this.generation || this.state.metadata !== metadata) return;
        const observed = observeScene(metadata, response.sceneItems);
        if (!observed.valid) { this.emit({ observed, ready: false, error: observed.error, message: 'Desktop Auto needs attention.' }); return; }
        if (this.state.pending && this.state.pending === observed.selected) this.cancelPending('', { observed, ready: !observed.transitioning });
        this.emit({ observed, ready: !observed.transitioning, error: this.actionError, message: metadata.detection_error || (observed.transitioning ? 'Loading / Cargando…' : metadata.detect_hotkey && !metadata.mac_available && !metadata.studio_available ? 'No displays detected. Connect a display or press Detect / Refresh displays.' : observed.holding ? 'Checking capture dimensions / Comprobando captura…' : 'Display fitted automatically / Pantalla ajustada automáticamente.') });
      } catch (error) {
        if (generation === this.generation) this.emit({ ready: false, observed: null, error: error.message, message: 'Could not observe Desktop Auto. Refresh or reconnect.' });
      } finally { if (generation === this.generation) this.pollBusy = false; }
    }
    cancelPending(error = '', patch = {}) {
      if (this.pendingTimer) clearTimeout(this.pendingTimer);
      this.pendingTimer = null;
      this.actionError = error;
      this.emit({ pending: null, error, ...patch });
    }
    async detectDisplays() {
      const metadata = this.state.metadata, generation = this.generation;
      if (!metadata?.detect_hotkey || !this.hotkeys.has(metadata.detect_hotkey)) throw new Error('Reload the updated Lua script to enable display detection.');
      if (this.state.detecting) return;
      this.emit({ detecting: true, error: '', message: 'Detecting displays / Detectando pantallas…' });
      try {
        await this.request('TriggerHotkeyByName', { hotkeyName: metadata.detect_hotkey });
        await new Promise(resolve => setTimeout(resolve, 300));
        if (generation === this.generation) await this.refresh();
      } finally { if (generation === this.generation) this.emit({ detecting: false }); }
    }
    async choose(display) {
      if (display !== 'mac' && display !== 'studio') throw new Error('Choose MacBook Pro or Studio Display.');
      if (!this.state.ready || this.state.pending || !this.state.metadata || !this.identified || (this.state.observed && this.state.observed.transitioning)) throw new Error('The dock is not ready. Wait for loading to finish, or Refresh and reconnect to OBS.');
      if (!displayAvailable(this.state.metadata, display)) throw new Error('This display is not connected. Connect it or press Detect / Refresh displays.');
      if (this.state.detecting) throw new Error('Display detection is in progress.');
      if (this.state.observed && this.state.observed.selected === display) return;
      const metadata = this.state.metadata, generation = this.generation;
      const hotkey = display === 'studio' ? metadata.studio_hotkey : metadata.mac_hotkey;
      if (!this.hotkeys.has(hotkey)) throw new Error('Display command is unavailable. Reload the Lua script and Refresh.');
      this.actionError = '';
      this.emit({ pending: display, error: '', message: 'Request sent. Waiting for OBS to confirm the selected capture…' });
      this.pendingTimer = setTimeout(() => {
        this.pendingTimer = null;
        if (generation === this.generation && this.state.pending) this.cancelPending('OBS did not confirm the switch. Check the Lua script status in Tools → Scripts, then Refresh.');
      }, this.selectionTimeoutMs);
      try {
        await this.request('TriggerHotkeyByName', { hotkeyName: hotkey });
        if (generation === this.generation) await this.pollScene();
      } catch (error) { if (generation === this.generation) this.cancelPending(error.message); }
    }
  }
  const api = { DockClient, validateMetadata, observeScene, makeAuthentication, displayAvailable };
  root.NRCDock = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof document === 'undefined') return;
  function init() {
    const elements = {};
    for (const id of ['connection', 'demo-label', 'automation-picker', 'automation', 'choose-mac', 'choose-studio', 'mac-source', 'studio-source', 'status-dot', 'observed', 'status-message', 'error', 'settings', 'port', 'password', 'connect', 'refresh', 'detect-displays', 'keychain-status', 'keychain-setup', 'forget-password']) elements[id] = document.getElementById(id);
    const demo = new URLSearchParams(root.location.search).get('demo') === '1';
    let lastAutomationOptions = '', lastConnection = 'offline';
    let credentialState = { saved: false, busy: false, available: false };
    let credentials;
    function render(state) {
      elements.connection.textContent = demo ? 'Demo' : state.connection === 'online' ? 'Connected' : state.connection === 'connecting' ? 'Connecting' : 'Offline';
      elements.connection.classList.toggle('online', state.connection === 'online');
      if (state.connection === 'online' && lastConnection !== 'online') elements.settings.open = false;
      if (state.connection === 'offline' && lastConnection !== 'offline') elements.settings.open = true;
      lastConnection = state.connection;
      const selected = state.observed && state.observed.valid ? state.observed.selected : null;
      for (const display of ['mac', 'studio']) {
        elements['choose-' + display].setAttribute('aria-pressed', String(selected === display));
        elements['choose-' + display].disabled = demo || !state.ready || !!state.pending || !!state.detecting || !displayAvailable(state.metadata, display);
      }
      elements['mac-source'].textContent = state.metadata ? state.metadata.primary_source : 'Primary capture / Captura principal';
      elements['studio-source'].textContent = state.metadata && state.metadata.studio_source ? state.metadata.studio_source : 'Second capture / Segunda captura';
      for (const display of ['mac', 'studio']) {
        const status = state.metadata?.[display + '_display_status'];
        if (status) elements[display + '-source'].textContent = status;
      }
      elements['detect-displays'].disabled = demo || state.connection !== 'online' || !state.metadata?.enabled || !state.metadata?.configured || !state.metadata?.detect_hotkey || !!state.pending || !!state.detecting || !!state.observed?.transitioning;
      elements['detect-displays'].textContent = state.detecting ? 'Detecting… / Detectando…' : 'Detect / Refresh displays';
      elements['status-dot'].className = 'status-dot' + (state.observed && state.observed.valid ? state.observed.holding || state.observed.transitioning ? ' hold' : ' ready' : '');
      elements.observed.textContent = demo ? 'MacBook Pro · Demo / Vista previa' : selected ? (selected === 'mac' ? 'MacBook Pro' : 'Studio Display') + (state.observed.transitioning ? ' · Loading / Cargando' : state.observed.holding ? ' · Checking / Comprobando' : ' · Active / Activa') : state.connection === 'online' ? 'Desktop Auto' : 'Connect to OBS / Conectar a OBS';
      elements['status-message'].textContent = state.observed && state.observed.transitioning ? 'Loading / Cargando…' : state.pending ? 'Request sent. Waiting for OBS to confirm… / Esperando confirmación…' : state.message;
      elements.error.textContent = state.error || ''; elements.error.hidden = !state.error;
      elements['automation-picker'].hidden = state.automations.length <= 1;
      const optionsSignature = JSON.stringify(state.automations.map(item => [item.id, item.label]));
      if (optionsSignature !== lastAutomationOptions) {
        elements.automation.replaceChildren();
        const placeholder = document.createElement('option'); placeholder.value = ''; placeholder.textContent = 'Choose an automation / Elegir'; elements.automation.appendChild(placeholder);
        for (const automation of state.automations) { const option = document.createElement('option'); option.value = automation.id; option.textContent = automation.label; elements.automation.appendChild(option); }
        lastAutomationOptions = optionsSignature;
      }
      elements.automation.value = state.selectedInstance;
      elements.connect.textContent = state.connection === 'offline' ? 'Connect / Conectar' : 'Disconnect / Desconectar';
      elements.refresh.disabled = demo || state.connection !== 'online';
      elements.connect.disabled = demo || credentialState.busy || !credentialState.available;
      elements.port.disabled = demo || credentialState.busy || state.connection !== 'offline';
      elements.password.disabled = demo || credentialState.busy || !credentialState.available || state.connection !== 'offline';
      elements['forget-password'].disabled = demo || credentialState.busy || !credentialState.saved;
      elements['keychain-status'].textContent = credentialState.busy ? 'Checking Keychain…' : credentialState.saved ? 'Password saved in macOS Keychain / Contraseña guardada.' : credentialState.available ? 'No saved password for this port / Sin contraseña guardada.' : 'Keychain helper required / Inicia el asistente del Llavero.';
      elements['keychain-setup'].hidden = demo || credentialState.available;
      elements.password.placeholder = credentialState.saved ? 'Leave blank to reuse · enter a replacement' : 'OBS → Tools → WebSocket Server Settings';
    }
    if (demo) {
      elements['demo-label'].hidden = false; elements.settings.open = false; elements.connect.disabled = true;
      render({ connection: 'online', automations: [], selectedInstance: '', metadata: { primary_source: 'MacBook Pro capture', studio_source: 'Studio Display capture' }, observed: { selected: 'mac', holding: false, valid: true }, ready: false, pending: null, error: '', message: 'Local dock preview / Vista previa del panel.' });
      return;
    }
    const client = new DockClient({ onState: render });
    if (root.NRCKeychain) {
      credentials = new root.NRCKeychain.ConnectionCredentials({ onState: next => { credentialState = next; render(client.state); } });
      credentialState = credentials.state;
      elements.port.value = credentials.preferredPort();
    }
    render(client.state);
    const report = error => client.emit({ error: error.message });
    if (credentials) credentials.check(client, elements.port.value, true).catch(report);
    else client.emit({ error: 'Keychain support file is missing. Reinstall this dock with the shared folder.' });
    elements.connect.addEventListener('click', () => {
      if (client.state.connection !== 'offline') { if (credentials) credentials.cancel(); client.disconnect(); return; }
      if (credentials) credentials.connect(client, elements.port.value, elements.password).catch(report);
    });
    elements.port.addEventListener('change', () => {
      elements.password.value = '';
      if (credentials) credentials.check(client, elements.port.value).catch(report);
    });
    elements['forget-password'].addEventListener('click', () => {
      elements.password.value = '';
      if (credentials) credentials.forget(client, elements.port.value).catch(report);
    });
    elements['detect-displays'].addEventListener('click', () => client.detectDisplays().catch(report));
    elements.refresh.addEventListener('click', () => { client.emit({ error: '' }); client.refresh(); });
    elements.automation.addEventListener('change', () => client.selectAutomation(elements.automation.value));
    for (const display of ['mac', 'studio']) elements['choose-' + display].addEventListener('click', () => client.choose(display).catch(error => client.emit({ error: error.message })));
    root.addEventListener('pagehide', () => { elements.password.value = ''; if (credentials) credentials.cancel(); client.disconnect(); });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})(typeof globalThis !== 'undefined' ? globalThis : this);
