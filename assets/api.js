// Shared helpers for the HQ dashboard and client portal (Supabase).
(function () {
  var cfg = window.LYTMOZ || {};
  var sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey, {
    auth: { persistSession: true, autoRefreshToken: true, storageKey: 'lytmoz-auth' }
  });

  function check(res) {
    if (res.error) {
      var m = res.error.message || 'Something went wrong';
      if (/Invalid login/i.test(m)) m = 'Wrong email or password';
      throw new Error(m);
    }
    return res.data;
  }
  function fn(body) {
    return sb.auth.getSession().then(function (s) {
      var h = { 'Content-Type': 'application/json', apikey: cfg.supabaseKey };
      if (s.data.session) h.Authorization = 'Bearer ' + s.data.session.access_token;
      return fetch(cfg.supabaseUrl + '/functions/v1/hq-users', { method: 'POST', headers: h, body: JSON.stringify(body) })
        .then(function (r) { return r.json().then(function (d) { if (!r.ok) throw new Error(d.error || 'Something went wrong'); return d; }); });
    });
  }
  function me() {
    return sb.auth.getUser().then(function (r) {
      if (!r.data.user) return null;
      return sb.from('profiles').select('*').eq('id', r.data.user.id).single().then(function (p) { return p.data || null; });
    });
  }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function money(cents, cur) {
    var sym = { USD: '$', GHS: 'GH₵', NGN: '₦' }[cur || 'USD'] || '';
    return sym + (cents / 100).toLocaleString('en-US', { maximumFractionDigits: 2 });
  }
  function when(iso) {
    if (!iso) return '';
    var d = new Date(iso), days = Math.floor((Date.now() - d) / 864e5);
    if (days <= 0) return 'Today';
    if (days === 1) return 'Yesterday';
    if (days < 7) return days + ' days ago';
    return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
  }
  function setMsg(el, text, kind) { el.textContent = text || ''; el.className = 'msg' + (kind ? ' ' + kind : ''); }

  // Show / hide button on every password field
  function addPasswordToggles() {
    document.querySelectorAll('input[type="password"]').forEach(function (inp) {
      if (inp.dataset.toggle) return; inp.dataset.toggle = '1';
      var wrap = document.createElement('span'); wrap.className = 'pw-wrap';
      inp.parentNode.insertBefore(wrap, inp); wrap.appendChild(inp);
      var b = document.createElement('button'); b.type = 'button'; b.className = 'pw-eye'; b.textContent = 'Show';
      b.setAttribute('aria-label', 'Show password'); b.setAttribute('aria-pressed', 'false');
      b.addEventListener('click', function () {
        var show = inp.type === 'password'; inp.type = show ? 'text' : 'password';
        b.textContent = show ? 'Hide' : 'Show'; b.setAttribute('aria-label', show ? 'Hide password' : 'Show password'); b.setAttribute('aria-pressed', show ? 'true' : 'false');
        inp.focus();
      });
      wrap.appendChild(b);
      if (inp.form) inp.form.addEventListener('submit', function () { inp.type = 'password'; b.textContent = 'Show'; b.setAttribute('aria-pressed', 'false'); });
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', addPasswordToggles); else addPasswordToggles();

  window.LZ = { cfg: cfg, sb: sb, check: check, fn: fn, me: me, esc: esc, money: money, when: when, setMsg: setMsg,
    stages: ['Audit', 'Proposal and deposit', 'Build', 'Launch', 'Monthly care'] };
})();
