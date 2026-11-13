# Udgivelseskataloget

Kataloget er filer i `catalog/` i git. Hver udgivelse er et commit, så historikken viser hvem der udgav hvad og hvornår, og en fejl rulles tilbage med `git revert`. API'et læser filerne ved opstart, og Railway genstarter det ved hvert push.

```
catalog/
  hosts.json          værtsprogrammer (Resolve, Premiere, After Effects): navne, bundle-id'er, stier
  support.json        "Giv en kop kaffe"-knappen og dens tiers
  products/*.json     ét produkt pr. fil
```

## Produkt, target og release

Et **produkt** er det brugeren kender (FloatBlur). Et **target** er én installation af det, med sin egen version. FloatBlur til Resolve og FloatBlur til Adobe er to targets under samme produkt, så Hubben kan vise dem hver for sig, og de kan udgives uafhængigt. En **release** er én version af ét target, med ændringer, krav og filer.

| Felt | Betydning |
| --- | --- |
| `target.kind` | `plugin-bundle` og `app-bundle`: Hubben installerer selv. `tauri-app`: appen opdaterer sig selv via `/v1/tauri/...`. `web-app`: Hubben åbner den og viser "Hvad er nyt". |
| `target.host` | Nøgle i `hosts.json`. Hubben beder brugeren lukke værten før udskiftning. |
| `target.install` | `path` (hvor bundlen ligger) og `bundleId` (så Hubben ikke rører en fremmed bundle på samme sti). |
| `release.channel` | `stable` eller `beta`. Beta ses kun af dem, der har slået det til i Hubben. |
| `release.status` | Sæt `"withdrawn"` for at trække en version tilbage. Den forsvinder fra kataloget, og Hubben advarer dem, der har den. |
| `release.requires` | `macos` og `hosts` (fx `{"davinci-resolve": "19.0"}`). Hubben tilbyder kun versioner, Mac'en kan køre. |
| `artifact` | `platform`, `arch` (`universal`, `arm64`, `x64`), `key` i bucketen, `size`, `sha256` og `signature`. Skrives af `npm run release`. |

## Sådan ser de næste produkter ud

FloatBlur til Adobe, som et ekstra target i `products/floatblur.json`:

```json
{
  "id": "floatblur-adobe-macos",
  "label": "FloatBlur til Premiere Pro og After Effects",
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

Sidechain Link følger samme mønster. Når et plugin bruges i både Premiere og After Effects, kan `host` udvides til en liste; det er den eneste ændring, Adobe kræver.

PROXEL (Tauri), `products/proxel.json`. Appen peger sin updater på `https://<api>/v1/tauri/proxel-macos/{{target}}/{{arch}}/{{current_version}}`, og Hubben viser den med en "Åbn"-knap:

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
        "tauriSignature": "indholdet af PROXEL.app.tar.gz.sig fra tauri build"
      }]
    }]
  }]
}
```

Gearbank og Co-E Platform (web), uden filer:

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

## Hvornår PostgreSQL

Kataloget i git holder til et adminpanel bliver nødvendigt: når andre end dig skal udgive, eller når betakanaler og tilbagetrækninger skal styres uden et commit. Felterne ovenfor flytter 1:1 til tabeller (`products`, `targets`, `releases`, `artifacts`), og API'ets svar ændrer sig ikke, så Hubben skal ikke opdateres.
