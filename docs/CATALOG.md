# The release catalog

The catalog is files in `catalog/` in git. Every release is a commit, so the history shows who published what and when, and a mistake is undone with `git revert`. The API reads the files at startup, and Railway restarts it on every push.

```
catalog/
  hosts.json          host apps (Resolve, Premiere, After Effects): names, bundle IDs, paths
  support.json        the "Buy me a coffee" button and its tiers
  products/*.json     one product per file
```

## Product, target and release

A **product** is what the user knows (FloatBlur). A **target** is one installation of it, with its own version. FloatBlur for Resolve and FloatBlur for Adobe are two targets under one product, so the Hub can show them separately and they can be released independently. A **release** is one version of one target, with notes, requirements and files.

| Field | Meaning |
| --- | --- |
| `target.kind` | `plugin-bundle` and `app-bundle`: the Hub installs them. `tauri-app`: the app updates itself via `/v1/tauri/...`. `web-app`: the Hub opens it and shows "What's new". |
| `target.host` | Key in `hosts.json`. The Hub asks the user to quit the host before replacing the plugin. |
| `target.install` | `path` (where the bundle lives) and `bundleId` (so the Hub never touches someone else's bundle at the same path). |
| `release.channel` | `stable` or `beta`. Beta is only shown to people who turned it on in the Hub. |
| `release.status` | Set `"withdrawn"` to pull a version. It disappears from the catalog, and the Hub warns people who have it. |
| `release.requires` | `macos` and `hosts` (e.g. `{"davinci-resolve": "19.0"}`). The Hub only offers versions the Mac can run. |
| `artifact` | `platform`, `arch` (`universal`, `arm64`, `x64`), bucket `key`, `size`, `sha256` and `signature`. Written by `npm run release`. |

## What the next products look like

FloatBlur for Adobe, as an extra target in `products/floatblur.json`:

```json
{
  "id": "floatblur-adobe-macos",
  "label": "FloatBlur for Premiere Pro and After Effects",
  "kind": "plugin-bundle",
  "platform": "macos",
  "host": "adobe-premiere-pro",
  "install": {
    "path": "/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/FloatBlur.plugin",
    "bundleId": "dk.line21.floatblur.adobe"
  },
  "releases": []
}
```

Sidechain Link follows the same pattern. When a plugin is used in both Premiere and After Effects, `host` can be extended to a list; that's the only change Adobe needs.

PROXEL (Tauri), `products/proxel.json`. The app points its updater at `https://<api>/v1/tauri/proxel-macos/{{target}}/{{arch}}/{{current_version}}`:

```json
{
  "id": "proxel",
  "name": "PROXEL",
  "targets": [{
    "id": "proxel-macos",
    "label": "PROXEL",
    "kind": "tauri-app",
    "platform": "macos",
    "install": { "path": "/Applications/PROXEL.app", "bundleId": "dk.line21.proxel" },
    "releases": [{
      "version": "1.2.0", "channel": "stable", "date": "2026-12-01", "notes": "- …",
      "artifacts": [{
        "platform": "macos", "arch": "arm64", "key": "proxel/…/PROXEL.app.tar.gz",
        "size": 0, "sha256": "…", "signature": "…",
        "tauriSignature": "contents of PROXEL.app.tar.gz.sig from tauri build"
      }]
    }]
  }]
}
```

Gearbank and Co-E Platform (web), without files:

```json
{
  "id": "gearbank",
  "name": "Gearbank",
  "targets": [{
    "id": "gearbank-web",
    "label": "Gearbank",
    "kind": "web-app",
    "platform": "web",
    "url": "https://gearbank.example",
    "releases": [{ "version": "2026.11.13", "channel": "stable", "date": "2026-11-13", "notes": "- …", "artifacts": [] }]
  }]
}
```

## When to add PostgreSQL

The git catalog works until you need an admin panel: when someone other than you publishes, or when beta channels and withdrawals should be managed without a commit. The fields above map 1:1 to tables (`products`, `targets`, `releases`, `artifacts`), and the API's responses don't change, so the Hub doesn't need an update.
