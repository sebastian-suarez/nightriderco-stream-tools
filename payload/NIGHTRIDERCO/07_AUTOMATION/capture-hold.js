/* Opaque, silent Nordic holding animation. No OBS controls or network calls. */
(function (root) {
  'use strict';
  const LOOP_MS = 1350;
  const COLORS = { slate: '#0B1118', steel: '#152330', ice: '#74DFFF', snow: '#F1F6F8' };
  const TEXTS = {
    en: ['ONE MOMENT', 'Getting the workspace ready.'],
    es: ['UN MOMENTO', 'Preparando el espacio de trabajo.']
  };
  function ease(value) { return value * value * (3 - 2 * value); }
  function languageAt(elapsedMs, config = {}) {
    if (config.defaultLanguage === 'en' || config.defaultLanguage === 'es') return config.defaultLanguage;
    const specified = Number(config.languageInterval);
    const interval = Math.max(3000, Number.isFinite(specified) && specified > 0 ? specified : 6000);
    return Math.floor(Math.max(0, elapsedMs) / interval) % 2 ? 'es' : 'en';
  }
  function polygon(ctx, points, color) {
    ctx.beginPath(); ctx.moveTo(points[0][0], points[0][1]);
    for (const point of points.slice(1)) ctx.lineTo(point[0], point[1]);
    ctx.closePath(); ctx.fillStyle = color; ctx.fill();
  }
  function drawHoldFrame(ctx, width, height, elapsedMs, reducedMotion = false) {
    // Every frame paints a complete opaque backing before any decoration.
    // CSS and OBS's existing native shield also remain opaque independently.
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over';
    ctx.fillStyle = COLORS.slate; ctx.fillRect(0, 0, width, height);
    // The native stinger uses CoreGraphics' upward y axis. Match its slope
    // while leaving the full opaque backing and DOM text in browser coordinates.
    ctx.save(); ctx.translate(0, height); ctx.scale(1, -1);
    const skew = width * 520 / 2560;
    polygon(ctx, [[width * .38, 0], [width * .73, 0], [width * .92, height], [width * .57, height]], COLORS.steel);
    polygon(ctx, [[-width * .12, 0], [width * .09, 0], [width * .30, height], [0, height]], COLORS.steel);
    ctx.strokeStyle = 'rgba(116,223,255,0.075)'; ctx.lineWidth = Math.max(1, width / 1280);
    for (let x = -width * .25; x < width * 1.25; x += width / 8) {
      ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x + skew, height); ctx.stroke();
    }
    const phase = ((Math.max(0, elapsedMs) % LOOP_MS) / LOOP_MS);
    if (!reducedMotion) {
      // Like the scene stinger: one solid ice blade and a thin snow edge.
      // The ends are fully offscreen, making the loop reset seamless.
      const edge = -skew - width * .08 + (width + skew * 2 + width * .16) * ease(phase);
      const band = width * 42 / 2560;
      polygon(ctx, [[edge - skew / 2 - band, 0], [edge - skew / 2, 0], [edge + skew / 2, height], [edge + skew / 2 - band, height]], COLORS.ice);
      polygon(ctx, [[edge - skew / 2 - band - width * 12 / 2560, 0], [edge - skew / 2 - band - width * 6 / 2560, 0], [edge + skew / 2 - band - width * 6 / 2560, height], [edge + skew / 2 - band - width * 12 / 2560, height]], COLORS.snow);
    }
    ctx.restore();
    return { phase, width, height };
  }
  function createAnimation(options) {
    const { context, getSize, clock, raf, cancelRaf } = options;
    let reducedMotion = !!options.reducedMotion, epoch = clock(), running = false, frameId = null;
    function draw() {
      const size = getSize();
      return drawHoldFrame(context, size.width, size.height, clock() - epoch, reducedMotion);
    }
    function tick() {
      if (!running) return;
      draw();
      if (!reducedMotion) frameId = raf(tick);
    }
    function stop() {
      running = false;
      if (frameId !== null) cancelRaf(frameId);
      frameId = null;
    }
    function start() {
      stop(); running = true; epoch = clock(); tick();
    }
    function restart() { epoch = clock(); if (running) draw(); }
    function handleVisibleEvent(event) {
      if (event && event.detail && event.detail.visible === true) restart();
    }
    function setReducedMotion(value) { reducedMotion = !!value; start(); }
    return { start, stop, restart, draw, handleVisibleEvent, setReducedMotion };
  }
  const api = { LOOP_MS, COLORS, TEXTS, languageAt, drawHoldFrame, createAnimation };
  root.NRCHold = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof document === 'undefined') return;
  function init() {
    const canvas = document.getElementById('ice-motion');
    const ctx = canvas.getContext('2d', { alpha: false });
    const reduced = root.matchMedia('(prefers-reduced-motion: reduce)');
    const loadedAt = root.performance.now();
    const config = root.NRC_CONFIG || {};
    const copy = document.getElementById('copy');
    let lang = languageAt(0, config), languageTimer = null;
    function paintLanguage() {
      document.documentElement.lang = lang;
      document.getElementById('title').textContent = TEXTS[lang][0];
      document.getElementById('subtitle').textContent = TEXTS[lang][1];
    }
    paintLanguage();
    if (config.defaultLanguage !== 'en' && config.defaultLanguage !== 'es') {
      languageTimer = root.setInterval(() => {
        const next = languageAt(root.performance.now() - loadedAt, config);
        if (next === lang) return;
        if (reduced.matches) { lang = next; paintLanguage(); return; }
        copy.classList.add('changing');
        root.setTimeout(() => { lang = next; paintLanguage(); copy.classList.remove('changing'); }, 180);
      }, 200);
    }
    // Text/CSS still work if a browser cannot create the decorative canvas.
    if (!ctx) return;
    function resize() { canvas.width = Math.max(1, root.innerWidth); canvas.height = Math.max(1, root.innerHeight); }
    resize();
    const animation = createAnimation({ context: ctx, getSize: () => ({ width: canvas.width, height: canvas.height }), clock: () => root.performance.now(), raf: callback => root.requestAnimationFrame(callback), cancelRaf: id => root.cancelAnimationFrame(id), reducedMotion: reduced.matches });
    animation.start();
    root.addEventListener('resize', () => { resize(); animation.draw(); });
    root.addEventListener('obsSourceVisibleChanged', animation.handleVisibleEvent);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) animation.restart(); });
    reduced.addEventListener('change', event => animation.setReducedMotion(event.matches));
    root.addEventListener('pagehide', () => { animation.stop(); if (languageTimer !== null) root.clearInterval(languageTimer); });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})(typeof globalThis !== 'undefined' ? globalThis : this);
