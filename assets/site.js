(function () {
  // Menu
  var btn = document.getElementById('lz-menu-btn');
  var menu = document.getElementById('lz-menu');
  var label = document.getElementById('lz-menu-label');
  function setMenu(open) {
    menu.hidden = !open;
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    label.textContent = open ? 'CLOSE' : 'MENU';
  }
  btn.addEventListener('click', function () { setMenu(menu.hidden); });
  menu.querySelectorAll('[data-close]').forEach(function (a) {
    a.addEventListener('click', function () { setMenu(false); });
  });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && !menu.hidden) { setMenu(false); btn.focus(); }
  });
  document.addEventListener('click', function (e) {
    if (!menu.hidden && !menu.contains(e.target) && !btn.contains(e.target)) setMenu(false);
  });

  // Earnings calculator
  var state = { d: 200, f: 10 };
  var fmt = function (n) { return '$' + n.toLocaleString('en-US'); };
  function render() {
    var m = state.d * state.f;
    document.getElementById('lz-monthly').textContent = fmt(m);
    document.getElementById('lz-yearly').textContent = fmt(m * 12);
  }
  document.querySelectorAll('.lz-opt').forEach(function (b) {
    b.addEventListener('click', function () {
      var g = b.getAttribute('data-group');
      state[g] = Number(b.getAttribute('data-val'));
      document.querySelectorAll('.lz-opt[data-group="' + g + '"]').forEach(function (o) {
        o.setAttribute('aria-pressed', o === b ? 'true' : 'false');
      });
      render();
    });
  });
  render();

  // Consultation form
  var cfg = window.LYTMOZ || {};
  var form = document.getElementById('lz-form');
  var msg = document.getElementById('lz-form-msg');
  function waLink(d) {
    var t = 'Hello Lytmoz, I’d like a free consultation.\n\nName: ' + d.name +
      (d.website ? '\nWebsite: ' + d.website : '') + '\nWhatsApp: ' + d.whatsapp + '\n\n' + d.message;
    return 'https://wa.me/' + (cfg.whatsapp || '233538729743') + '?text=' + encodeURIComponent(t);
  }
  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var fd = new FormData(form);
    var d = {};
    fd.forEach(function (v, k) { d[k] = String(v).trim(); });
    if (!d.name || !d.whatsapp || !d.message) {
      msg.style.color = '#9A3412';
      msg.textContent = 'Please add your name, WhatsApp number and a few words about your idea or business.';
      return;
    }
    var submit = form.querySelector('button[type="submit"]');
    submit.disabled = true;
    msg.style.color = '#4A423A';
    msg.textContent = 'Sending…';
    if (!cfg.supabaseUrl) {
      window.open(waLink(d), '_blank', 'noopener');
      msg.textContent = 'WhatsApp opened with your request ready to send.';
      submit.disabled = false;
      return;
    }
    var lead = { name: d.name.slice(0, 120), website: (d.website || '').slice(0, 500) || null, whatsapp: d.whatsapp.slice(0, 40), message: d.message.slice(0, 8000) };
    // 1) Save to Lytmoz HQ
    var save = fetch(cfg.supabaseUrl + '/rest/v1/leads', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: cfg.supabaseKey, Prefer: 'return=minimal' },
      body: JSON.stringify(lead)
    }).then(function (r) {
      if (!r.ok) return r.json().catch(function () { return {}; }).then(function (e) { throw new Error(e.message || ('HTTP ' + r.status)); });
      return true;
    });
    // 2) Email a copy to the inbox
    var mail = cfg.email ? fetch('https://formsubmit.co/ajax/' + cfg.email, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ _subject: 'New consultation request: ' + lead.name, _template: 'table', _captcha: 'false',
        Name: lead.name, WhatsApp: lead.whatsapp, Website: lead.website || '-', Message: lead.message })
    }).then(function (r) { return r.ok; }).catch(function () { return false; }) : Promise.resolve(false);
    Promise.allSettled([save, mail]).then(function (res) {
      var saved = res[0].status === 'fulfilled', mailed = res[1].status === 'fulfilled' && res[1].value === true;
      if (saved || mailed) {
        form.reset();
        msg.style.color = '#166534';
        msg.textContent = 'Thank you. Your request has been received. We will reply on WhatsApp within 2 working days.';
        return;
      }
      var m = res[0].reason ? res[0].reason.message : '';
      msg.style.color = '#9A3412';
      var hint = /whatsapp/i.test(m) ? 'Please check your WhatsApp number (digits only, e.g. 0241234567). ' :
                 /Too many/.test(m) ? 'You have sent several requests today. ' :
                 /message/i.test(m) ? 'Please check your message and try again. ' : 'We could not send your request. ';
      msg.innerHTML = hint + '<a href="' + waLink(d) + '" target="_blank" rel="noopener" style="color:#8A4E28">Send it on WhatsApp instead</a>.';
      submit.disabled = false;
    }).finally(function () { submit.disabled = false; });
  });
})();
