// Recent ListenBrainz listens for any element with class "lb-widget".
// Data: /1/user/<user>/listens?count=10 and /1/user/<user>/playing-now.
// A fresh result is reused for 60 s (sessionStorage). If ListenBrainz can't be
// reached, the last good result is shown from localStorage. The widget
// refreshes every 60 s while the tab is visible.
(() => {
  'use strict';

  const API = 'https://api.listenbrainz.org/1/user/';
  const CACHE_MS = 60 * 1000;
  const REFRESH_MS = 60 * 1000;
  const DEFAULT_USER = 'urazaliev';

  function readStore(storage, key) {
    try {
      const raw = storage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  }

  function writeStore(storage, key, value) {
    try {
      storage.setItem(key, JSON.stringify(value));
    } catch {
      // Storage full or blocked: the widget still works, just without a cache.
    }
  }

  async function fetchJSON(url) {
    const response = await fetch(url, { headers: { Accept: 'application/json' } });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  }

  async function load(user) {
    const key = `lb-widget:${user}`;
    const fresh = readStore(sessionStorage, key);
    if (fresh && Date.now() - fresh.at < CACHE_MS) return { ...fresh, offline: false };

    try {
      const base = API + encodeURIComponent(user);
      const [listens, playing] = await Promise.all([
        fetchJSON(`${base}/listens?count=10`),
        fetchJSON(`${base}/playing-now`),
      ]);
      const entry = {
        at: Date.now(),
        listens: listens?.payload?.listens ?? [],
        playing: playing?.payload?.listens?.[0] ?? null,
      };
      writeStore(sessionStorage, key, entry);
      writeStore(localStorage, key, entry);
      return { ...entry, offline: false };
    } catch (error) {
      const saved = readStore(localStorage, key);
      if (saved) return { ...saved, offline: true };
      throw error;
    }
  }

  // Cover art comes from the Cover Art Archive when the listen is mapped to
  // a MusicBrainz release.
  function releaseMBID(listen) {
    const metadata = listen?.track_metadata ?? {};
    return metadata.mbid_mapping?.caa_release_mbid
      ?? metadata.mbid_mapping?.release_mbid
      ?? metadata.additional_info?.release_mbid
      ?? null;
  }

  const relative = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });

  function timeAgo(unixSeconds) {
    const seconds = Math.round(unixSeconds - Date.now() / 1000);
    const units = [['day', 86400], ['hour', 3600], ['minute', 60]];
    for (const [unit, size] of units) {
      if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
    }
    return relative.format(0, 'minute');
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function artwork(listen) {
    const mbid = releaseMBID(listen);
    const placeholder = el('div', 'lb-widget__art lb-widget__art--empty', '♪');
    placeholder.setAttribute('aria-hidden', 'true');
    if (!mbid) return placeholder;

    const img = el('img', 'lb-widget__art');
    img.src = `https://coverartarchive.org/release/${encodeURIComponent(mbid)}/front-250`;
    img.alt = '';
    img.loading = 'lazy';
    img.decoding = 'async';
    img.addEventListener('error', () => img.replaceWith(placeholder), { once: true });
    return img;
  }

  function item(listen, nowPlaying) {
    const metadata = listen.track_metadata ?? {};
    const li = el('li', nowPlaying ? 'lb-widget__item lb-widget__item--now' : 'lb-widget__item');
    li.append(artwork(listen));

    const text = el('div', 'lb-widget__text');
    text.append(
      el('div', 'lb-widget__track', metadata.track_name ?? 'Unknown track'),
      el('div', 'lb-widget__artist', metadata.artist_name ?? 'Unknown artist'),
    );
    li.append(text);

    if (nowPlaying) {
      const bars = el('span', 'lb-widget__bars');
      bars.setAttribute('aria-label', 'Playing now');
      bars.append(el('span'), el('span'), el('span'));
      li.append(bars);
    } else {
      li.append(el('time', 'lb-widget__time', timeAgo(listen.listened_at)));
    }
    return li;
  }

  function render(root, user, data) {
    const header = el('div', 'lb-widget__header');
    header.append(el('h2', 'lb-widget__title', 'Recently played'));
    const link = el('a', 'lb-widget__user', user);
    link.href = `https://listenbrainz.org/user/${encodeURIComponent(user)}/`;
    link.rel = 'noopener';
    header.append(link);

    const list = el('ul', 'lb-widget__list');
    if (data.playing) list.append(item(data.playing, true));
    for (const listen of data.listens) list.append(item(listen, false));

    const children = [header];
    if (list.children.length) {
      children.push(list);
    } else {
      children.push(el('p', 'lb-widget__status', 'No listens yet.'));
    }
    if (data.offline) {
      const when = new Date(data.at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
      children.push(el('p', 'lb-widget__note', `ListenBrainz is unreachable. Showing listens saved at ${when}.`));
    }
    root.replaceChildren(...children);
  }

  function mount(root) {
    const user = root.dataset.user || DEFAULT_USER;
    let busy = false;

    async function refresh() {
      if (busy) return;
      busy = true;
      try {
        render(root, user, await load(user));
      } catch {
        root.replaceChildren(el('p', 'lb-widget__status', 'Couldn’t load listens right now.'));
      } finally {
        busy = false;
      }
    }

    refresh();
    setInterval(() => {
      if (document.visibilityState === 'visible') refresh();
    }, REFRESH_MS);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') refresh();
    });
  }

  document.querySelectorAll('.lb-widget').forEach(mount);
})();
