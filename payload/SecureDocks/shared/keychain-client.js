/* The browser sends a password once to the local helper. Only macOS Keychain retains it. */
(function (root) {
  'use strict';
  const ORIGIN = 'http://127.0.0.1:17642';
  const PORT_KEY = 'nrc.obs.websocket.port';
  function validPort(value) {
    if (!/^\d{1,5}$/.test(String(value)) || Number(value) < 1 || Number(value) > 65535) throw new Error('Enter a port from 1 to 65535.');
    return Number(value);
  }
  class KeychainClient {
    constructor(options = {}) {
      this.location = options.location || root.location;
      this.fetch = options.fetch || (root.fetch && root.fetch.bind(root));
      this.AbortController = options.AbortController || root.AbortController;
      this.timeoutMs = options.timeoutMs || 35000;
    }
    get available() { return Boolean(this.location && this.location.origin === ORIGIN && typeof this.fetch === 'function'); }
    async request(action, data) {
      if (!this.available) throw new Error('Start the Keychain helper, then open this dock using its local address.');
      const controller = typeof this.AbortController === 'function' ? new this.AbortController() : null;
      let timeout;
      const deadline = new Promise((resolve, reject) => {
        timeout = setTimeout(() => {
          if (controller) controller.abort();
          reject(new Error('Keychain helper timed out. Restart it and reconnect.'));
        }, this.timeoutMs);
      });
      const operation = (async () => {
        let response;
        try {
          response = await this.fetch('/api/' + action, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-NRC-Dock': '1' }, body: JSON.stringify(data), credentials: 'omit', cache: 'no-store', redirect: 'error', ...(controller ? { signal: controller.signal } : {}) });
        } catch (_) { throw new Error('Keychain helper is unavailable. Start it, then reconnect.'); }
        let result;
        try { result = await response.json(); } catch (_) { throw new Error('Keychain helper returned an invalid response. Restart it and reconnect.'); }
        if (!response.ok) throw new Error(result && typeof result.error === 'string' ? result.error : 'Keychain request failed. Check the helper and reconnect.');
        if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error('Keychain helper returned an invalid response.');
        return result;
      })();
      try { return await Promise.race([operation, deadline]); }
      finally { clearTimeout(timeout); }
    }

    async status(port) {
      const result = await this.request('status', { port: validPort(port) });
      if (typeof result.saved !== 'boolean') throw new Error('Invalid Keychain status. Restart the helper.');
      return result.saved;
    }
    async save(port, password) {
      if (typeof password !== 'string' || !password) throw new Error('Enter the OBS WebSocket password to save it.');
      const operation = this.request('save', { port: validPort(port), password });
      password = '';
      const result = await operation;
      if (result.saved !== true) throw new Error('Keychain did not confirm the saved password.');
    }
    async authentication(port, salt, challenge) {
      if (typeof salt !== 'string' || typeof challenge !== 'string' || !salt || !challenge || salt.length > 1024 || challenge.length > 1024) throw new Error('Invalid OBS authentication challenge.');
      const result = await this.request('auth', { port: validPort(port), salt, challenge });
      if (typeof result.authentication !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(result.authentication)) throw new Error('Keychain helper returned invalid authentication.');
      return result.authentication;
    }
    async forget(port) {
      const result = await this.request('forget', { port: validPort(port) });
      if (result.saved !== false) throw new Error('Keychain did not confirm removal.');
    }
  }
  class ConnectionCredentials {
    constructor(options = {}) {
      this.api = options.api || new KeychainClient();
      this.onState = options.onState || function () {};
      this.storage = options.storage;
      if (!Object.prototype.hasOwnProperty.call(options, 'storage')) { try { this.storage = root.localStorage; } catch (_) {} }
      this.generation = 0;
      this.state = { saved: false, busy: false, available: this.api.available };
    }
    emit(patch) { Object.assign(this.state, patch); this.onState({ ...this.state }); }
    preferredPort() {
      try { const value = this.storage && this.storage.getItem(PORT_KEY); return value ? validPort(value) : 4455; } catch (_) { return 4455; }
    }
    rememberPort(port) { try { if (this.storage) this.storage.setItem(PORT_KEY, String(validPort(port))); } catch (_) {} }
    cancel() { ++this.generation; this.emit({ busy: false }); }
    async check(client, port, autoConnect = false) {
      port = validPort(port);
      const generation = ++this.generation;
      this.emit({ busy: true, saved: false });
      try {
        const saved = await this.api.status(port);
        if (generation !== this.generation) return;
        this.emit({ saved });
        if (saved && autoConnect) this.open(client, port);
        return saved;
      } catch (error) { if (generation === this.generation) throw error; }
      finally { if (generation === this.generation) this.emit({ busy: false }); }
    }
    open(client, port) {
      this.rememberPort(port);
      client.connect({ port, authenticate: (salt, challenge) => this.api.authentication(port, salt, challenge) });
    }
    async connect(client, port, passwordInput) {
      port = validPort(port);
      const generation = ++this.generation;
      let password = passwordInput.value;
      passwordInput.value = '';
      this.emit({ busy: true });
      try {
        if (password) {
          let operation;
          try { operation = this.api.save(port, password); } finally { password = ''; }
          await operation;
          if (generation !== this.generation) return;
          this.emit({ saved: true });
        } else {
          const saved = await this.api.status(port);
          if (generation !== this.generation) return;
          this.emit({ saved });
        }
        if (generation === this.generation) this.open(client, port);
      } catch (error) { if (generation === this.generation) throw error; }
      finally { password = ''; if (generation === this.generation) this.emit({ busy: false }); }
    }
    async forget(client, port) {
      port = validPort(port);
      const generation = ++this.generation;
      client.disconnect();
      this.emit({ busy: true });
      try {
        await this.api.forget(port);
        if (generation === this.generation) this.emit({ saved: false });
      } catch (error) { if (generation === this.generation) throw error; }
      finally { if (generation === this.generation) this.emit({ busy: false }); }
    }
  }
  const api = { KeychainClient, ConnectionCredentials, validPort, ORIGIN, PORT_KEY };
  root.NRCKeychain = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
