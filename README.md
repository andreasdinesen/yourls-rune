# YOURLS som yggdrasil-rune

[YOURLS](https://yourls.org) (Your Own URL Shortener) pakket som en **rune** til
[yggdrasil](https://github.com/kristianwind/yggdrasil) — med **indbygget database**
og **automatiske opdateringer**.

Hele opsætningen sker direkte i yggdrasil-interfacet: sæt admin-bruger og
-adgangskode, tryk Start, og log ind på `/admin/`. Ingen separat database-rune, ingen
manuel indtastning af host/port.

## Hvad gør denne rune anderledes

En yggdrasil-rune er normalt ét enkelt container, og fællesskabets `wordpress`-rune
kræver derfor at man selv opretter en MariaDB-rune og finder dens LAN-IP og
tilfældigt tildelte port. Denne rune undgår det ved at pakke **YOURLS + MariaDB +
supervisor i ét image**:

- **Database indbygget** — MariaDB kører inde i containeren; data ligger i `/data`.
- **Opsætning i interfacet** — admin-bruger, adgangskode, sprog m.m. som
  rune-variabler.
- **Auto-detekteret URL** — `YOURLS_SITE` udledes fra den adresse du tilgår den på,
  så den virker på den tilfældige port yggdrasil tildeler (og bag en reverse proxy).
- **Automatiske opdateringer** — se nedenfor.

## Installation i yggdrasil

1. **Runes → Browse runes on GitHub**
   - Repository: `andreasdinesen/yourls-rune`
   - Folder: `runes`
2. Vælg **YOURLS** → udfyld mindst **Admin-brugernavn** og **Admin-adgangskode**.
3. **Install** → **Start**. (Install-loggen streamer ikke live i yggdrasil — genindlæs
   siden og se at knappen skifter til "Start".)
4. Åbn den tildelte port og log ind på **`/admin/`**.

## Variabler

| Variabel | Betydning | Standard |
|---|---|---|
| `YOURLS_USER` | Admin-brugernavn | `admin` |
| `YOURLS_PASS` | Admin-adgangskode (skjult) | *(påkrævet)* |
| `YOURLS_SITE` | Site-URL. Tom = auto-detektér (brug den tildelte port). Se [Eget domæne](#eget-domæne-bag-reverse-proxy) | *(tom)* |
| `YOURLS_PRIVATE` | Kræv login for at oprette links | `true` |
| `AUTO_UPDATE` | Hent nyeste YOURLS (og opdatér plugins) ved hver opstart | `false` |
| `YOURLS_VERSION` | Pin/manuel opdatering til præcis version, se [Manuel opdatering](#manuel-opdatering-og-versionsvisning) | *(tom = imagets)* |
| `QR_CODE` | QR-koder: `.qr` på en kort-URL, se [QR-koder](#qr-koder) | `false` |
| `PLUGINS` | Plugins at installere, se [Plugins](#plugins) | *(tom)* |
| `YOURLS_LANG` | Sprog, fx `da_DK` (kræver `.mo`-fil i `user/language`) | *(engelsk)* |
| `YOURLS_URL_CONVERT` | Nøgleformat: `36` (små bogstaver) / `62` (blandet) | `36` |

Databasen konfigureres automatisk — der er ingen DB-variabler at udfylde.

## Manuel opdatering og versionsvisning

Vil du selv styre hvornår YOURLS opdateres — fx for at kunne tage en backup først —
så lad `AUTO_UPDATE` være **slået fra** og brug `YOURLS_VERSION`:

1. Se status i **Console**-loggen eller i filen **`YOURLS-VERSION.txt`** under **Files**.
   Den viser kørende version, imagets version og nyeste udgivelse, og råber op hvis
   der er en ny version. Opdateres ved hver genstart.
2. **Tag en backup** under **Backups**-fanen.
3. Skriv den ønskede version i `YOURLS_VERSION` (fx `1.10.5`) og tryk **Restart**.
4. Beder YOURLS om det, så kør `/admin/upgrade.php` én gang.

Går opgraderingen galt: **gendan backuppen** og sæt `YOURLS_VERSION` tilbage til den
gamle version (databasen ligger i backuppen; en ren nedgradering af koden uden
gendannelse kan give versions-mismatch mod databasen).

- `YOURLS_VERSION` **vinder over** `AUTO_UPDATE` — sat betyder "kør præcis denne".
- Tom `YOURLS_VERSION` = kør imagets version (som auto-bumpes af den daglige
  GitHub Action, se ovenfor).
- Panelets settings-formular kan kun vise statisk tekst, så den *live* versionsstatus
  bor i Console/Files. YOURLS' egen admin viser også versionen i bunden af hver side
  og et banner når en ny version findes.

## QR-koder

Slå **`QR_CODE`** til og tryk Restart. Så giver `.qr` på enhver kort-URL dens QR-kode:

```
https://kort.dit-domæne.dk/abc      → dit link
https://kort.dit-domæne.dk/abc.qr   → QR-kode for linket
```

Det er YOURLS' eget eksempel-plugin
([docs](https://yourls.org/docs/development/examples/qrcode)), som er lagt ind i imaget.

**Vær opmærksom på:** QR-billedet genereres ikke lokalt. Brugeren sendes videre til
`api.qrserver.com` (GoQR), som ifølge deres vilkår logger **IP og referrer** (men ikke
selve QR-dataen), med en grænse på 10.000 forespørgsler pr. dag. QR-koder virker derfor
ikke uden internetadgang. Vil du undgå tredjepart, så find et plugin der tegner koden
lokalt via `PLUGINS` nedenfor.

I modsætning til `PLUGINS` **aktiverer** denne toggle også pluginet — den er en
funktions-kontakt, så den håndhæves ved hver opstart. Slår du QR fra i yggdrasil,
deaktiveres det; deaktiverer du det manuelt under Manage Plugins mens toggle'en står
til, aktiveres det igen ved næste genstart. Dine øvrige plugins røres ikke.

## Plugins

YOURLS har ingen indbygget plugin-installer — et plugin er blot en mappe med en
`plugin.php` i `user/plugins/`. Runen kan hente dem for dig:

Skriv GitHub-repos i **`PLUGINS`**, adskilt med komma:

```
YOURLS/antispam, MatthewC/yourls-2fa-support
```

Tryk **Restart**, gå til **Manage Plugins** i YOURLS-admin og **aktivér** dem.

- Find plugins på [github.com/YOURLS/awesome](https://github.com/YOURLS/awesome) (259 stk.).
- Vil du have en bestemt version/branch: `YOURLS/antispam@master`.
- Runen **aktiverer aldrig** et plugin automatisk — det er dit valg, og aktivering
  gemmes i databasen.
- Allerede installerede plugins røres ikke ved genstart. Slår du `AUTO_UPDATE` til,
  hentes de forfra hver opstart (så de følger med opstrøms).
- Fejler en download (fx forkert navn), logges det og YOURLS starter alligevel.

### Fjerne et plugin

Slet det fra `PLUGINS` og tryk **Restart** — så afinstalleres det. Var det aktiveret,
opdager YOURLS selv at filerne er væk og fjerner det fra listen over aktive plugins.

Runen sætter en skjult `.rune-installed`-fil i de mapper den selv installerer, og rører
**kun** dem. YOURLS' egne medfølgende plugins (Sample Plugin, YOURLS Toolbar, Random
Backgrounds m.fl.) og alt du selv har uploadet via **Files**, bliver aldrig slettet.

Plugins installeret før rune v6 mangler den markering, så dem skal du fjerne én gang
manuelt under **Files** → `/data/user/plugins/<mappe>`. Derefter klarer `PLUGINS` det.

Plugins ligger i `/data/user/plugins/` og overlever opdateringer. Du kan også lægge
dem manuelt der via yggdrasils **Files**-fane — fx et plugin der ikke er på GitHub.

## Eget domæne bag reverse proxy

**`YOURLS_SITE` opretter ikke domænet** — det fortæller kun YOURLS hvad dens egen adresse
er. Sæt det først når DNS og en reverse proxy rent faktisk peger på containeren, ellers
låser du dig ude: YOURLS ser en `https`-adresse, opdager at forbindelsen ikke er https, og
redirecter til en adresse der ikke svarer.

Rækkefølge der virker:

1. Lad `YOURLS_SITE` stå **tom**, tryk Start, og bekræft at YOURLS virker på den tildelte
   port.
2. Peg DNS for dit domæne på serveren.
3. Sæt en reverse proxy op (fx `nginx-proxy-manager`-runen): proxy host `kort.dit-domæne.dk`
   → serverens IP + YOURLS-containerens tildelte port. Slå SSL til.
4. Sæt nu `YOURLS_SITE` = `https://kort.dit-domæne.dk` og tryk **Restart**.

Runen håndterer selv proxy-opsætningen: den stoler på `X-Forwarded-Proto`/`X-Forwarded-Host`,
så YOURLS ved at den oprindelige forespørgsel var https. Uden det ville YOURLS redirecte til
https i en uendelig løkke (proxyen sender den videre som http igen). Skriver du et bart
domæne uden `https://` foran, sættes det automatisk på.

## Automatiske opdateringer

**To lag, begge sikre** (dine links, plugins og config i `/data` røres aldrig af en
opgradering):

1. **Auto-build (standard).** En daglig GitHub Action tjekker YOURLS' releases; ved en
   ny version bumpes `Dockerfile` + rune-`version:`, og et nyt image bygges og pushes
   til GHCR. Et **ugentligt** rebuild henter desuden base-imagets sikkerhedsrettelser.
   Tryk **Restart** i yggdrasil for at hente den nye version. Versionen er
   reproducerbar og kan rulles tilbage.

2. **`AUTO_UPDATE` (valgfri).** Slås checkboxen til, henter containeren selv nyeste
   YOURLS fra GitHub ved hver opstart. Ingen ventetid på et image-build, men versionen
   er ikke reproducerbar. Efter en større opdatering kan YOURLS bede om at køre
   `/admin/upgrade.php` én gang.

Webroot'en lægges frisk fra imaget ved hver opstart, så **et nyere image = nyere
YOURLS-kerne automatisk**. Kun `user/` (config, plugins, sider) og databasen er
persistente.

## Data og backup

Alt persistent ligger i `/data`:

```
/data/mysql/       MariaDB-datafiler
/data/user/        YOURLS user/ (config.php, config-extra.php, plugins, pages)
/data/secrets/     db-password, cookiekey (genereret én gang, stabile)
/data/db-dump/     yourls.sql — konsistent mysqldump hver 6. time
/data/cache/       hentede YOURLS-tarballs (AUTO_UPDATE)
```

Runens `backup` arkiverer hele `/data`. Fordi rå MariaDB-filer kan være
inkonsistente hvis de kopieres mens serveren kører, ligger der altid et friskt
`db-dump/yourls.sql` at gendanne fra.

Egne PHP-indstillinger, der skal overleve opdateringer, lægges i
`/data/user/config-extra.php` (inkluderes automatisk; overskrives aldrig).
`config.php` regenereres ved hver opstart og skal ikke redigeres.

## Lokal test (kræver Docker)

```bash
docker build -t yourls-rune .
docker run --rm -p 8080:8080 -v "$PWD/data:/data" \
  -e YOURLS_USER=admin -e YOURLS_PASS=test1234 yourls-rune
# → http://localhost:8080/admin/
```

CI kører automatisk en tilsvarende ende-til-ende-røgtest (start container, tjek at
`/admin/` kræver login, og at tabellerne blev oprettet) før hvert image publiceres.

## Vedligeholdelse

Bump `version:` i [`runes/yourls.yaml`](runes/yourls.yaml) ved **hver** ændring af
rune-filen eller imaget — ellers cacher yggdrasil den gamle rune. `check-upstream`
gør det automatisk ved YOURLS-releases.

## Arkitektur

| Fil | Rolle |
|---|---|
| `Dockerfile` | `FROM yourls:<version>-apache` + MariaDB + supervisor |
| `rune-entrypoint.sh` | Env/secrets/webroot/DB-init + valgfri self-update → supervisord |
| `run-mariadb.sh` | MariaDB på 127.0.0.1 (data i `/data/mysql`) |
| `start-apache.sh` | Venter på DB, opretter DB+bruger, installerer tabeller, kører Apache |
| `yourls-install.php` | Opretter YOURLS-tabeller via YOURLS' egen install-API (idempotent) |
| `db-dump.sh` | Periodisk `mysqldump` til backup-konsistens |
| `config-container.php` | Env-drevet config med auto-detekteret `YOURLS_SITE` |
| `supervisord.conf` | Supervisorer mariadb / apache / db-dump |
| `runes/yourls.yaml` | Selve runen |
| `.github/workflows/` | `build` (multi-arch → GHCR + røgtest), `check-upstream` (dagligt) |
