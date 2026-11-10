/* Wording and contact details managed in Lytmoz HQ > Settings.
   The text written in each page is the fallback; whatever HQ has published replaces it.
   Add ?preview=1 to any page to see the unpublished draft (signed-in HQ admins only). */
(function () {
  var cfg = window.LYTMOZ; if (!cfg || !window.fetch) return;
  var preview = /[?&]preview=1(&|$)/.test(location.search);
  function apply(c) {
    if (!c || typeof c !== 'object') return;
    var t = c.text || {};
    document.querySelectorAll('[data-lz]').forEach(function (el) { var v = t[el.getAttribute('data-lz')]; if (typeof v === 'string' && v.trim() && el.textContent !== v) el.textContent = v; });
    // Contact details
    var wa = t['org.whatsapp'];
    if (typeof wa === 'string' && /^\d{9,15}$/.test(wa)) {
      cfg.whatsapp = wa;
      document.querySelectorAll('a[href*="wa.me/"]').forEach(function (a) { a.href = a.href.replace(/wa\.me\/\d+/, 'wa.me/' + wa); if (/^WhatsApp \+[\d ]+$/.test(a.textContent.trim())) a.textContent = 'WhatsApp +' + wa; });
    }
    [['facebook', 'facebook.com'], ['instagram', 'instagram.com'], ['tiktok', 'tiktok.com'], ['linkedin', 'linkedin.com']].forEach(function (s) {
      var u = t['org.' + s[0]]; if (typeof u !== 'string' || !/^https:\/\/[^\s"'<>]+$/.test(u)) return;
      document.querySelectorAll('a[href*="' + s[1] + '/"]').forEach(function (a) { a.href = u; });
    });
    var box = document.querySelector('[data-lz-list="specialists"]');
    if (box && Array.isArray(c.specialists) && c.specialists.length && box.firstElementChild) {
      var chip = box.firstElementChild.cloneNode(false); box.textContent = '';
      c.specialists.forEach(function (x) { var n = chip.cloneNode(false); n.textContent = x; box.appendChild(n); });
    }
    var old = document.querySelectorAll('[data-lz-faq]');
    if (old.length && Array.isArray(c.faq) && c.faq.length) {
      var tpl = old[0], frag = document.createDocumentFragment();
      c.faq.forEach(function (f) { var n = tpl.cloneNode(true); n.removeAttribute('open'); n.querySelector('summary').textContent = f.q; n.querySelector('p').textContent = f.a; frag.appendChild(n); });
      tpl.parentNode.insertBefore(frag, tpl); old.forEach(function (o) { o.remove(); });
      var ld = document.querySelector('script[type="application/ld+json"]');
      try {
        var d = JSON.parse(ld.textContent), page = (d['@graph'] || []).filter(function (x) { return x['@type'] === 'FAQPage'; })[0];
        if (page) { page.mainEntity = c.faq.map(function (f) { return { '@type': 'Question', name: f.q, acceptedAnswer: { '@type': 'Answer', text: f.a } }; }); ld.textContent = JSON.stringify(d); }
      } catch (e) {}
    }
  }
  var KEY = 'lz-site-v1';
  if (!preview) { try { apply(JSON.parse(localStorage.getItem(KEY) || 'null')); } catch (e) {} }
  var token = cfg.supabaseKey;
  if (preview) {
    try { var sess = JSON.parse(localStorage.getItem('lytmoz-auth') || 'null'); token = sess && sess.access_token; } catch (e) { token = null; }
    var bar = document.createElement('div');
    bar.setAttribute('role', 'status');
    bar.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:99;background:#C98A5E;color:#0E0D0C;font:600 14px/1.4 Manrope,system-ui,sans-serif;padding:12px 16px;text-align:center';
    bar.textContent = token ? 'Preview of your unpublished draft. Visitors do not see this until you publish in HQ.' : 'Sign in to Lytmoz HQ in this browser to preview your draft.';
    document.body.appendChild(bar);
    if (!token) return;
  }
  fetch(cfg.supabaseUrl + '/rest/v1/rpc/' + (preview ? 'site_draft' : 'public_site'), { method: 'POST', headers: { apikey: cfg.supabaseKey, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }, body: '{}' })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (c) { if (!c) return; apply(c); if (!preview) { try { localStorage.setItem(KEY, JSON.stringify(c)); } catch (e) {} } })
    .catch(function () {});
})();
