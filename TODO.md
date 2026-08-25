# TODO

Known-broken / known-missing, roughly worst first. PoC stage: security items are
listed but deliberately not blocking.

## bugs

- [ ] `go mod tidy` has never been run against the current import set: every direct
      dependency (websocket, gin-contrib/zap, glebarez/sqlite, uuid, zap, gorm,
      zapgorm2) is marked `// indirect`, and go.sum carries stale duplicate `h1:`
      lines for x/text, x/mod, x/sync, x/tools.

## security (post-PoC)

- [ ] `/ws/:id` is unauthenticated. Anyone who learns a job id can connect, and the
      read loop writes whatever it receives into DataStorage and publishes a
      MessageService notification for it. Should go through GameMiddleware, or at
      least require the API key.
- [ ] `OriginPatterns: allowedOrigins` is commented out in `websocket.Accept`, so
      the socket accepts any Origin and `allowedOrigins` is now dead. Re-enable
      before anything is exposed off localhost.
- [ ] `GameMiddleware` is wired as `[]string{universeId}` but compares against the
      `roblox-id` header, which carries the place id, not the universe id. Inert
      while `strict` is false; will reject every request the moment it's true.

## cleanup

- [ ] `/send` and `/data/:uuidv4` now require a `Job-ID` header (the middleware
      routes on it). The Luau client still has to be updated to send it.
- [ ] `fmt.Sprint(c.MustGet("jobid"))` in both handlers is just `c.GetString("jobid")`.
- [ ] No tests exist for the hub fan-out or the ws teardown path.
