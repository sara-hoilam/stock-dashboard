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
}
