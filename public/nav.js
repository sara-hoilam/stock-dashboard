/* ===========================================================================
   Ticker Alpha — shared top navigation.

   One script, injected into every page, so the bar cannot drift between them.
   It renders: a stats strip (the market at a glance, the way CoinMarketCap
   opens with global crypto stats), then the bar itself — brand, sections,
   ticker search, and sign-in.

   The brand always returns to Markets Today.
=========================================================================== */
(function () {
  "use strict";

  const CFG = window.ALPHATICKER_CONFIG || window.LEDGER_CONFIG || {};
  const HOSTED = !!(CFG.supabaseUrl && CFG.supabaseAnonKey);
  const esc = s => String(s ?? "").replace(/[&<>"]/g,
    c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  async function rpc(fn, args) {
    if (!HOSTED) throw new Error("no data source");
    const r = await fetch(`${CFG.supabaseUrl}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: { apikey: CFG.supabaseAnonKey, "Content-Type": "application/json" },
      body: JSON.stringify(args || {}),
    });
    if (!r.ok) throw new Error(`${fn} ${r.status}`);
    return r.json();
  }

  const page = (location.pathname.split("/").pop() || "index.html").toLowerCase();
  const here = p => page === p || (p === "index.html" && page === "");

  document.body.insertAdjacentHTML("afterbegin", `
    <div class="nav-strip" id="nav-strip">
      <div class="nav-tape" id="nav-tape"></div>
    </div>
    <nav class="nav"><div class="nav-in">
      <a class="nav-brand" href="index.html" aria-label="Ticker Alpha home">
        <span class="nav-mark">TA</span><b>Ticker&nbsp;Alpha</b>
      </a>

      <div class="nav-links">
        <a href="index.html"   class="${here("index.html") ? "on" : ""}">Markets</a>
        <a href="news.html"    class="${here("news.html") ? "on" : ""}">News</a>
        <a href="company.html" class="${here("company.html") ? "on" : ""}">Financials</a>
      </div>

      <div class="nav-search">
        <svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="9" cy="9" r="6"
          fill="none" stroke="currentColor" stroke-width="2"/><path d="M13.5 13.5 18 18"
          stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>
        <input type="text" id="nav-q" placeholder="Search a ticker or company"
               autocomplete="off" role="combobox" aria-expanded="false" aria-controls="nav-ac">
        <kbd>/</kbd>
        <div class="nav-ac" id="nav-ac" role="listbox"></div>
      </div>

      <div class="nav-right">
        <button class="nav-theme" id="nav-theme" aria-label="Switch colour theme"></button>
        <div id="nav-auth"></div>
      </div>
    </div></nav>
    <div class="nav-onetap" id="nav-onetap" hidden></div>
  `);

  // Publish the bar's height so a page's own sticky elements can sit below it
  // instead of underneath it.
  const bar = document.querySelector("nav.nav");
  const measure = () =>
    document.documentElement.style.setProperty("--nav-h", bar.offsetHeight + "px");
  measure();
  addEventListener("resize", measure);

  /* ---- theme ------------------------------------------------------------ */
  const themeBtn = document.getElementById("nav-theme");
  const ICON = { dark: "☾", light: "☀" };
  function setTheme(t) {
    document.documentElement.setAttribute("data-theme", t);
    themeBtn.textContent = t === "dark" ? ICON.light : ICON.dark;
    themeBtn.title = t === "dark" ? "Switch to light" : "Switch to dark";
    try { localStorage.setItem("alphaticker-theme", t); } catch {}
    window.dispatchEvent(new CustomEvent("themechange", { detail: t }));
  }
  themeBtn.onclick = () =>
    setTheme(document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark");
  let t0 = null;
  try { t0 = localStorage.getItem("alphaticker-theme") || localStorage.getItem("ledger-theme"); } catch {}
  setTheme(t0 || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"));
  window.setTheme = setTheme;

  /* ---- ticker tape ------------------------------------------------------ */
  // A marquee of index ETFs and large caps, each one a link to its page.
  //
  // The animation moves one copy of the list the width of one copy, with a
  // second copy behind it, so the seam never shows and the loop needs no
  // JavaScript per frame. Duration scales with content so a longer tape does
  // not scroll faster.
  const pct = v => v === null || v === undefined ? "—"
    : `${v >= 0 ? "+" : ""}${v.toFixed(2)}%`;
  const dir = v => (v >= 0 ? "up" : "down");
  const price = v => v === null || v === undefined ? ""
    : v >= 1000 ? v.toLocaleString(undefined, { maximumFractionDigits: 0 })
                : v.toFixed(2);

  async function tape() {
    const host = document.getElementById("nav-tape");
    if (!HOSTED) return;
    let rows;
    try {
      rows = await rpc("get_ticker_tape", { p_limit: 180 });
    } catch {
      // Before 0009 is applied, fall back to the watchlist so the strip is
      // still a tape rather than an empty bar.
      try { rows = await rpc("get_market_summary", { p_view: "market_cap", p_limit: 50 }); }
      catch { return; }
    }
    if (!rows || !rows.length) return;

    const one = rows.map(r =>
      `<a class="tape-i" href="company.html?t=${encodeURIComponent(r.symbol)}"` +
      ` title="${esc(r.name || r.symbol)}">` +
      `<span class="tape-s">${esc(r.symbol)}</span>` +
      `<span class="tape-p">${price(r.price)}</span>` +
      `<span class="${dir(r.changePct)}">${pct(r.changePct)}</span></a>`).join("");

    host.innerHTML =
      `<div class="tape-run" aria-label="Live prices">${one}</div>` +
      `<div class="tape-run" aria-hidden="true">${one}</div>`;

    // ~55px a second reads comfortably without being distracting.
    const w = host.firstElementChild.scrollWidth;
    host.style.setProperty("--tape-w", w + "px");
    host.style.setProperty("--tape-t", Math.max(30, w / 55) + "s");
  }
  tape();

  /* ---- ticker search ---------------------------------------------------- */
  const q = document.getElementById("nav-q"), ac = document.getElementById("nav-ac");
  let items = [], idx = -1, timer = null;

  const close = () => { ac.classList.remove("open"); q.setAttribute("aria-expanded", "false"); idx = -1; };
  const open = t => { location.href = `company.html?t=${encodeURIComponent(t)}`; };

  q.addEventListener("input", () => {
    clearTimeout(timer);
    const term = q.value.trim();
    if (!term) return close();
    timer = setTimeout(async () => {
      try {
        items = (await rpc("search_companies", { q: term })) || [];
        idx = -1;
        if (!items.length) return close();
        ac.innerHTML = items.map((x, i) =>
          `<div role="option" data-i="${i}" aria-selected="false">` +
          `<b>${esc(x.ticker)}</b><span>${esc(x.name)}</span></div>`).join("");
        ac.classList.add("open");
        q.setAttribute("aria-expanded", "true");
      } catch { close(); }
    }, 130);
  });
  ac.addEventListener("mousedown", e => {
    const d = e.target.closest("[data-i]");
    if (d) { e.preventDefault(); open(items[+d.dataset.i].ticker); }
  });
  q.addEventListener("keydown", e => {
    if (!ac.classList.contains("open")) {
      if (e.key === "Enter" && q.value.trim()) open(q.value.trim().toUpperCase());
      return;
    }
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      idx = (idx + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length;
      [...ac.children].forEach((c, i) => c.setAttribute("aria-selected", i === idx));
    } else if (e.key === "Enter") {
      e.preventDefault(); open((idx >= 0 ? items[idx] : items[0]).ticker);
    } else if (e.key === "Escape") close();
  });
  q.addEventListener("blur", () => setTimeout(close, 120));
  // "/" focuses search, the way every other market site behaves.
  addEventListener("keydown", e => {
    if (e.key === "/" && !/^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName)) {
      e.preventDefault(); q.focus();
    }
  });

  /* ---- auth ------------------------------------------------------------- */
  // Supabase Auth over its REST endpoints -- no SDK, same as everything else
  // here. Google sign-in only appears once a client id is configured; without
  // one the button would open a Google page that immediately errors.
  const auth = document.getElementById("nav-auth");
  const TOKEN_KEY = "alphaticker-session";

  const session = () => {
    try { return JSON.parse(localStorage.getItem(TOKEN_KEY) || "null"); } catch { return null; }
  };
  const saveSession = s => {
    try { s ? localStorage.setItem(TOKEN_KEY, JSON.stringify(s))
            : localStorage.removeItem(TOKEN_KEY); } catch {}
  };

  function renderAuth() {
    const s = session();
    if (s && s.user) {
      const name = s.user.name || s.user.email || "Account";
      const pic = s.user.picture;
      auth.innerHTML =
        `<button class="nav-user" id="nav-user" title="${esc(s.user.email || "")}">
           ${pic ? `<img src="${esc(pic)}" alt="">` : `<span class="nav-avatar">${esc(name[0].toUpperCase())}</span>`}
           <span class="nav-uname">${esc(name.split(" ")[0])}</span>
         </button>
         <button class="nav-signout" id="nav-signout">Sign out</button>`;
      document.getElementById("nav-signout").onclick = () => { saveSession(null); renderAuth(); };
    } else {
      auth.innerHTML = `<button class="nav-login" id="nav-login">Log in</button>`;
      document.getElementById("nav-login").onclick = signIn;
    }
  }

  function signIn() {
    if (!HOSTED) return alert("Sign-in needs the site configuration (config.js).");
    if (!CFG.googleClientId) {
      alert("Google sign-in is not configured yet.\n\n" +
            "Add googleClientId to config.js and enable Google in Supabase " +
            "Authentication → Providers.");
      return;
    }
    const redirect = location.origin + location.pathname;
    location.href = `${CFG.supabaseUrl}/auth/v1/authorize` +
      `?provider=google&redirect_to=${encodeURIComponent(redirect)}`;
  }

  // Supabase returns the session in the URL fragment after the round trip.
  (function captureRedirect() {
    if (!location.hash.includes("access_token")) return;
    const p = new URLSearchParams(location.hash.slice(1));
    const tok = p.get("access_token");
    if (!tok) return;
    let user = {};
    try {
      const body = JSON.parse(atob(tok.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
      user = { email: body.email, name: (body.user_metadata || {}).full_name,
               picture: (body.user_metadata || {}).avatar_url };
    } catch {}
    saveSession({ access_token: tok, user });
    history.replaceState(null, "", location.pathname + location.search);
  })();

  renderAuth();

  /* ---- Google One Tap --------------------------------------------------- */
  // The prompt in the top-right corner. Requires a client id; silently absent
  // without one rather than showing a control that cannot work.
  if (CFG.googleClientId && !session()) {
    const s = document.createElement("script");
    s.src = "https://accounts.google.com/gsi/client";
    s.async = true;
    s.onload = () => {
      if (!window.google || !google.accounts || !google.accounts.id) return;
      google.accounts.id.initialize({
        client_id: CFG.googleClientId,
        callback: async res => {
          // Hand Google's credential to Supabase, which verifies it and
          // returns a session of its own.
          try {
            const r = await fetch(
              `${CFG.supabaseUrl}/auth/v1/token?grant_type=id_token`, {
                method: "POST",
                headers: { apikey: CFG.supabaseAnonKey, "Content-Type": "application/json" },
                body: JSON.stringify({ provider: "google", id_token: res.credential }),
              });
            const d = await r.json();
            if (d.access_token) {
              saveSession({ access_token: d.access_token, user: {
                email: (d.user || {}).email,
                name: ((d.user || {}).user_metadata || {}).full_name,
                picture: ((d.user || {}).user_metadata || {}).avatar_url } });
              renderAuth();
            }
          } catch {}
        },
        auto_select: false,
        cancel_on_tap_outside: true,
      });
      google.accounts.id.prompt();
    };
    document.head.appendChild(s);
  }
})();
