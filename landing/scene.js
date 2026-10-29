// Dusk: the nav turns to glass once the page moves, the four jobs switch the pane, the shelf demo toggles pin-lock, and the strip grows in when seen.
(() => {
  const nav = document.querySelector('[data-nav]');
  const hero = document.querySelector('.hero');
  if (nav && hero) {
    const set = () => nav.classList.toggle('is-solid', window.scrollY > hero.offsetHeight - 120);
    set();
    window.addEventListener('scroll', set, { passive: true });
  }

  const list = document.querySelector('[data-tabs]');
  if (list) {
    const tabs = [...list.querySelectorAll('[role="tab"]')];
    const pick = (t, focus) => {
      for (const o of tabs) {
        const on = o === t;
        o.setAttribute('aria-selected', String(on));
        o.tabIndex = on ? 0 : -1;
        const panel = document.getElementById(o.getAttribute('aria-controls'));
        if (panel) panel.hidden = !on;
      }
      if (focus) t.focus();
    };
    for (const t of tabs) t.addEventListener('click', () => pick(t));
    list.addEventListener('keydown', (e) => {
      const i = tabs.indexOf(document.activeElement);
      if (i < 0) return;
      const k = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (k) { e.preventDefault(); pick(tabs[(i + k + tabs.length) % tabs.length], true); }
      if (e.key === 'Home') { e.preventDefault(); pick(tabs[0], true); }
      if (e.key === 'End') { e.preventDefault(); pick(tabs[tabs.length - 1], true); }
    });
  }

  // Interactive Tuckbar secondary shelf in the hero
  const pinBtn = document.querySelector('[data-pin-toggle]');
  const pinLabel = document.querySelector('[data-pin-label]');
  const shelfStatus = document.querySelector('[data-shelf-status]');
  const searchInput = document.querySelector('[data-shelf-search]');
  const rows = [...document.querySelectorAll('[data-shelf-item]')];
  let editing = false;

  const updateCounts = () => {
    const pinned = rows.filter((r) => r.dataset.pinned === 'true').length;
    const hidden = rows.length - pinned;
    if (shelfStatus) {
      shelfStatus.textContent = editing
        ? `整理锁定中，${hidden} 项收起，${pinned} 项常驻`
        : `${hidden} 项收起，${pinned} 项常驻`;
    }
  };

  if (pinBtn) {
    pinBtn.addEventListener('click', () => {
      editing = !editing;
      pinBtn.classList.toggle('is-editing', editing);
      pinBtn.setAttribute('aria-pressed', String(editing));
      if (pinLabel) {
        pinLabel.textContent = editing ? '完成整理（已锁面板）' : '整理常驻图标';
      }
      updateCounts();
    });
  }

  for (const row of rows) {
    row.addEventListener('click', () => {
      if (!editing) return;
      const isPinned = row.dataset.pinned === 'true';
      row.dataset.pinned = String(!isPinned);
      const badge = row.querySelector('.acct__state');
      if (badge) {
        if (!isPinned) {
          badge.textContent = '常驻菜单栏';
          badge.classList.add('is-ok');
          row.classList.remove('is-open');
        } else {
          badge.textContent = '二级抽屉';
          badge.classList.remove('is-ok');
        }
      }
      updateCounts();
    });
  }

  if (searchInput) {
    searchInput.addEventListener('input', () => {
      const q = searchInput.value.trim().toLowerCase();
      for (const row of rows) {
        const name = (row.dataset.name || '').toLowerCase();
        row.hidden = q.length > 0 && !name.includes(q);
      }
    });
  }

  const strip = document.querySelector('.strip');
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (strip && !still && 'IntersectionObserver' in window) {
    const nights = [...strip.querySelectorAll('.night i')];
    nights.forEach((n, i) => { n.style.transitionDelay = `${i * 22}ms`; });
    strip.classList.add('is-waiting');
    const io = new IntersectionObserver((es) => {
      if (es.some((e) => e.isIntersecting)) { strip.classList.remove('is-waiting'); io.disconnect(); }
    }, { threshold: 0.35 });
    io.observe(strip);
  }
})();
