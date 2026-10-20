// Shared helpers for the admin dashboard and client portal.
(function () {
  var cfg = window.LYTMOZ || {};
  var KEY = 'lytmoz_token';
  function getToken() { try { return localStorage.getItem(KEY) || ''; } catch (e) { return ''; } }
  function setToken(t) { try { t ? localStorage.setItem(KEY, t) : localStorage.removeItem(KEY); } catch (e) {} }

  function api(method, path, body) {
    var h = { 'Content-Type': 'application/json' };
    var t = getToken();
    if (t) h.Authorization = 'Bearer ' + t;
    return fetch(cfg.api + path, { method: method, headers: h, body: body ? JSON.stringify(body) : undefined })
      .then(function (r) {
        return r.json().catch(function () { return {}; }).then(function (d) {
          if (r.status === 401 && path !== '/api/login') { setToken(''); }
          if (!r.ok) { var e = new Error(d.error || 'Something went wrong'); e.status = r.status; throw e; }
          return d;
        });
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
    var d = new Date(iso.replace(' ', 'T') + (iso.indexOf('Z') < 0 && iso.indexOf('+') < 0 ? 'Z' : ''));
    var days = Math.floor((Date.now() - d) / 864e5);
    if (days <= 0) return 'Today';
    if (days === 1) return 'Yesterday';
    if (days < 7) return days + ' days ago';
    return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
  }
  function setMsg(el, text, kind) { el.textContent = text || ''; el.className = 'msg' + (kind ? ' ' + kind : ''); }

  window.LZ = { cfg: cfg, api: api, getToken: getToken, setToken: setToken, esc: esc, money: money, when: when, setMsg: setMsg,
    stages: ['Audit', 'Proposal and deposit', 'Build', 'Launch', 'Monthly care'] };
})();
