/* Lytmoz Messages: one-to-one chat used by Admin HQ and the client portal.
   LZChat.mount(element, { me: profile, isAdmin: bool, staff: bool, onUnread: fn(n), onVisibility: fn() }) */
(function () {
  var sb = LZ.sb, esc = LZ.esc, check = LZ.check;
  function initials(n) { return String(n || '?').trim().split(/\s+/).slice(0, 2).map(function (w) { return w.charAt(0).toUpperCase(); }).join(''); }
  function hm(d) { return new Date(d).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }); }
  function dayLabel(d) {
    var a = new Date(d), n = new Date(), diff = Math.round((new Date(n.getFullYear(), n.getMonth(), n.getDate()) - new Date(a.getFullYear(), a.getMonth(), a.getDate())) / 864e5);
    return diff === 0 ? 'Today' : diff === 1 ? 'Yesterday' : a.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });
  }
  function listTime(d) { var l = dayLabel(d); return l === 'Today' ? hm(d) : l === 'Yesterday' ? 'Yesterday' : new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }); }

  function mount(root, opt) {
    var me = opt.me.id, st = { list: [], people: [], cur: null, msgs: [], mode: 'list', q: '', visible: opt.me.chat_visible !== false, busy: false };
    root.innerHTML = '<div class="chat">' +
      '<aside class="chat-side"><div class="chat-side-h"><strong id="cs-title">Chats</strong><button type="button" class="icon-btn" data-c="new" aria-label="Start a new chat"><svg class="ic" aria-hidden="true"><use href="#i-plus"/></svg></button></div>' +
      '<div class="chat-note" data-c="note" hidden></div>' +
      '<label class="chat-search"><span class="sr">Search chats</span><input type="search" data-c="q" placeholder="Search" autocomplete="off"></label>' +
      '<div class="chat-list" data-c="list" role="list"></div></aside>' +
      '<section class="chat-main" data-c="main"><div class="chat-empty"><svg class="ic" aria-hidden="true"><use href="#i-chat"/></svg><p>Choose a chat, or tap + to start one.</p></div></section></div>';
    var $ = function (k) { return root.querySelector('[data-c="' + k + '"]'); }, box = root.querySelector('.chat');

    function note() {
      var n = $('note');
      if (opt.staff) { n.hidden = false; n.innerHTML = 'Private: only you and the other person can read a chat. If something is wrong, open the chat and use Report.'; return; }
      if (opt.isAdmin && opt.only === 'staff') { n.hidden = false; n.innerHTML = 'Private chats between you and your staff. Chats between staff members stay private to them unless one of them reports a conversation.'; return; }
      if (opt.isAdmin) { n.hidden = true; return; }
      n.hidden = st.visible;
      n.innerHTML = 'You are hidden. Other clients cannot see you or start a chat with you. <button type="button" class="linkish" data-c="vis">Show me in Messages</button>';
    }
    function totalUnread() { return st.list.reduce(function (a, t) { return a + (+t.unread || 0); }, 0); }
    function refreshList() {
      return sb.rpc('chat_list').then(check).then(function (rows) {
        st.list = keep(rows || []); if (opt.onUnread) opt.onUnread(totalUnread());
        if (st.mode === 'list') renderSide();
        var c = st.list.filter(function (t) { return t.id === st.cur; })[0]; if (c) renderHead(c);
      }).catch(function () {});
    }
    function keep(rows) { return opt.only === 'staff' ? rows.filter(function (r) { return r.staff; }) : opt.only === 'clients' ? rows.filter(function (r) { return !r.staff; }) : rows; }
    function loadPeople() { return sb.rpc('chat_people').then(check).then(function (rows) { st.people = keep(rows || []); if (st.mode === 'people') renderSide(); }); }
    function avatar(name, online, lytmoz) { return '<span class="chat-av' + (lytmoz ? ' lz' : '') + '">' + esc(initials(name)) + (online ? '<i class="on" aria-hidden="true"></i>' : '') + '</span>'; }
    function renderSide() {
      $('q').value = st.q;
      var q = st.q.toLowerCase(), match = function (x) { return !q || (x.name + ' ' + (x.business || '')).toLowerCase().indexOf(q) >= 0; };
      root.querySelector('#cs-title') && (root.querySelector('#cs-title').textContent = st.mode === 'people' ? 'New chat' : 'Chats');
      if (st.mode === 'people') {
        var ppl = st.people.filter(match);
        $('list').innerHTML = '<button type="button" class="chat-row back" data-c="back"><svg class="ic" aria-hidden="true"><use href="#i-back"/></svg><span>Back to chats</span></button>' +
          (ppl.map(function (p) { return '<button type="button" class="chat-row" role="listitem" data-person="' + p.id + '">' + avatar(p.name, p.online, p.lytmoz) + '<span class="chat-b"><strong>' + esc(p.name) + '</strong><span>' + esc(p.online ? 'Online' : (p.business || (p.lytmoz ? 'Lytmoz team' : 'Client'))) + '</span></span></button>'; }).join('') ||
            '<p class="chat-none">' + (opt.staff ? 'Nobody to message right now.' : opt.only === 'staff' ? 'No staff to message yet.' : opt.isAdmin ? 'No clients to message yet.' : st.visible ? 'No other clients are visible right now. Lytmoz is always here.' : 'Only Lytmoz is shown while you are hidden.') + '</p>');
        return;
      }
      var rows = st.list.filter(match);
      $('list').innerHTML = rows.map(function (t) {
        return '<button type="button" class="chat-row' + (t.id === st.cur ? ' cur' : '') + '" role="listitem" data-thread="' + t.id + '">' + avatar(t.name, t.online, t.name === 'Lytmoz') +
          '<span class="chat-b"><span class="chat-top"><strong>' + esc(t.name) + '</strong><small>' + (t.last_text ? listTime(t.last_at) : '') + '</small></span>' +
          '<span class="chat-top"><span class="chat-last">' + (t.last_text ? (t.last_mine ? 'You: ' : '') + esc(t.last_text) : '<em>No messages yet</em>') + '</span>' + (+t.unread ? '<b class="chat-n">' + t.unread + '</b>' : '') + '</span></span></button>';
      }).join('') || '<p class="chat-none">' + (st.q ? 'No chats match.' : 'No chats yet. Tap + to start one.') + '</p>';
    }
    function renderHead(t) {
      var h = root.querySelector('.chat-head'); if (!h) return;
      h.querySelector('[data-c="hname"]').textContent = t.name;
      h.querySelector('[data-c="hsub"]').textContent = t.blocked ? 'Blocked' : t.online ? 'Online' : (t.business || '');
      h.querySelector('.chat-av').outerHTML = avatar(t.name, t.online, t.name === 'Lytmoz');
      var owner = t.name === 'Lytmoz' || t.business === 'Owner';
      var b = h.querySelector('[data-c="block"]'); if (b) { b.hidden = owner; b.textContent = t.blocked ? 'Unblock' : 'Block'; }
      var r = h.querySelector('[data-c="report"]'); if (r) { r.hidden = !opt.staff || owner; r.disabled = !!t.reported; r.textContent = t.reported ? 'Reported' : 'Report'; }
      var off = !!t.blocked || !!t.closed, f = root.querySelector('.chat-form'), m = root.querySelector('.chat-blocked');
      if (f) { f.hidden = off; m.hidden = !off; m.textContent = t.blocked ? 'You blocked this person. Unblock them to send messages.' : 'You cannot message this person right now. You can still read earlier messages.'; }
    }
    function bubbles() {
      var out = '', last = '';
      st.msgs.forEach(function (m) {
        var d = dayLabel(m.created_at); if (d !== last) { out += '<div class="chat-day"><span>' + d + '</span></div>'; last = d; }
        var mine = m.sender === me;
        out += '<div class="cb ' + (mine ? 'me' : 'them') + (m.pending ? ' pending' : '') + '">' + esc(m.text) + '<small>' + hm(m.created_at) + (mine ? ' <span class="tick' + (m.read_at ? ' read' : '') + '" aria-label="' + (m.pending ? 'Sending' : m.read_at ? 'Read' : 'Sent') + '">' + (m.pending ? '…' : m.read_at ? '✓✓' : '✓') + '</span>' : '') + '</small></div>';
      });
      return out || '<p class="chat-none" style="margin:auto">Say hello.</p>';
    }
    function renderMsgs(stick) {
      var s = root.querySelector('.chat-msgs'); if (!s) return;
      var atEnd = s.scrollHeight - s.scrollTop - s.clientHeight < 80;
      s.innerHTML = bubbles();
      if (stick || atEnd) s.scrollTop = s.scrollHeight;
    }
    function open(id) {
      st.cur = id; st.mode = 'list'; box.classList.add('has-cur');
      var t = st.list.filter(function (x) { return x.id === id; })[0] || { name: '', business: '' };
      $('main').innerHTML = '<div class="chat-head"><button type="button" class="icon-btn chat-backbtn" data-c="close" aria-label="Back to chats"><svg class="ic" aria-hidden="true"><use href="#i-back"/></svg></button>' + avatar(t.name, t.online) +
        '<div class="chat-who"><strong data-c="hname"></strong><span data-c="hsub"></span></div><button type="button" class="btn small ghost" data-c="report" hidden>Report</button><button type="button" class="btn small ghost" data-c="block" hidden>Block</button></div>' +
        '<div class="chat-msgs" aria-live="polite"><p class="chat-none" style="margin:auto">Loading…</p></div>' +
        '<p class="chat-blocked" hidden>You blocked this person. Unblock them to send messages.</p>' +
        '<form class="chat-form"><label class="sr" for="chat-in">Message</label><textarea id="chat-in" rows="1" maxlength="4000" placeholder="Type a message"></textarea><button class="btn chat-send" type="submit" aria-label="Send"><svg class="ic" aria-hidden="true"><use href="#i-send"/></svg></button></form>';
      renderHead(t); renderSide();
      sb.from('chat_messages').select('*').eq('thread_id', id).order('id', { ascending: true }).limit(500).then(check).then(function (rows) {
        if (st.cur !== id) return; st.msgs = rows; renderMsgs(true);
        return sb.rpc('chat_read', { t: id }).then(refreshList);
      }).catch(function (err) { root.querySelector('.chat-msgs').innerHTML = '<p class="msg err">' + esc(err.message) + '</p>'; });
      var inp = root.querySelector('#chat-in'); if (inp && window.matchMedia('(min-width:761px)').matches) inp.focus();
    }
    function send(text) {
      var id = st.cur, tmp = { id: 'tmp' + Date.now(), thread_id: id, sender: me, text: text, created_at: new Date().toISOString(), pending: true };
      st.msgs.push(tmp); renderMsgs(true);
      sb.from('chat_messages').insert({ thread_id: id, text: text }).select().single().then(check).then(function (row) {
        var i = st.msgs.indexOf(tmp); if (i >= 0) st.msgs[i] = row; renderMsgs(); refreshList();
      }).catch(function (err) { st.msgs = st.msgs.filter(function (m) { return m !== tmp; }); renderMsgs(); alert(err.message); });
    }
    function pullNew() {
      if (!st.cur) return;
      var real = st.msgs.filter(function (m) { return typeof m.id === 'number'; }), lastId = real.length ? real[real.length - 1].id : 0, id = st.cur;
      sb.from('chat_messages').select('*').eq('thread_id', id).gt('id', lastId).order('id', { ascending: true }).then(check).then(function (rows) {
        if (st.cur !== id) return;
        var fresh = rows.filter(function (r) { return !st.msgs.some(function (m) { return m.id === r.id; }); });
        if (fresh.length) { st.msgs = st.msgs.concat(fresh); renderMsgs(); if (fresh.some(function (r) { return r.sender !== me; })) sb.rpc('chat_read', { t: id }).then(refreshList); }
        // pick up read ticks on my messages
        return sb.from('chat_messages').select('id,read_at').eq('thread_id', id).eq('sender', me).not('read_at', 'is', null).gt('id', Math.max(0, lastId - 200)).then(check).then(function (r2) {
          var changed = false; r2.forEach(function (x) { st.msgs.forEach(function (m) { if (m.id === x.id && !m.read_at) { m.read_at = x.read_at; changed = true; } }); }); if (changed) renderMsgs();
        });
      }).catch(function () {});
    }

    root.addEventListener('click', function (e) {
      var t = e.target, x;
      if (t.closest('[data-c="new"]')) { st.mode = 'people'; st.q = ''; renderSide(); loadPeople(); return; }
      if (t.closest('[data-c="back"]')) { st.mode = 'list'; st.q = ''; renderSide(); return; }
      if (t.closest('[data-c="close"]')) { st.cur = null; box.classList.remove('has-cur'); $('main').innerHTML = '<div class="chat-empty"><svg class="ic" aria-hidden="true"><use href="#i-chat"/></svg><p>Choose a chat, or tap + to start one.</p></div>'; renderSide(); return; }
      if (t.closest('[data-c="vis"]')) { if (opt.onVisibility) opt.onVisibility(); return; }
      if ((x = t.closest('[data-thread]'))) { open(+x.dataset.thread); return; }
      if ((x = t.closest('[data-person]'))) {
        sb.rpc('chat_open', { other: x.dataset.person }).then(check).then(function (id) { st.q = ''; return refreshList().then(function () { open(id); }); }).catch(function (err) { alert(err.message); });
        return;
      }
      if (t.closest('[data-c="report"]')) {
        var rt = st.list.filter(function (y) { return y.id === st.cur; })[0]; if (!rt) return;
        var why = prompt('Report this conversation with ' + rt.name + ' to the owner?\n\nThe owner will then be able to read this whole conversation. Say briefly what is wrong:', '');
        if (why === null) return; if (why.trim().length < 3) return alert('Please say briefly what is wrong.');
        sb.rpc('chat_report', { t: rt.id, reason: why.trim() }).then(check).then(function () { alert('Reported. The owner can now read this conversation and will look into it.'); return refreshList(); }).catch(function (err) { alert(err.message); });
        return;
      }
      if (t.closest('[data-c="block"]')) {
        var th = st.list.filter(function (y) { return y.id === st.cur; })[0]; if (!th) return;
        if (th.blocked) sb.from('chat_blocks').delete().eq('blocker', me).eq('blocked', th.other).then(check).then(refreshList).catch(function (err) { alert(err.message); });
        else if (confirm('Block ' + th.name + '? Neither of you will be able to send messages, and they will no longer see you in Messages.')) sb.from('chat_blocks').insert({ blocker: me, blocked: th.other }).then(check).then(refreshList).catch(function (err) { alert(err.message); });
      }
    });
    root.addEventListener('input', function (e) {
      if (e.target.dataset.c === 'q') { st.q = e.target.value; renderSide(); }
      if (e.target.id === 'chat-in') { e.target.style.height = 'auto'; e.target.style.height = Math.min(140, e.target.scrollHeight) + 'px'; }
    });
    root.addEventListener('keydown', function (e) {
      if (e.target.id === 'chat-in' && e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); e.target.form.requestSubmit(); }
    });
    root.addEventListener('submit', function (e) {
      if (!e.target.classList.contains('chat-form')) return;
      e.preventDefault(); var inp = root.querySelector('#chat-in'), v = inp.value.trim(); if (!v || !st.cur) return;
      inp.value = ''; inp.style.height = 'auto'; send(v.slice(0, 4000));
    });

    // live updates, with a slower check in case the live link drops
    try {
      sb.channel('lz-chat-' + me + (opt.only || '')).on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'chat_messages' }, function (p) {
        var m = p.new; if (m.thread_id === st.cur && m.sender !== me) pullNew(); refreshList();
      }).subscribe();
    } catch (err) {}
    setInterval(function () { if (document.visibilityState !== 'visible') return; refreshList(); pullNew(); }, 8000);
    function seen() { if (document.visibilityState === 'visible') sb.rpc('chat_seen').then(function () {}, function () {}); }
    seen(); setInterval(seen, 60000); document.addEventListener('visibilitychange', seen);

    note(); refreshList();
    return {
      setVisible: function (v) { st.visible = v; note(); if (st.mode === 'people') loadPeople(); },
      refresh: refreshList, unread: totalUnread,
      openWith: function (person) { return sb.rpc('chat_open', { other: person }).then(check).then(function (id) { return refreshList().then(function () { open(id); }); }).catch(function (err) { alert(err.message); }); }
    };
  }
  window.LZChat = { mount: mount };
})();
