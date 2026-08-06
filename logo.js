/* Ticker Alpha — cached company logos (Logo.dev via Supabase).
 *
 * The worker downloads Logo.dev images for S&P 500 + top crypto and stores
 * them in ledger.symbol_logo. Pages call TickerLogos.hydrate(symbols, root)
 * after rendering initials avatars marked with data-logo="AAPL". When a
 * cached data URL exists, the initials are covered by the logo image;
 * otherwise initials stay as the fallback.
 */
(function () {
  "use strict";

  if (window.TickerLogos) return;

  var cache = Object.create(null);

  function cfg() {
    return window.ALPHATICKER_CONFIG || window.LEDGER_CONFIG || {};
  }

  function injectCss() {
    if (document.getElementById("ticker-logos-css")) return;
    var s = document.createElement("style");
    s.id = "ticker-logos-css";
    s.textContent = [
      ".dot.has-logo,.av.has-logo,[data-logo].has-logo{",
      "  background:#fff!important;color:transparent!important;",
      "  overflow:hidden;position:relative}",
      ".dot img.logo-img,.av img.logo-img,[data-logo] img.logo-img{",
      "  position:absolute;inset:0;width:100%;height:100%;",
      "  object-fit:contain;padding:15%;box-sizing:border-box;",
      "  border-radius:inherit;display:block}",
    ].join("");
    document.head.appendChild(s);
  }

  async function fetchLogos(symbols) {
    var C = cfg();
    if (!C.supabaseUrl || !C.supabaseAnonKey) return cache;

    var uniq = [];
    var seen = Object.create(null);
    (symbols || []).forEach(function (raw) {
      var s = String(raw || "").toUpperCase().trim();
      if (!s || seen[s]) return;
      seen[s] = 1;
      if (cache[s] && cache[s]._resolved) return;
      uniq.push(s);
    });
    if (!uniq.length) return cache;

    var tok = window.TA && window.TA.token && window.TA.token();
    var headers = {
      apikey: C.supabaseAnonKey,
      "Content-Type": "application/json",
    };
    if (tok) headers.Authorization = "Bearer " + tok;

    var r = await fetch(C.supabaseUrl + "/rest/v1/rpc/get_symbol_logos", {
      method: "POST",
      headers: headers,
      body: JSON.stringify({ p_symbols: uniq }),
    });
    if (!r.ok) return cache;

    var rows = await r.json();
    (Array.isArray(rows) ? rows : []).forEach(function (row) {
      if (!row || !row.symbol) return;
      cache[row.symbol] = {
        symbol: row.symbol,
        status: row.status,
        dataUrl: row.dataUrl || null,
        _resolved: true,
      };
    });
    uniq.forEach(function (s) {
      if (!cache[s]) {
        cache[s] = { symbol: s, status: "unknown", dataUrl: null, _resolved: true };
      } else {
        cache[s]._resolved = true;
      }
    });
    return cache;
  }

  function dataUrl(symbol) {
    var row = cache[String(symbol || "").toUpperCase().trim()];
    return row && row.dataUrl ? row.dataUrl : null;
  }

  function apply(root) {
    injectCss();
    var scope = root || document;
    scope.querySelectorAll("[data-logo]").forEach(function (el) {
      var sym = el.getAttribute("data-logo");
      var url = dataUrl(sym);
      if (!url) return;
      var existing = el.querySelector("img.logo-img");
      if (existing) {
        if (existing.src !== url) existing.src = url;
        el.classList.add("has-logo");
        return;
      }
      var img = document.createElement("img");
      img.className = "logo-img";
      img.alt = "";
      img.decoding = "async";
      img.loading = "lazy";
      img.src = url;
      img.onerror = function () {
        el.classList.remove("has-logo");
        if (img.parentNode) img.remove();
      };
      el.classList.add("has-logo");
      el.appendChild(img);
    });
  }

  async function hydrate(symbols, root) {
    try {
      await fetchLogos(symbols);
      apply(root);
    } catch (_) {
      /* keep initials */
    }
  }

  window.TickerLogos = {
    load: fetchLogos,
    apply: apply,
    hydrate: hydrate,
    dataUrl: dataUrl,
  };
})();
