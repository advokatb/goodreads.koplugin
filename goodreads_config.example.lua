-- Copy this file to goodreads_config.lua and paste your Cookie header.
--
-- Easiest: DevTools (F12) → Network → reload goodreads.com → any request →
-- Request Headers → Cookie → copy the whole value.
--
-- One cookie is not enough. Writes need:
--   _session_id2                          (Rails session)
--   at-main, session-token, sess-at-main,  (Amazon SSO)
--   session-id, session-id-time, sst-main,
--   ubid-main, x-main
-- Optional but fine to keep: aws-waf-token, ccsid.
-- Do NOT keep jwt_token — it expires in ~5 minutes and breaks the request
-- if stale (the plugin strips it if you paste it anyway).
return {
  session_cookie = '',
}