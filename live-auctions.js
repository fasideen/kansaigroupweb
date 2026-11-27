/* Kansai Group — adds Live Auctions links to the homepage and turns the
   "Coming Soon" auction box into a live one. Load with:
   <script src="live-auctions.js" defer></script>  (just before </body>) */
(function () {
  var LINK = 'auctions.html';

  // styles
  var st = document.createElement('style');
  st.textContent =
    '.nav-live{color:var(--red)!important;display:inline-flex;align-items:center;gap:7px}' +
    '.nav-live::before,.btn-live::before{content:"";width:7px;height:7px;border-radius:50%;background:var(--red);animation:pulse 1.2s infinite}' +
    '.btn-live{border-color:var(--red)!important;color:var(--red)!important;gap:9px}' +
    '.mobile-menu-nav a.m-live{color:#fff;background:rgba(230,0,18,0.18)}';
  document.head.appendChild(st);

  function add(parent, el, before) {
    if (!parent) return;
    if (before && before.parentNode === parent) parent.insertBefore(el, before); else parent.appendChild(el);
  }

  // desktop nav (before "About")
  var ul = document.querySelector('nav ul');
  if (ul) {
    var li = document.createElement('li');
    li.innerHTML = '<a class="nav-live" href="' + LINK + '">Live Auctions</a>';
    var about = ul.querySelector('a[href="#about"]');
    add(ul, li, about && about.parentNode);
  }

  // mobile menu (first item)
  var mm = document.querySelector('.mobile-menu-nav');
  if (mm) {
    var ma = document.createElement('a');
    ma.className = 'm-live'; ma.href = LINK; ma.textContent = '● Live Auctions';
    mm.insertBefore(ma, mm.firstChild);
  }

  // hero button (after "Browse Stock")
  var actions = document.querySelector('.hero-actions');
  if (actions) {
    var hb = document.createElement('a');
    hb.className = 'btn-outline btn-live'; hb.href = LINK; hb.textContent = 'Live Auctions';
    var first = actions.querySelector('a');
    if (first && first.nextSibling) {
      actions.insertBefore(document.createTextNode(' '), first.nextSibling);
      actions.insertBefore(hb, first.nextSibling.nextSibling);
    } else { actions.appendChild(hb); }
  }

  // footer link
  var calc = document.querySelector('.footer-col a[href="duty-calculator.html"]');
  if (calc) {
    var fa = document.createElement('a');
    fa.href = LINK; fa.textContent = 'Live Auctions';
    calc.parentNode.insertBefore(fa, calc);
  }

  // auction box: replace the "Coming Soon" content straight away, then add the live count
  var box = document.querySelector('#auction .auction-box');
  if (!box) return;
  var label = box.querySelector('.auction-live span:last-child');
  var desc = box.querySelector('.auction-desc');
  var acts = box.querySelector('.auction-actions');
  var notify = acts && acts.querySelector('.auction-notify');
  var notifyHref = notify ? notify.getAttribute('href') : 'https://wa.me/601151177026';

  // n = null while loading (neutral wording), then the number of live auctions
  function paint(n) {
    if (label) label.textContent = n > 0 ? n + (n === 1 ? ' Auction Live Now' : ' Auctions Live Now') : 'Live Auctions';
    if (desc) desc.textContent = n === 0
      ? 'No auction is live at the moment. New vehicles are listed regularly, so check back soon or message us to be notified.'
      : 'Make an offer on hand-picked vehicles in under a minute. Enter your amount, name and number, then confirm on WhatsApp.';
    if (acts) acts.innerHTML =
      '<a href="' + LINK + '" class="btn-primary">' + (n === 0 ? 'View Auctions' : 'View Live Auctions') + '</a>' +
      '<a href="' + notifyHref + '" class="auction-notify">Notify me →</a>';
  }
  paint(null);

  try {
    sb.from('auctions').select('id,status,deadline').then(function (r) {
      if (!r || r.error || !r.data) return;
      var now = new Date();
      var n = r.data.filter(function (a) { return a.status !== 'closed' && (!a.deadline || new Date(a.deadline) > now); }).length;
      paint(n);
    });
  } catch (e) { /* keep the neutral version */ }
})();
