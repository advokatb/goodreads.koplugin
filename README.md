# goodreads.koplugin

![GitHub release (latest by date)](https://img.shields.io/github/v/release/advokatb/goodreads.koplugin?style=for-the-badge&color=orange) ![GitHub all releases](https://img.shields.io/github/downloads/advokatb/goodreads.koplugin/total?style=for-the-badge&color=yellow) ![Platform](https://img.shields.io/badge/Platform-KOReader-success?style=for-the-badge&logo=koreader)


A [KOReader](https://github.com/koreader/koreader) plugin that syncs reading status, progress, and ratings from the reader to your [Goodreads](https://www.goodreads.com) account.

## Features

- Search for books on Goodreads by title and author (from document metadata or a manual query)
- Link a Goodreads edition to the open book (stored in the sidecar file)
- **Autolink** when the EPUB contains a `GOODREADS` identifier or an ISBN (on by default)
- Set status: **Want to read** / **Currently reading** / **Finished** / **Remove status**
- Sync rating from KOReader Book Status (1–5★, same scale as Goodreads)
- Auto-tracking: **Currently reading** while reading (optional percent via `POST /user_status.json`), **Finished** at ~100% / book completion (+ rating and today's date read)
- Manual **Update progress: N%** in the Goodreads menu (and a gesture) — posts percent now, even if auto-tracking is off
- Session cookies with live `Set-Cookie` rotation (`aws-waf-token` and friends)

> Goodreads exclusive shelves are at least **Want to read / Currently reading / Read**. Extra exclusive shelves from the account (for example **Did not finish** or **Paused**) appear in the menu. Custom tag shelves are not listed.

## Installation

1. Copy the `goodreads.koplugin` folder to your KOReader plugins directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Android: `/sdcard/koreader/plugins/`
   - Linux: `~/.config/koreader/plugins/`

2. Copy `goodreads_config.example.lua` → `goodreads_config.lua`:
   ```
   cp goodreads_config.example.lua goodreads_config.lua
   ```

3. Get your goodreads.com session cookies (the whole **Cookie** request header, not one named cookie):
   - Log in at [goodreads.com](https://www.goodreads.com) in a browser
   - Open DevTools (F12) → **Network** → reload → click any `www.goodreads.com` request
   - Copy **Request Headers → Cookie** (the assembled `name=value; …` string)
   - Do not keep `jwt_token` (short-lived; the plugin strips it)

   Required: `_session_id2` **and** the Amazon SSO set (`at-main`, `session-token`, `sess-at-main`, `session-id`, `session-id-time`, `sst-main`, `ubid-main`, `x-main`). `aws-waf-token` and `ccsid` are optional.

4. Paste the cookie string into `goodreads_config.lua`:
   ```lua
   return {
     session_cookie = '_session_id2=xxx; at-main=yyy; aws-waf-token=zzz; ...',
   }
   ```

5. Restart KOReader. **Goodreads** appears in the top menu.

### Alternative: enter cookies from the menu

**Menu → Goodreads → Settings → Session cookies**

## Usage

### Link a book

1. Open a book in KOReader
2. **Menu → Goodreads → Link book…**
3. If the file has a GOODREADS identifier, it is linked immediately
4. Otherwise the plugin searches by metadata and shows results
5. Tap **↩ New search** to search again

Hold-tap **Book: …** to unlink. Tap **Book: …** again to re-search.

### Change status

1. **Menu → Goodreads → Change status**
2. Pick a status (radio buttons)

The current status is cached in the sidecar and restored when you reopen the book.

### Update progress

1. Link the book and read at least 1%
2. **Menu → Goodreads → Update progress: N%**

This posts KOReader’s percent as a Goodreads status update immediately (no 60s wait). It does not require **Auto-track progress**. If the shelf is still **Want to read**, it is set to **Currently reading** first. Custom exclusive shelves such as **Paused** are left as-is. Near 100%, use **Change status → Finished** instead.

Turn off **Settings → Sync reading progress** if you only want these manual posts, not automatic ones while reading.

### Rating (★)

1. Set stars in KOReader **Book Status** (long-press status icon / book widget)
2. When setting **Finished**, the rating is sent automatically (if enabled in settings)
3. Or manually: **Menu → Goodreads → Send rating (N★)**

Scale: 1–5★ in KOReader = 1–5 on Goodreads (no conversion).

### Auto-tracking

1. Link the book
2. Enable **Auto-track progress** in the Goodreads menu (or globally: **Settings → Auto-tracking for new books**)
3. On link (or as soon as you start turning pages) → **Currently reading**, and percent is posted to Goodreads once it is ≥1% (status update; at most once a minute)
4. At ~100%, EndOfBook, or Book Status = complete → **Finished** (+ rating + today's date read)
5. Book Status = abandoned → **Did not finish** if that exclusive shelf exists on the account

Requests are throttled (max once per minute). Turn off **Settings → Sync reading progress** if you do not want automatic percent updates in the Goodreads feed; **Update progress** in the menu still works. Custom exclusive shelves (not the three system ones) are left alone. **Enable Wi-Fi on demand** helps on devices that can restore Wi-Fi automatically.

### Autolink

**Settings → Autolink by GOODREADS identifier** (on by default). When you open an unlinked EPUB whose metadata contains `goodreads:12345`, the plugin links that id without a search dialog.

**Settings → Autolink by ISBN** (on by default). If there is no GOODREADS id, the plugin searches by ISBN and links the first match. It does not guess from the title.

### Gestures / hardware keys

In **Menu → Settings → Gestures**, you can assign:

- **Goodreads: Link book**
- **Goodreads: Status — Currently reading**
- **Goodreads: Status — Finished**
- **Goodreads: Enable / Disable auto-tracking**
- **Goodreads: Send rating**
- **Goodreads: Update progress**

## Data storage

| Data | Location |
|------|----------|
| Session cookies, plugin settings | `<koreader_dir>/settings/goodreads_settings.lua` |
| Book link (book id, status, rating, sync) | Sidecar (`*.sdr/metadata.*.lua`, key `goodreads`) |
| KOReader rating / status | Sidecar `summary.rating` / `summary.status` |
| Secret cookies (manual config) | `goodreads_config.lua` (gitignored) |

## Updating cookies

Goodreads cookies expire (especially `_session_id2`). The plugin applies `Set-Cookie` from responses. Refresh the full bundle from the browser when you see “Goodreads: session expired”.

You do not need to restart KOReader after pasting new cookies.

## Technical details

- **Auth:** browser Cookie header (Rails `_session_id2` + Amazon SSO; not a single cookie; no official API)
- **HTTP:** `socket.http` + `ltn12`; GET without `Origin`; `Sec-Fetch-*` on navigations
- **JSON:** built-in `json` module
- **CSRF:** `<meta name="csrf-token">` from `GET /` (homepage is still Rails)
- **Progress:** `POST /user_status.json` with `user_status[percent]` (never page+percent together)
- **Anti-bot:** AWS WAF; keep `aws-waf-token` if the browser sent it; never replay `jwt_token`

## License

MIT

## Credits

Architecture inspired by:

- [livelib.koplugin](https://github.com/advokatb/livelib.koplugin) — plugin structure
- [storygraph.koplugin](https://github.com/burneracc0112/storygraph.koplugin) — session cookie auth
- [hardcoverapp.koplugin](https://github.com/billiam/hardcoverapp.koplugin) — identifier autolink UX
