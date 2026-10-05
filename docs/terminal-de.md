# Socket Manager – Terminalversion

Reines Python 3, keine Dependencies (`curses` + `lsof` + `ps` aus dem System).

```
 socketmanager · 5 web servers · sort port · 2 marked · 4 hidden (a)
    PORT     PID  PROCESS            PROJECT            BY               UP  HTTP  INFO
    8933    7370  Webex                                 orphan       12m44s  tcp   [all interfaces] /Applications/…
 ▸  9931    8409  python http.server proj-alpha         orphan        0m54s  HTTP  200 Directory listing for /
 ▸  9932    8411  python http.server proj-alpha         orphan        0m54s  HTTP  200 Directory listing for /
    9934    8415  python -c          preview            orphan        0m54s  HTTP  [ipv6] 200 Agent Preview
```

## Start

```sh
./socketmanager.py                     # TUI
./socketmanager.py -l                  # einmal auflisten
./socketmanager.py --json              # maschinenlesbar
./socketmanager.py -a                  # auch nicht-Web-Sockets
./socketmanager.py --watch             # meldet neue Server per Notification
./socketmanager.py --stop 8777,9000    # Ports ohne TUI freimachen
```

Praktisch als Alias in `~/.zshrc`:

```sh
alias srv='"'"$PWD"'/socketmanager.py"'
```

## Tasten

| Taste | Wirkung |
|-------|---------|
| `↑` `↓` / `j` `k` | navigieren (`PgUp/PgDn`, `Home/End`) |
| `⏎` / `c` | URL öffnen / in die Zwischenablage |
| `s` | stoppen: SIGTERM, nach 2 s automatisch SIGKILL |
| `K` | sofort SIGKILL |
| `t` | Prozessbaum stoppen (Kinder + ggf. Supervisor-Parent) |
| `space` | markieren (springt eine Zeile weiter) |
| `v` / `m` / `u` | alle sichtbaren / alle mit gleichem Projekt / keine markieren |
| `S` | alle markierten stoppen |
| `/` | suchen (Port, Prozess, Projekt, cwd, Titel) |
| `o` | Sortierung: port → uptime → project → process |
| `a` | alle Sockets ⇄ nur Webserver |
| `p` | HTTP-Probe an/aus |
| `r` | sofort neu laden |
| `?` | Tastenübersicht |
| `q` | beenden |

Vier vergessene Server aus derselben Session bist du damit in drei Anschlägen
los: `m` (alle mit gleichem Projekt markieren), `S`, `y`.

## Aufräumen von der Kommandozeile

```sh
./socketmanager.py --stop-all --cwd netdash          # alles aus einem Projekt
./socketmanager.py --stop-all --older-than 3d        # alles, was ewig läuft
./socketmanager.py --stop-all --older-than 2h -y     # ohne Rückfrage
```

Ohne `-y` wird erst die Trefferliste gezeigt und nachgefragt. `--older-than`
versteht `30s`, `15m`, `2h`, `3d`.

## Watch-Modus

```sh
./socketmanager.py --watch --interval 5
nohup ./socketmanager.py --watch > ~/socketmanager-watch.log 2>&1 &
```

Meldet jeden neu auftauchenden Server per macOS-Notification (bzw.
`notify-send` unter Linux) und schreibt eine Zeile pro Ereignis:
`·` Bestand beim Start, `+` neu, `-` verschwunden.

## Was die Spalten bedeuten

- **PROCESS** – der Prozess, dem der Socket gehört. Bei Containern
  `docker <name>`.
- **PROJECT** – woher der Server kommt: Name des Git-Repos oberhalb des
  Arbeitsverzeichnisses, sonst das Verzeichnis selbst. Details (Unterordner,
  Agent-Scratchpad, Container) stehen im Detailbereich und in der INFO-Spalte.
- **BY** – der Elternprozess. Bei Agent-Servern steht dort meist `orphan`: im
  Hintergrund gestartet, die aufrufende Shell ist beendet, `launchd` hat den
  Prozess adoptiert. Wer ihn gestartet hat, verrät dann **PROJECT**/**cwd**.
- **UP** – Laufzeit (`12d18h`, `21h26m`, `3m12s`).
- **HTTP** – Ergebnis eines kurzen `GET /` (Timeout 0,4 s, Cache 30 s):
  `HTTP` = echter Webserver, `TLS` = spricht HTTPS, `tcp` = kein HTTP,
  `-` = nimmt nichts an. Mit `p` bzw. `--no-probe` abschaltbar.
- **INFO** – `<title>` der Startseite, sonst `Server:`-Header, sonst die Herkunft.
- **`[all interfaces]`** (gelb) – lauscht nicht nur auf localhost, ist also im
  LAN erreichbar. **`[ipv6]`** – nur über `::1` erreichbar.

## Filter

Standardmäßig werden nur Webserver gezeigt: Sockets auf localhost/allen
Interfaces, bei denen entweder die HTTP-Probe anschlägt, der Port typisch ist
(3000–3100, 8000–8999, 5173, 4200 …) oder das Kommando nach Dev-Server aussieht
(node, python, uvicorn, vite, caddy …). Bekanntes Systemrauschen (rapportd,
OneDrive, Dropbox …) fliegt raus. `a` zeigt alles.

## Sicherheitsnetze

- Prozesse aus der eigenen Prozesskette (dieses Tool, die Shell, das Terminal)
  werden nie signalisiert.
- Docker: veröffentlichte Container-Ports werden dem Container zugeordnet und
  über `docker stop` beendet. Der Docker-Daemon selbst wird nie signalisiert.
- Jeder Kill wird bestätigt; gepufferte Tastendrücke werden vorher verworfen,
  damit eine gedrückt gehaltene Taste nichts bestätigt.
- `t` nimmt den Elternprozess nur mit, wenn er ein Supervisor ist
  (`npm`/`yarn`/`bun`/`nodemon`/`bash -c` …) – sonst würde er den Server
  sofort neu starten.
- Jeder Stopp landet mit Zeitstempel, Port, PID und Projekt in
  `~/.local/state/socketmanager.log`.
- `lsof` zeigt ohne `sudo` nur deine eigenen Prozesse; fremde Ports melden beim
  Stoppen "no permission".

## Bekannte Grenzen

- Nur lauschende TCP-Sockets (kein UDP, keine Unix-Sockets).
- Der Docker-Pfad ist gegen eine simulierte `docker ps`-Ausgabe getestet, ein
  echtes `docker stop` noch nicht (Daemon lief hier nicht).
- `--watch` pollt; ein Server, der zwischen zwei Durchläufen startet und wieder
  endet, wird nicht gemeldet.
