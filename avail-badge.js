/* Black Label portal — global availability badge (Brief 7).
   Self-contained: injects its own style and renders a small pill in the topbar
   (#availBadge) showing the logged-in agent's current Drop availability, linking
   to profile.html where they can change it. Effective-availability mirrors the DB:
   a timed pause that has already lapsed reads as Available. */
(function () {
  var URL = 'https://hqiyxeriugywlkbcuasu.supabase.co';
  var KEY = 'sb_publishable_9m66yQmAgJwgCRMoYcU5sA_3l_XlfXr';

  var css = ''
    + '.avail-badge{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:999px;'
    + 'font-size:12px;font-weight:700;letter-spacing:.2px;text-decoration:none;margin-right:12px;'
    + 'border:1px solid transparent;white-space:nowrap}'
    + '.avail-badge .avail-dot{width:8px;height:8px;border-radius:50%;flex:0 0 auto}'
    + '.avail-badge.avail-on{color:#7fb89a;background:rgba(127,184,154,0.14);border-color:rgba(127,184,154,0.40)}'
    + '.avail-badge.avail-on .avail-dot{background:#7fb89a;box-shadow:0 0 6px rgba(127,184,154,0.85)}'
    + '.avail-badge.avail-off{color:#d2a96a;background:rgba(210,169,106,0.14);border-color:rgba(210,169,106,0.45)}'
    + '.avail-badge.avail-off .avail-dot{background:#d2a96a}'
    + '@media (max-width:560px){.avail-badge{font-size:11px;padding:3px 8px;margin-right:8px}}';
  var st = document.createElement('style'); st.textContent = css; document.head.appendChild(st);

  function fmt(ts) { try { return new Date(ts).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }); } catch (e) { return ''; } }

  function paint(avail, until) {
    var el = document.getElementById('availBadge');
    if (!el) return;
    var lapsed = until && (new Date(until) <= new Date());
    var eff = avail || lapsed;
    var label, cls;
    if (eff) { label = 'Available'; cls = 'avail-on'; }
    else if (until) { label = 'Paused · til ' + fmt(until); cls = 'avail-off'; }
    else { label = 'Paused'; cls = 'avail-off'; }
    el.innerHTML = '<a class="avail-badge ' + cls + '" href="profile.html" title="Your Drop availability — tap to change">'
      + '<span class="avail-dot"></span>' + label + '</a>';
  }
  window.blAvailPaint = paint;  // profile.html repaints this after a toggle

  function go() {
    if (!window.supabase || !document.getElementById('availBadge')) return;
    var db = window.supabase.createClient(URL, KEY);
    db.auth.getSession().then(function (r) {
      if (!r.data || !r.data.session) return;
      db.from('agent_profiles').select('is_available, available_until').eq('id', r.data.session.user.id).single()
        .then(function (res) { if (res && res.data) paint(res.data.is_available, res.data.available_until); })
        .catch(function () {});
    }).catch(function () {});
  }
  if (document.readyState !== 'loading') go(); else document.addEventListener('DOMContentLoaded', go);
})();
