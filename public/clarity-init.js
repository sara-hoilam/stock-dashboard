/**
 * Microsoft Clarity — bootstrapped from @microsoft/clarity (npm).
 *
 * Loaded as a module on every page after config.js. The project ID is public
 * (it ships in the browser tag URL); set it on ALPHATICKER_CONFIG.
 */
import Clarity from "./vendor/clarity/index.js";

const CFG = window.ALPHATICKER_CONFIG || window.LEDGER_CONFIG || {};
const projectId = (CFG.clarityProjectId || "").trim();

if (projectId) {
  Clarity.init(projectId);
  // Expose the same API the npm package documents, so nav.js can identify
  // signed-in visitors without a second import.
  window.TAClarity = Clarity;

  // The cookie banner in analytics.js speaks for both tags, so honour the same
  // answer here rather than storing regardless. Declared straight after init
  // because this module is deferred and the choice was made long before it
  // ran; analytics.js reapplies it on every later change.
  let consent = null;
  try { consent = localStorage.getItem("alphaticker-consent"); } catch {}
  Clarity.consentV2({
    ad_Storage: "denied",
    analytics_Storage: consent === "granted" ? "granted" : "denied",
  });
}
