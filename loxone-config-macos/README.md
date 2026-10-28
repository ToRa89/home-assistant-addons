# Loxone Config auf macOS (Wine)

Loxone Config gibt es nur für Windows. Dieses Skript richtet auf dem Mac eine eigene Wine-Umgebung ein, installiert die nötigen Laufzeiten und Schriften, spielt Loxone Config ein und legt einen Starter im Ordner „Programme“ (`/Applications`) an, ohne Schreibrecht dort in `~/Applications`. Updates von Wine, winetricks und Loxone Config laufen über einen Befehl.

Loxone selbst unterstützt Wine offiziell nicht. Wer eine garantiert funktionierende Lösung braucht, nimmt eine Windows-VM (Parallels, VMware Fusion, UTM). Diese Lösung ist für den Alltag gedacht, in dem man ohne VM schnell eine Konfiguration öffnen, ändern und speichern will.

## Warum diese Bausteine

Wine kommt aus den Builds von Gcenx (`github.com/Gcenx/macOS_Wine_builds`). Das sind die Builds, auf die früher das Homebrew-Cask `wine-stable` gezeigt hat. Homebrew hat dieses Cask zum 1. September 2026 abgeschaltet, weil es die Gatekeeper-Notarisierung nicht besteht. Das Skript lädt die Builds deshalb direkt und legt sie in einem eigenen Ordner ab. So ist es unabhängig von Homebrew-Casks und von einer systemweiten Wine-Installation.

Whisky ist seit April 2025 eingestellt und bleibt auf Wine 7.7 stehen. Für Loxone Config 17 reicht das nicht, weil die Version 64-Bit-Wine braucht.

CrossOver (CodeWeavers, kostenpflichtig) ist die bequemere Alternative mit Support. Die Skript-Schritte lassen sich dort sinngemäß nachbauen: Flasche Windows 10 64 Bit, dann „Visual C++ 2015-2022“ und „Core Fonts“ installieren.

## Was installiert wird

| Baustein | Zweck |
|---|---|
| Rosetta 2 (nur Apple Silicon) | Die Wine-Builds sind x86_64 |
| cabextract (Homebrew-Formel) | Wird von winetricks für Schriften und VC++ gebraucht |
| Wine (Gcenx, Kanal stable, Rückfall auf devel) | Laufzeitumgebung, enthält Wine-Mono und Wine-Gecko |
| winetricks (aktuelle Version) | Installiert Laufzeiten und Schriften in den Prefix |
| vcrun2022 | Visual C++ 2015-2022 Laufzeit, Loxone Config 17 braucht `mfc140u.dll` |
| corefonts, tahoma | Arial, Verdana, Times, Courier New, Tahoma u.a. |
| fontsmooth=rgb | Subpixel-Glättung, sonst wirkt Text pixelig |
| Schrift-Ersetzungen | Segoe UI, MS Shell Dlg und MS Sans Serif zeigen auf Tahoma |
| Mac-Treiber-Optionen | Cmd wirkt als Strg (Cmd+C, Cmd+V, Cmd+S), Retina optional |
| Loxone Config | Aktueller Installer von der Loxone-Download-Seite |

Ein .NET Framework wird nicht installiert. Nach den Erfahrungen aus dem Projekt `lian/docker-loxone-config` (Loxone Config 17.2 unter Wine 11 auf Linux) braucht Loxone Config 17 zur Laufzeit die VC++-Laufzeit mit `mfc140u.dll` und bringt eine eigene Qt-WebEngine mit. Eine .NET-Abhängigkeit ist dort nicht aufgefallen, für eventuelle Reste reicht das mitgelieferte Wine-Mono.

Alles liegt unter `~/Library/Application Support/LoxoneConfigMac`. Projektdateien speichert man am besten außerhalb davon, zum Beispiel in `~/Documents`, der Ordner ist in Wine als Laufwerk `Z:` sichtbar.

## Installation

