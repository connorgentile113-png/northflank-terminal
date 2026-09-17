# Free Educational Coding Machine

A browser-accessible Linux terminal on Northflank, served entirely through **one
ngrok tunnel**. The browser never contacts a CDN, unpkg, or Firebase: the only
external reference in the UI is a Google Fonts stylesheet, and it is loaded
asynchronously so a blocked font request cannot stall the page.

```
                        ┌────────────────── Northflank container ──────────────────┐
  browser ──https──▶ ngrok ──▶ nginx :8080 ─┬─▶ /                  index.html (UI)  │
   (one URL)                                ├─▶ /terminal/*         ttyd :7681     │
                                            ├─▶ /port/<PORT>/*      any localhost  │
                                            └─▶ /healthz            health check   │
                                                                                     │
  ngrok :4040/api/tunnels ──polled by──▶ tunnel-url-writer.sh ──curl PUT──▶ Firebase  │
                                                                    (server side)    │
                        └───────────────────────────────────────────────────────────┘
```

## Files

| File | Role |
| --- | --- |
| `Dockerfile` | ubuntu:22.04 + ttyd 1.7.7, nginx, ngrok, Node LTS, python3, supervisord |
| `entrypoint.sh` | ulimits, dirs, ngrok authtoken, optional auth, welcome banner, `exec supervisord` |
| `supervisord.conf` | keeps nginx / ttyd / ngrok / writer / keepalive alive, logs to stdout |
| `nginx.conf` | one HTTP surface: static UI, ttyd proxy, dynamic port proxy with asset rewriting |
| `index.html` | the entire frontend — landing page, terminal shell, sliding Ports panel |
| `tunnel-url-writer.sh` | ngrok local API → `PUT /tunnel/url.json` on Firebase (plain curl, no SDK) |
| `firebase-rules.json` | Realtime Database rules: public read of `tunnel`, writes off |
| `northflank.json` | combined-service resource definition (Dockerfile build, port 8080, health check) |

## Deploy on Northflank

1. **Push this directory to a Git repo** (or upload it as a build bundle). If you
   move the files, update `buildSettings.dockerfile.dockerFilePath` and
   `dockerWorkDir` in `northflank.json` — they currently point at
   `/northflank-terminal/Dockerfile` and `/northflank-terminal`.

2. **Create the service** either in the UI (Build type: **Dockerfile**, exposed
   port **8080 HTTP**, instances 1, plan `nf-compute-20` = 0.2 vCPU / 512 MB,
   health check `GET /`), or from the resource definition:

   ```bash
   curl --header "Content-Type: application/json" \
        --header "Authorization: Bearer $NORTHFLANK_API_TOKEN" \
        --request POST \
        --data @northflank.json \
        https://api.northflank.com/v1/projects/<projectId>/services/combined
   ```

   The Northflank CLI consumes the same file: `northflank ... -f northflank.json`.

3. **Set the runtime variables** (they are already in `northflank.json`):

   | Variable | Purpose |
   | --- | --- |
   | `NGROK_AUTHTOKEN` | the ngrok agent token (required for a stable tunnel) |
   | `FIREBASE_DATABASE_URL` | `https://vps-server-2bcbd-default-rtdb.firebaseio.com` |
   | `FIREBASE_TUNNEL_PATH` | `/tunnel/url.json` |
   | `FIREBASE_DB_SECRET` | optional — only needed once Firebase writes are authenticated |
   | `PORT_LIST` | the ports pre-listed in the UI panel |
   | `TERMINAL_PASSWORD`, `TERMINAL_USER` | optional basic auth for `/terminal/` and `/port/*/` |

4. **Deploy.** Then read the public URL from the container logs (`[tunnel]` lines),
   from the terminal (`cat /run/tunnel-url`), or from Firebase:

   ```bash
   curl -s https://vps-server-2bcbd-default-rtdb.firebaseio.com/tunnel/url.json
   ```

### Deploying the Firebase rules

`firebase-rules.json` publishes `tunnel` for public reading and disables writes:

```bash
firebase deploy --only database
# or paste the JSON into the Realtime Database → Rules tab
```

> **Writes vs. rules.** The rules above set `".write": false`, so the
> container's `PUT` only succeeds while the database is still in open/test mode.
> The moment you deploy these rules the writer starts reporting `HTTP 401`, and
> the logs say so explicitly. To keep publishing with the rules in place, use a
> database secret (Project settings → Service accounts → Database secrets) and
> set `FIREBASE_DB_SECRET` — the writer then sends `?auth=<secret>`.
> The `apiKey` in the Firebase config is **not** used anywhere in this project:
> the Realtime Database REST API does not need it, and no Firebase code ever runs
> in the browser.

## Using it

