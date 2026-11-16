# LINE21 Hub

One Mac app to install and update LINE21 software, and one release catalog on Railway that both the Hub and apps with their own update button (PROXEL) read from. You publish a version in one place.

The first version covers **LineSeparator** and **FloatBlur** for DaVinci Resolve (OFX).

```
app/        LINE21 Hub (SwiftUI, macOS 13+)
api/        Catalog API for Railway (Node 22): catalog, downloads, Tauri feed, stats
catalog/    The catalog itself: products, versions, release notes, requirements (versioned in git)
tools/      keygen, release (sign + upload + write catalog), validate
docs/       CATALOG.md: the schema, and how Adobe, PROXEL and web apps fit in
```

## What the Hub does

1. On launch, every 4 hours and when the Mac wakes: fetches the catalog and reads the version in each installed bundle's `Info.plist` (`/Library/OFX/Plugins/Seperator.ofx.bundle`, `FloatBlur.ofx.bundle`).
2. Shows *installed → new version*, "What's new" for every version in between, and one Mac notification per new version.
3. **Update** (or **Update All**):
   - If Resolve is open, it asks: *Quit Resolve* (Resolve still asks to save) or *When I Quit It*, where the Hub waits and updates as soon as Resolve has quit.
   - Downloads the package through a short-lived link from the private bucket.
   - Checks size, SHA-256 and LINE21's Ed25519 signature. The signature covers target, version and platform, so a valid file can't be replayed as another release.
   - Unpacks and checks that the bundle has the right bundle ID and exactly the promised version, and that any code signature is intact.
   - Backs up the current bundle to `~/Library/Application Support/LINE21 Hub/Backups` (last 3 per plugin). Right-click → *Restore Backup*.
   - Writes the new bundle. `/Library/OFX/Plugins` is protected, so the row shows a lock up front and macOS asks for the password. Everything runs in one privileged command, so an interrupted install never leaves half a bundle.
   - Reads the version again afterwards and reports an error if it doesn't match.

## Publish a new version

Once: `npm install && npm run keygen`. The private key goes to `~/.line21/hub-signing-key.pem` and must never go into git or onto Railway. The public key is built into the Hub (repository variable `LINE21_SIGNING_PUBLIC_KEY`).

```sh
# 1. Build the plugin as usual and bump its version (CMake project VERSION)
# 2. Sign, upload and write the catalog:
BUCKET=… ENDPOINT=… ACCESS_KEY_ID=… SECRET_ACCESS_KEY=… \
npm run release -- --target lineseparator-ofx-macos --version 0.3.1 \
  --file ~/Downloads/Seperator-macOS-universal.zip --notes-file notes.md --upload
# 3. git commit catalog/ && git push   → Railway redeploys the API
```

The tool refuses if the bundle ID or version inside the zip doesn't match what you're releasing.

### Publish a new LINE21 Hub

The Hub is in the catalog too (`line21-hub-macos`), so it updates itself: when a newer version is published, a banner says *LINE21 Hub X is available* and **Update & Relaunch** downloads it, checks the signature, swaps the app where it lives and opens the new one.

1. Push to `main`. CI builds the app as version `0.1.<run number>`.
2. Download the `LINE21-Hub` artifact from the run and unzip it once, so you have `LINE21-Hub.zip` (it contains `LINE21 Hub.app`).
3. Sign, upload and add it to the catalog:

```sh
railway run npm run release -- --target line21-hub-macos --version 0.1.N \
  --file ~/Downloads/LINE21-Hub.zip --notes "- What changed" --upload
git commit -am "Publish LINE21 Hub 0.1.N" && git push
```

`https://<api>/download/line21-hub-macos` always points at the newest stable Hub, so that's the link to put on the website. It works for every target (`/download/floatblur-ofx-macos`, …).

## API

| Endpoint | |
| --- | --- |
| `GET /v1/catalog?channel=stable\|beta` | The whole catalog, newest first, with an ETag. No bucket keys. |
| `GET /v1/targets/:id` | One target. |
| `GET /download/:target` | 302 to the newest stable macOS package. A fixed link for the website. |
| `GET /v1/download/:target/:version/:platform-:arch` | 302 to a link that expires after 10 minutes. Counted as a download. |
| `GET /v1/tauri/:target/:os/:arch/:current` | Tauri updater format for PROXEL (200 or 204). |
| `POST /v1/events` | Anonymous events from the Hub. |
| `GET /admin` | Stats page, private to you (needs `ADMIN_TOKEN`). |
| `GET /healthz` | Health check for Railway. |

Environment: `ADMIN_TOKEN`, `PUBLIC_BASE_URL`, the bucket's `BUCKET`/`ENDPOINT`/`REGION`/`ACCESS_KEY_ID`/`SECRET_ACCESS_KEY`, and `DATABASE_URL` for stats (without it, events go to `EVENTS_FILE`, which must live on a volume to survive deploys).

## Stats

The Hub creates a random ID on first launch and sends: Hub version, macOS version, architecture, which LINE21 versions and which Resolve version are installed, and each download, update, failure (as a short error code) and rollback. No names, emails, files, projects or IP addresses. Users can turn it off in Settings. `/admin` shows active Hubs per day, downloads and installs per version, what people have installed right now, failures, and Resolve/macOS versions.

## Development

```sh
npm install && npm test            # API and catalog
npm run dev                        # API on :8080 with the local catalog
cd app && swift test               # Hub core (versions, signatures)
PUBLIC_KEY=… app/scripts/build-app.sh   # app/dist/LINE21 Hub.app
```

CI builds the app on every push to `main` and attaches `LINE21-Hub.zip` to the run.