Voraussetzungen: macOS 15 oder neuer (Loxone verlangt das ab Frühjahr 2026), Homebrew für cabextract.

```bash
git clone https://github.com/tora89/home-assistant-addons.git
cd home-assistant-addons/loxone-config-macos
./loxone-config.sh install
```

Während der Installation öffnet sich der Loxone-Installer als Windows-Fenster. Durchklicken und den Zielpfad nicht ändern. Danach liegt „Loxone Config“ im Ordner „Programme“ und lässt sich ins Dock ziehen. Den Ort zeigt `./loxone-config.sh doctor` in der Zeile „App-Starter“.

Findet das Skript den Download-Link nicht, weil Loxone die Seite umgebaut hat, den Installer im Browser laden und so einspielen:

```bash
LXC_SETUP_FILE=~/Downloads/LoxoneConfigSetup_17020828.zip ./loxone-config.sh update-loxone
```

## Updates

```bash
./loxone-config.sh update
```

Das aktualisiert winetricks, lädt eine neuere Wine-Version (die vorherige bleibt als Rückfallebene liegen) und spielt eine neuere Loxone-Config-Version ein. Der Prefix mit allen Einstellungen bleibt erhalten. Einzeln geht es mit `update-wine` und `update-loxone`.

Loxone Config meldet neue Versionen auch selbst beim Start. Diese Meldung kann man nutzen, sicherer ist aber der Weg über das Skript, weil es danach den Prefix und den Starter prüft.

Geht nach einem Wine-Update etwas kaputt, lässt sich auf die vorherige Version zurückschalten:

```bash
cd ~/Library/Application\ Support/LoxoneConfigMac/wine
ls
ln -sfn "$PWD/devel-11.17" current
```

## Weitere Befehle

| Befehl | Wirkung |
|---|---|
| `run` | Loxone Config starten (das macht auch die App) |
| `doctor` | Versionen und Bausteine prüfen |
| `fonts` | Schriften erneut einrichten |
| `app` | Starter neu erzeugen, optional mit `AppIcon.icns` neben dem Skript |
| `winecfg` | Wine-Einstellungen für diesen Prefix |
| `uninstall` | Alles entfernen |

Einstellungen per Umgebungsvariable:

| Variable | Standard | Bedeutung |
|---|---|---|
| `LXC_WINE_CHANNEL` | `stable` | `stable`, `devel` oder `staging` |
| `LXC_SETUP_FILE` | leer | Lokale Installer-Datei (.zip oder .exe) |
| `LXC_SETUP_URL` | leer | Direkter Download-Link auf den Installer |
| `LXC_CMD_IS_CTRL` | `y` | Cmd-Taste als Strg |
| `LXC_RETINA` | `n` | `y` für volle Retina-Auflösung, die Oberfläche wird dann kleiner |

Die App schreibt ihre Ausgaben nach `~/Library/Application Support/LoxoneConfigMac/logs/app.log`. Für Fehlersuche hilft `WINEDEBUG=err+all ./loxone-config.sh run`.

## Bekannte Grenzen

Die Miniserver-Suche im Netzwerk (UDP-Broadcast) kann unter Wine scheitern. Dann die IP-Adresse oder den Remote-Connect-Namen direkt eingeben.

Die Anmeldung mit dem Loxone-Konto über das eingebettete Browserfenster ist unter Wine nicht verlässlich getestet. Das Skript setzt `QTWEBENGINE_CHROMIUM_FLAGS=--no-sandbox`, damit das Fenster überhaupt startet.

Beim ersten Start kann die Titelleiste mit Speichern-Knopf und Tabs abgeschnitten sein. Fenster einmal maximieren oder verschieben behebt das in der Regel.

Rosetta 2 ist eine Abhängigkeit mit Ablaufdatum. Apple hat angekündigt, Rosetta nach macOS 27 nur noch eingeschränkt anzubieten. Sobald es native arm64-Builds von Wine für macOS gibt, wird das Skript darauf umgestellt werden müssen.
