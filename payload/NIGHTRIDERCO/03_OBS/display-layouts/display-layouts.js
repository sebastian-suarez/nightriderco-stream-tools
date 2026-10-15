/* Independent, offline bilingual controller for display-aware OBS overlays. */
(() => {
  "use strict";
  const config = window.NRC_CONFIG || {};
  const dictionary = {
    session: { en: "BUILD · RACE · EXPLORE", es: "CREA · CORRE · EXPLORA" },
    camera: { en: "ON CAMERA", es: "EN CÁMARA" },
    skadi: { en: "WINTER HUNTRESS", es: "CAZADORA DEL INVIERNO" },
    topic: { en: "SIMRACING · CODE · IRL", es: "SIMRACING · CÓDIGO · IRL" },
    ride: { en: "THE NEXT RIDE STARTS HERE", es: "LA PRÓXIMA RUTA EMPIEZA AQUÍ" }
  };
  const allowed = new Set(["auto", "en", "es"]);
  const queryLanguage = new URLSearchParams(window.location.search || "").get("lang");
  const requested = queryLanguage || config.defaultLanguage;
  const mode = allowed.has(requested) ? requested : "auto";
  const configuredInterval = Number(config.languageInterval);
  const interval = Number.isFinite(configuredInterval) && configuredInterval >= 1000 ? configuredInterval : 6000;
  const nodes = Array.from(document.querySelectorAll("[data-i18n]"));
  let language = mode === "es" ? "es" : "en";
  let fadeTimer = null;
  let intervalTimer = null;

  function applyLanguage() {
    document.documentElement.lang = language;
    for (const node of nodes) {
      const pair = dictionary[node.dataset.i18n];
      if (pair) node.textContent = pair[language] || pair.en;
      node.classList.remove("changing");
    }
  }
  function switchLanguage() {
    for (const node of nodes) node.classList.add("changing");
    fadeTimer = window.setTimeout(() => {
      language = language === "en" ? "es" : "en";
      applyLanguage();
      fadeTimer = null;
    }, 180);
  }
  function fitStage() {
    const stage = document.getElementById("stage");
    if (!stage) return;
    const scale = Math.min(window.innerWidth / 2560, window.innerHeight / 1440);
    stage.style.transform = `scale(${scale})`;
    stage.style.left = `${(window.innerWidth - 2560 * scale) / 2}px`;
    stage.style.top = `${(window.innerHeight - 1440 * scale) / 2}px`;
  }
  applyLanguage();
  fitStage();
  window.addEventListener("resize", fitStage);
  if (mode === "auto") intervalTimer = window.setInterval(switchLanguage, interval);
  window.addEventListener("unload", () => {
    if (intervalTimer !== null) window.clearInterval(intervalTimer);
    if (fadeTimer !== null) window.clearTimeout(fadeTimer);
  });
})();
