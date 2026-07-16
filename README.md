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
| `AUTO_UPDATE` | Hent nyeste YOURLS ved hver opstart | `false` |
| `YOURLS_LANG` | Sprog, fx `da_DK` (kræver `.mo`-fil i `user/language`) | *(engelsk)* |
| `YOURLS_URL_CONVERT` | Nøgleformat: `36` (små bogstaver) / `62` (blandet) | `36` |

Databasen konfigureres automatisk — der er ingen DB-variabler at udfylde.

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
