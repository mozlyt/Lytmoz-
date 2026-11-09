// Install as an app: Android/desktop get the browser's install prompt; iPhone gets simple steps.
(function () {
  if ('serviceWorker' in navigator) window.addEventListener('load', function () { navigator.serviceWorker.register('/sw.js').catch(function () {}); });
  var btns = Array.prototype.slice.call(document.querySelectorAll('[data-install]')); if (!btns.length) return;
  var show = function (on) { btns.forEach(function (b) { b.hidden = !on; }); };
  var standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  if (standalone) return;
  var ios = /iphone|ipad|ipod/i.test(navigator.userAgent) && !window.MSStream, deferred = null;
  window.addEventListener('beforeinstallprompt', function (e) { e.preventDefault(); deferred = e; show(true); });
  window.addEventListener('appinstalled', function () { show(false); deferred = null; });
  if (ios) show(true);
  btns.forEach(function (btn) { btn.addEventListener('click', function () {
    if (deferred) { deferred.prompt(); deferred.userChoice.finally(function () { deferred = null; show(false); }); return; }
    var h = document.getElementById('ios-hint'); if (h) h.hidden = false;
  }); });
  var c = document.getElementById('ios-hint-close'); if (c) c.addEventListener('click', function () { document.getElementById('ios-hint').hidden = true; });
})();
