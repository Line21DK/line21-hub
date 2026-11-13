# LINE21 Hub

Én Mac-app til at installere og opdatere LINE21-software, og ét udgivelseskatalog på Railway, som både Hubben og apps med egen opdateringsknap (PROXEL) læser fra. Du udgiver en version ét sted.

Første version dækker **LineSeparator** og **FloatBlur** til DaVinci Resolve (OFX).

```
app/        LINE21 Hub (SwiftUI, macOS 13+)
api/        Katalog-API til Railway (Node 22): katalog, downloads, Tauri-feed, statistik
catalog/    Selve kataloget: produkter, versioner, ændringer, krav (versionsstyret i git)
tools/      keygen, release (signér + upload + skriv katalog), validate
docs/       CATALOG.md: skemaet og hvordan Adobe, PROXEL og webapps kommer ind
```

## Hvad Hubben gør

1. Ved opstart, hver 4. time og når Mac'en vågner: henter kataloget og læser versionen i `Info.plist` på hver installeret bundle (`/Library/OFX/Plugins/Seperator.ofx.bundle`, `FloatBlur.ofx.bundle`).
2. Viser *installeret → ny version*, "Hvad er nyt" for alle versioner imellem, og en Mac-notifikation én gang pr. ny version.
3. **Opdater** (eller **Opdater alle**):
   - Er Resolve åben, spørger den: *Luk Resolve* (Resolve beder selv om at gemme) eller *Når jeg lukker det*, hvor Hubben venter og opdaterer, så snart Resolve er lukket.
   - Henter pakken via et tidsbegrænset link fra den private bucket.
   - Tjekker størrelse, SHA-256 og LINE21's Ed25519-signatur. Signaturen dækker target, version og platform, så en gyldig fil ikke kan genbruges som en anden udgivelse.
   - Pakker ud og tjekker, at bundlen har det rigtige bundle-id og præcis den lovede version, og at en eventuel kodesignatur er intakt.
   - Tager backup af den nuværende bundle i `~/Library/Application Support/LINE21 Hub/Backups` (de seneste 3 pr. plugin). Højreklik → *Læg backup tilbage*.
   - Skriver den nye bundle. `/Library/OFX/Plugins` er beskyttet, så knappen viser *Kræver adgangskode* på forhånd, og macOS' egen dialog beder om den. Alt sker i én privilegeret kommando, så en afbrudt installation ikke efterlader en halv bundle.
   - Læser versionen igen bagefter og melder fejl, hvis den ikke passer.

## Udgiv en ny version

Én gang: `npm install && npm run keygen`. Den private nøgle lægges i `~/.line21/hub-signing-key.pem` og må aldrig i git eller på Railway. Den offentlige nøgle bygges ind i Hubben.

```sh
# 1. Byg plugin'et som altid og bump versionen (CMake project VERSION)
# 2. Signér, upload og skriv kataloget:
BUCKET=… ENDPOINT=… ACCESS_KEY_ID=… SECRET_ACCESS_KEY=… \
npm run release -- --target lineseparator-ofx-macos --version 0.3.1 \
  --file ~/Downloads/Seperator-macOS-universal.zip --notes-file notes.md --upload
# 3. git commit catalog/ && git push   → Railway genudruller API'et
```

Værktøjet nægter, hvis zip'ens bundle-id eller version ikke passer med det, du udgiver.

## API

| Endpoint | |
| --- | --- |
| `GET /v1/catalog?channel=stable\|beta` | Hele kataloget, nyeste først, med ETag. Ingen bucket-nøgler. |
| `GET /v1/targets/:id` | Ét target. |
| `GET /v1/download/:target/:version/:platform-:arch` | 302 til et link, der udløber efter 10 min. Tælles som download. |
| `GET /v1/tauri/:target/:os/:arch/:current` | Tauri-updater-format til PROXEL (200 eller 204). |
| `POST /v1/events` | Anonyme hændelser fra Hubben. |
| `GET /admin` | Statistikside (kræver `ADMIN_TOKEN`). |
| `GET /healthz` | Sundhedstjek til Railway. |

Miljøvariabler: `ADMIN_TOKEN`, `PUBLIC_BASE_URL`, bucketens `BUCKET`/`ENDPOINT`/`REGION`/`ACCESS_KEY_ID`/`SECRET_ACCESS_KEY`, og `DATABASE_URL` til statistikken (uden den skrives hændelser til `EVENTS_FILE`, som skal ligge på et volume for ikke at forsvinde ved deploy).

## Statistik

Hubben laver et tilfældigt id ved første start og sender: Hub-version, macOS-version, arkitektur, hvilke LINE21-versioner og hvilken Resolve-version der er installeret, og hver download, opdatering, fejl (med en kort fejlkode) og tilbagerulning. Ingen navne, e-mails, filer, projekter eller IP-adresser. Kan slås fra under Indstillinger. `/admin` viser aktive Hubs pr. dag, downloads og installationer pr. version, hvad folk har installeret lige nu, fejl og Resolve/macOS-versioner.

## Udvikling

```sh
npm install && npm test            # API og katalog
npm run dev                        # API på :8080 med det lokale katalog
cd app && swift test               # Hubbens kerne (versioner, signatur)
PUBLIC_KEY=… app/scripts/build-app.sh   # app/dist/LINE21 Hub.app
```
