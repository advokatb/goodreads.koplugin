# Changelog

## [0.3.0] - 2026-09-01

### Fixed
- Stale CSRF: cookie rotation now drops the cached token, and a POST that
  returns **404** (Goodreads’ usual response for a dead authenticity_token)
  retries once after `GET /`. Failed progress posts are throttled so they
  do not fire on every page turn.

## [0.2.0] - 2026-08-27

### Added
- Menu item **Update progress: N%** (and a gesture) to post the current percent
  to Goodreads on demand. Independent of auto-tracking and of **Sync reading
  progress**. Want to read is switched to Currently reading; Finished / DNF /
  ~100% still go through Change status.

### Fixed
- Switching to a custom exclusive shelf (e.g. Paused) no longer leaves a
  leftover Finished/DNF/`-2` in sidecar `status`. Lua omits `status = nil`;
  the write now UNSETs it. Update progress trusts `shelf` when it is set.
- Auto-track sets **Currently reading** as soon as the book is linked (and on
  the first pages). It no longer waits for 1% progress, so a
  new book is not left unshelved after autolink.
- After Kobo resume, do not show a blocking “no network” dialog while Wi-Fi
  is up but DHCP has not finished. Background sync waits for a real
  connection and retries once; a leftover network error is a 3s toast.

## [0.1.0] - 2026-08-27

First public release: link a Goodreads edition to the open KOReader book,
sync exclusive-shelf status, rating, date finished, and reading percent.
Session cookies only (no official API). English / Russian / Ukrainian UI.

### Added
- Search via `GET /book/auto_complete` (JSON) and link to sidecar key `goodreads`.
- Autolink by embedded `GOODREADS` / `goodreads:` identifier (on by default).
- Autolink by ISBN when no GOODREADS id is present (on by default; not by title).
- Status: Want to read / Currently reading / Finished / Status removed.
  Extra exclusive shelves from ShelfChooser (e.g. Did not finish, Paused).
  Non-exclusive tag shelves are not listed.
- Rating 1–5★ from KOReader Book Status (`POST /review/rate/{book_id}`).
- Date finished (today) on Finished via reading sessions; skip if a session
  already exists.
- Reading percent via `POST /user_status.json` (`user_status[percent]`; never
  page and percent together). Auto-tracking posts at most once a minute while
  Currently reading. Toggle: Settings → Sync reading progress.
- Auto-tracking: ≥1% → Currently reading; ~100% / Book Status / EndOfBook →
  Finished (+ rating + date). Abandoned → DNF if that exclusive shelf exists.
- CSRF from `GET /`, cookie rotation from `Set-Cookie`, session-expired
  detection. `jwt_token` is stripped (stale JWT breaks requests).
- Settings: cookies, autolink, sync rating/progress, Wi-Fi on demand, confirm
  dialogs. Dispatcher actions for link / status / rating / auto-tracking.
- i18n (`locale/ru.po`, `locale/uk.po`) and GitHub Release workflow.

### Fixed
- `POST /review/rate` HTTP **204 No Content** treated as success.
- Status removed uses `POST /review/destroy/{book_id}` (exclusive `a=remove`
  is 404). Sidecar `shelf` is actually cleared after remove (no double radio).
- GET without `Origin` (avoids self-redirect hangs). Comma-folded `Set-Cookie`
  merged on redirect hops.
- `add_to_shelf` success parsing when `read_status` is JS-string-escaped.
- HTTP 429/5xx retried twice; parse errors surface instead of failing silently.
