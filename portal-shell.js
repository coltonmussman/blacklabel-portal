/* Black Label portal — shared shell behavior for the redesign.
   Look-only helpers; every page keeps its own Supabase wiring.
   - mobile sidebar open/close
   - BLtagMoney(): adds the stronger "money" shimmer to $-bearing value cells (idempotent; call again after async data renders)
   - BLhideable()/BLrestoreHidden(): hover-x hideable dashboard widgets, remembered in localStorage */
(function () {
  function q(id) { return document.getElementById(id); }

  /* ---- mobile sidebar ---- */
  var side = q('side'), scrim = q('scrim'), hamb = q('hamb');
  if (hamb) hamb.setAttribute('aria-expanded', 'false');
  function openSide() { if (!side) return; side.classList.add('open'); if (scrim) scrim.classList.add('show'); if (hamb) hamb.setAttribute('aria-expanded', 'true'); }
  function closeSide() { if (!side) return; side.classList.remove('open'); if (scrim) scrim.classList.remove('show'); if (hamb) hamb.setAttribute('aria-expanded', 'false'); }
  if (hamb && side) hamb.addEventListener('click', openSide);
  if (scrim && side) scrim.addEventListener('click', closeSide);
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeSide(); });

  /* ---- money shimmer: only on $-bearing value cells, so notes/disclaimers never shimmer ---- */
  var MONEY_SEL = '.stat .num,.lb-val,.bignum .v,.sheet .cell .v,.strip .s .v,.refstat .s .v,.recap .r .v,.ring-info .big';
  window.BLtagMoney = function (root) {
    var els = (root || document).querySelectorAll(MONEY_SEL);
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.classList.contains('money')) continue;
      if ((el.textContent || '').indexOf('$') > -1) el.classList.add('money');
    }
  };

  /* ---- hideable widgets (dashboard) with localStorage memory ---- */
  // BLhideable(el, key, extras): adds a hover-x; hiding also hides any elements in `extras` (e.g. a section header).
  window.BLhideable = function (el, key, extras) {
    if (!el) return;
    extras = extras || [];
    function applyHidden(h) {
      el.classList.toggle('hidden', h);
      extras.forEach(function (x) { if (x) x.classList.toggle('hidden', h); });
    }
    var hidden = false;
    try { hidden = localStorage.getItem('blhide:' + key) === '1'; } catch (e) {}
    el.classList.add('hideable');
    applyHidden(hidden);
    var x = document.createElement('button');
    x.className = 'hidex'; x.type = 'button'; x.innerHTML = '&times;';
    x.title = 'Hide this'; x.setAttribute('aria-label', 'Hide this widget');
    x.addEventListener('click', function (e) {
      e.stopPropagation();
      applyHidden(true);
      try { localStorage.setItem('blhide:' + key, '1'); } catch (_) {}
    });
    el.appendChild(x);
    el.__blapply = applyHidden; el.__blkey = key;
  };
  // BLrestoreHidden(): bring every hidden widget back and forget the saved choices.
  window.BLrestoreHidden = function () {
    var any = false;
    document.querySelectorAll('.hideable').forEach(function (el) {
      if (el.classList.contains('hidden')) any = true;
      if (el.__blapply) el.__blapply(false);
      try { localStorage.removeItem('blhide:' + el.__blkey); } catch (_) {}
    });
    return any;
  };

  if (document.readyState !== 'loading') window.BLtagMoney();
  else document.addEventListener('DOMContentLoaded', function () { window.BLtagMoney(); });
})();
