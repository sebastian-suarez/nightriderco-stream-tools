(() => {
  'use strict';

  const byId = id => document.getElementById(id);
  const demo = new URLSearchParams(window.location.search).get('demo') === '1';
  const presets = ['top-left', 'top-right', 'bottom-left', 'bottom-right'];
  let state = {
    connection: 'offline', sceneChoice: 'auto', sceneName: null, activeScene: null,
    busy: false, ready: false, missing: false, error: '', message: '', observed: null
  };
  let lastConnection = 'offline';
  let localError = '';
  let client;
  let credentials;
  let credentialState = { saved: false, busy: false, available: false };
  const positionButtons = [...document.querySelectorAll('.position-button')];

  const defaults = {
    camera: { visible: true, preset: 'bottom-left', transform: { positionX: 52, positionY: 992, width: 576, height: 331 } },
    chat: { visible: true, preset: 'bottom-right', transform: { positionX: 2024, positionY: 680, width: 476, height: 646.1 } }
  };

  function finite(value, fallback) {
    return Number.isFinite(Number(value)) ? Number(value) : fallback;
  }

  function drawItem(kind, item) {
    const fallback = defaults[kind].transform;
    const rawTransform = item.transform || fallback;
    const f = state.canvasWidth ? 2560 / state.canvasWidth : 1;
    const transform = {...rawTransform};
    if (item.transform) for (const key of ['positionX','positionY','width','height']) transform[key] *= f;
    const x = finite(transform.positionX, fallback.positionX);
    const y = finite(transform.positionY, fallback.positionY);
    const width = Math.max(1, finite(transform.width, fallback.width));
    const height = Math.max(1, finite(transform.height, fallback.height));
    const rect = byId(`map-${kind}-rect`);
    Object.entries({ x, y, width, height }).forEach(([name, value]) => rect.setAttribute(name, value));
    const label = byId(`map-${kind}-label`);
    label.setAttribute('x', x + width / 2);
    label.setAttribute('y', y + height / 2 + 3);
    byId(`map-${kind}`).classList.toggle('is-hidden', !item.visible);
    if (kind === 'camera') {
      const inset = Math.min(width, height) * .024;
      const aperture = byId('map-camera-aperture');
      Object.entries({ x: x + inset, y: y + inset, width: width - inset * 2, height: height - inset * 2 })
        .forEach(([name, value]) => aperture.setAttribute(name, value));
    }
  }

  function render(nextState) {
    state = { ...state, ...nextState };
    byId('map-size').textContent = `${state.canvasWidth || 2560} × ${state.canvasHeight || 1440}`;
    const online = state.connection === 'online';
    const connecting = state.connection === 'connecting';
    const canControl = online && state.ready && !state.busy && Boolean(state.observed);
    const status = byId('connection-status');
    status.classList.toggle('online', online);
    status.classList.toggle('connecting', connecting);
    byId('connection-label').textContent = demo ? 'Demo' : online ? 'Connected' : connecting ? 'Connecting' : 'Offline';
    byId('dock').classList.toggle('is-busy', Boolean(state.busy));
    byId('dock').setAttribute('aria-busy', String(Boolean(state.busy)));
    byId('scene-select').value = state.sceneChoice || 'auto';
    byId('scene-select').disabled = state.busy;
    byId('scene-follow-label').textContent = state.sceneChoice === 'auto' ? 'Follow active' : 'Pinned scene';
    byId('map-scene').textContent = state.sceneName || (online ? 'Choose a supported scene' : 'No scene connected');
    byId('map-live-dot').classList.toggle('is-live', online && Boolean(state.observed));
    byId('map-offline').hidden = online && Boolean(state.observed);
    byId('map-offline').textContent = online ? state.missing ? 'Scene setup required' : 'Select Workshop or Gameplay' : connecting ? 'Connecting to OBS…' : 'Connect to view layout';
    byId('setup-notice').hidden = !(online && state.missing);
    byId('prepare-button').disabled = !online || !state.missing || state.busy;

    for (const kind of ['camera', 'chat']) {
      const observed = state.observed?.[kind];
      drawItem(kind, observed || defaults[kind]);
      const visible = Boolean(observed?.visible);
      const toggle = byId(`${kind}-visibility`);
      toggle.disabled = !canControl;
      toggle.setAttribute('aria-checked', String(visible));
      toggle.setAttribute('aria-label', `${visible ? 'Hide' : 'Show'} ${kind === 'camera' ? 'Camera Switch' : 'chat'}`);
      toggle.querySelector('.visibility-text').textContent = observed ? visible ? 'Visible' : 'Hidden' : '—';
      byId(`${kind}-card`).classList.toggle('is-hidden', Boolean(observed) && !visible);
      byId(`${kind}-caption`).textContent = observed && !visible
        ? kind === 'camera' ? 'Hidden in this scene. Shared selection is unchanged.' : 'Hidden · your position is saved.'
        : kind === 'camera' ? 'Position applies to this scene only.' : 'Choose a corner. Keep the action clear.';
    }
    positionButtons.forEach(button => {
      const selected = state.observed?.[button.dataset.kind]?.preset === button.dataset.preset;
      button.disabled = !canControl;
      button.setAttribute('aria-pressed', String(selected));
    });

    const error = localError || state.error || '';
    byId('error-notice').hidden = !error;
    byId('error-notice').textContent = error;
    byId('activity-message').textContent = state.busy ? 'Updating scene…' : state.message || (demo ? 'Demo controls are interactive.' : online && state.ready ? 'Ready. Changes apply immediately.' : online ? 'Select a scene or prepare its controls.' : 'Connect to OBS to enable scene controls.');
    byId('refresh-button').disabled = !online || state.busy;
    byId('connect-button').hidden = online;
    byId('connect-button').disabled = connecting || state.busy || credentialState.busy || !credentialState.available;
    byId('connect-button').firstChild.textContent = connecting ? 'Connecting…' : 'Connect to OBS';
    byId('disconnect-button').hidden = !online && !connecting;
    byId('port-input').disabled = online || connecting || credentialState.busy;
    byId('password-input').disabled = online || connecting || credentialState.busy || !credentialState.available;
    byId('forget-password').disabled = credentialState.busy || !credentialState.saved;
    byId('keychain-status').textContent = credentialState.busy ? 'Checking Keychain…' : credentialState.saved ? 'Password saved in macOS Keychain.' : credentialState.available ? 'No saved password for this port.' : 'Start the Keychain helper to connect.';
    byId('keychain-setup').hidden = demo || credentialState.available;
    byId('password-input').placeholder = credentialState.saved ? 'Leave blank to reuse · enter a replacement' : 'OBS WebSocket password';
    document.querySelector('.connection-fields').hidden = online;
    if (online && lastConnection !== 'online' && !demo) byId('connection-panel').open = false;
    lastConnection = state.connection;
  }

  async function perform(action) {
    localError = '';
    try {
      await action();
    } catch (error) {
      localError = error?.message || 'Could not update OBS. Refresh and try again.';
      render({});
    }
  }

  function createDemoClient() {
    const sceneLayouts = {
      Workshop: JSON.parse(JSON.stringify(defaults)),
      Gameplay: JSON.parse(JSON.stringify(defaults))
    };
    const demoState = {
      connection: 'online', sceneChoice: 'auto', sceneName: 'Workshop', activeScene: 'Workshop',
      busy: false, ready: true, missing: false, error: '', message: 'Demo controls are interactive.', observed: sceneLayouts.Workshop
    };
    const update = () => render({ ...demoState, observed: sceneLayouts[demoState.sceneName] });
    const labels = { 'top-left': 'top left', 'top-right': 'top right', 'bottom-left': 'bottom left', 'bottom-right': 'bottom right' };
    return {
      start: update,
      selectScene(value) {
        demoState.sceneChoice = value;
        demoState.sceneName = value === 'auto' ? demoState.activeScene : value;
        demoState.message = `Previewing ${demoState.sceneName}.`;
        update();
      },
      move(kind, preset) {
        if (!presets.includes(preset)) return;
        const item = sceneLayouts[demoState.sceneName][kind];
        const position = window.NRCLayout.PRESETS[kind][preset];
        Object.assign(item.transform, position);
        item.preset = preset;
        demoState.message = `${kind === 'camera' ? 'Camera Switch' : 'Chat'} moved to ${labels[preset]}.`;
        update();
      },
      setVisible(kind, visible) {
        sceneLayouts[demoState.sceneName][kind].visible = visible;
        demoState.message = `${kind === 'camera' ? 'Camera Switch' : 'Chat'} ${visible ? 'shown' : 'hidden'}.`;
        update();
      },
      refresh() { demoState.message = 'Demo layout refreshed.'; update(); },
      disconnect() {}, connect() {}, prepare() {}
    };
  }

  byId('demo-banner').hidden = !demo;
  byId('connection-panel').hidden = demo;
  const compactQuery = window.matchMedia('(max-height: 600px)');
  if (compactQuery.matches) byId('connection-panel').open = false;
  compactQuery.addEventListener('change', event => {
    if (event.matches) byId('connection-panel').open = false;
  });
  byId('map-toggle').addEventListener('click', () => {
    const expanded = byId('dock').classList.toggle('show-compact-map');
    byId('map-toggle').setAttribute('aria-expanded', String(expanded));
    byId('map-toggle').textContent = expanded ? 'Hide map' : 'Show map';
  });
  if (demo) {
    client = createDemoClient();
    client.start();
  } else if (window.NRCLayout?.LayoutClient) {
    client = new window.NRCLayout.LayoutClient({ onState: render });
    if (window.NRCKeychain) {
      credentials = new window.NRCKeychain.ConnectionCredentials({ onState: next => { credentialState = next; render({}); } });
      credentialState = credentials.state;
      byId('port-input').value = credentials.preferredPort();
      byId('connection-address').textContent = `Local · ${byId('port-input').value}`;
      perform(() => credentials.check(client, byId('port-input').value, true));
    } else localError = 'Keychain support file is missing. Reinstall this dock with the shared folder.';
    render({});
  } else {
    localError = 'The dock support file is missing. Keep layout-core.js beside this HTML file.';
    render({});
  }

  byId('scene-select').addEventListener('change', event => {
    if (client) perform(() => client.selectScene(event.target.value));
  });
  positionButtons.forEach(button => button.addEventListener('click', () => {
    if (client) perform(() => client.move(button.dataset.kind, button.dataset.preset));
  }));
  for (const kind of ['camera', 'chat']) {
    byId(`${kind}-visibility`).addEventListener('click', () => {
      if (client && state.observed?.[kind]) perform(() => client.setVisible(kind, !state.observed[kind].visible));
    });
  }
  byId('refresh-button').addEventListener('click', () => client && perform(() => client.refresh()));
  byId('prepare-button').addEventListener('click', () => client && perform(() => client.prepare()));
  byId('disconnect-button').addEventListener('click', () => {
    if (credentials) credentials.cancel();
    if (client) perform(() => client.disconnect());
  });
  byId('port-input').addEventListener('change', () => {
    byId('password-input').value = '';
    if (credentials) perform(() => credentials.check(client, byId('port-input').value));
  });
  byId('forget-password').addEventListener('click', () => {
    byId('password-input').value = '';
    if (credentials) perform(() => credentials.forget(client, byId('port-input').value));
  });
  byId('connection-form').addEventListener('submit', event => {
    event.preventDefault();
    if (!client || demo) return;
    const portInput = byId('port-input');
    if (!portInput.reportValidity()) return;
    const port = Number(portInput.value);
    const passwordInput = byId('password-input');
    byId('connection-address').textContent = `Local · ${port}`;
    if (credentials) perform(() => credentials.connect(client, port, passwordInput));
  });
  window.addEventListener('pagehide', () => {
    byId('password-input').value = '';
    if (credentials) credentials.cancel();
    if (!demo && client) client.disconnect();
  });
})();