- **`/`** — landing page. *Continue →* fades into the terminal with no page
  reload; the terminal iframe is already loaded underneath, so it appears
  instantly rather than reconnecting on click.
- **Terminal** — `ttyd` with `--writable --terminal-type xterm-256color` running
  `bash -l`, so `nano`, `vim`, `htop`, `tmux` and 256-colour TUIs render
  correctly. `npm`, `npx`, `node`, `python3`, `pip`, `git`, `apt` all work
  (root inside the container).
- **⚡ Ports** (bottom-right) — slides a panel over the terminal (the terminal
  session is untouched, nothing is reloaded). It lists 3000, 4200, 5173, 8000,
  8080 and 8888 plus a free-text port box; **Open** renders `/port/<PORT>/` in an
  iframe inside the panel.
- **`/port/<PORT>/`** — direct URL for any port, e.g. `/port/5173/` for a Vite
  dev server. Deep link with `/?port=5173`.

Try it in the terminal:

```bash
python3 -m http.server 8000      # then open /port/8000/
npm create vite@latest app -- --template vanilla && cd app && npm i && npm run dev -- --host
```

## Verification

```bash
# build and run locally
docker build -t coding-machine northflank-terminal
docker run --rm -it -p 8080:8080 -e NGROK_AUTHTOKEN=<token> coding-machine

# inside the container
supervisorctl status            # nginx, ttyd, ngrok, writer, keepalive RUNNING
nginx -t                        # config is validated at build and at boot
curl -s localhost:4040/api/tunnels | jq -r '.tunnels[].public_url'
cat /run/tunnel-url             # what was published to Firebase
```

If the public URL loads but the terminal stays blank, check in this order:
`nginx` is up (`/healthz`), `ttyd` is up (`curl -sI localhost:7681/terminal` →
302), then the tunnel (`curl localhost:4040/api/tunnels`).

## Known caveats

- **Port 8080 cannot be previewed.** 8080 is the port this proxy itself listens
  on, so `/port/8080/` would recurse back into nginx; the route answers with an
  explanation page instead (see the `location ~ ^/port/8080` block in
  `nginx.conf`). Run apps on any other port.
- **ngrok's free tier shows a one-time interstitial** ("You are about to visit…")
  on the first browser navigation. Click through once — the cookie covers the
  rest of the session, including the terminal WebSocket.
- **Absolute-URL apps need a base path.** The proxy rewrites `src="/…"`,
  `href="/…"`, `url(/…)`, `fetch('/…')` and the common bundler roots (`/_next/`,
  `/assets/`, `/static/`, `/build/`, `/@vite/`, …), which covers most dev
  servers. Frameworks that hardcode absolute URLs from a config value still need
  that value pointed at the prefix, e.g. Vite: `base: '/port/5173/'`, and
  `server.allowedHosts: true` (Vite blocks unknown `Host` headers) plus
  `server.hmr.clientPort` if HMR does not connect.
- **`sub_filter` disables upstream compression** on `/port/*/` (`Accept-Encoding: ""`),
  which is required for rewriting to work. This route also keeps proxy buffering
  on so rewritten tags are not split across chunks; streaming SSE previews are
  therefore chunked rather than live.
- **This is a public root shell on the internet.** Anyone with the URL gets
  root in the container. For anything beyond a throwaway sandbox, set
  `TERMINAL_PASSWORD` (and optionally `TERMINAL_USER`) so nginx puts basic auth
  in front of `/terminal/` and `/port/*/`; the landing page stays public so the
  platform health check keeps returning 200.
- **Keep the ngrok token out of git.** `northflank.json` ships a
  `REPLACE_WITH_NGROK_AUTHTOKEN` placeholder — put the real value in a Northflank
  secret group or runtime variable. The container only ever reads it from the
  environment and never logs it, so no rebuild is needed to change it.
- **supervisord `command` lines are Python `%`-formatted.** A literal percent
  sign must be written `%%`. A `date +%FT%TZ` argument, for instance, parses as a
  float conversion and supervisord aborts at startup with
  `is badly formatted: must be real number, not dict`. The keepalive program
  therefore uses `date -Iseconds`. If you edit these lines, read every `%` in
  them as a format spec and escape anything that is meant literally.
- **512 MB is tight.** Install AI CLIs one at a time
  (`npm i -g @openai/codex`, `pip install aider-chat`); if node gets OOM-killed
  during an install, retry with `NODE_OPTIONS=--max-old-space-size=384`. The
  `keepalive` supervisor program also touches a heartbeat every 2 minutes so the
  free tier does not treat the service as idle.
- **Single-instance only.** The tunnel URL is per-container and published
  globally, so scaling this service past one replica makes the published URL
  flap between instances.
