#!/bin/bash
# Loxone Config auf macOS: Wine-Umgebung installieren, aktualisieren und starten.
#
# Nutzung: ./loxone-config.sh <befehl>
#   install         Alles einrichten: Wine, Prefix, Laufzeiten, Schriften, Loxone Config, App-Starter
#   run             Loxone Config starten
#   update          Wine, winetricks und Loxone Config aktualisieren (nur wenn neuer)
#   update-wine     Nur Wine aktualisieren
#   update-loxone   Nur Loxone Config aktualisieren
#   fonts           Schriften und Schriftglaettung erneut einrichten
#   app             App-Starter "Loxone Config.app" in ~/Applications neu erzeugen
#   doctor          Umgebung pruefen und Versionen anzeigen
#   winecfg         Wine-Konfiguration fuer den Loxone-Prefix oeffnen
#   uninstall       Alles entfernen (fragt vorher nach)
#
# Bewusst kompatibel mit dem macOS-Standard-Bash 3.2 (keine assoziativen Arrays, kein mapfile).

set -euo pipefail

# ---------------------------------------------------------------------------
# Einstellungen (per Umgebungsvariable ueberschreibbar)
# ---------------------------------------------------------------------------
BASE_DIR="${LXC_BASE_DIR:-$HOME/Library/Application Support/LoxoneConfigMac}"
WINE_CHANNEL="${LXC_WINE_CHANNEL:-stable}"          # stable | devel | staging
WINE_RELEASES_API="https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=40"
WINETRICKS_URL="https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
LOXONE_DOWNLOAD_PAGE="${LXC_DOWNLOAD_PAGE:-https://www.loxone.com/dede/support/downloads/}"
LOXONE_SETUP_URL="${LXC_SETUP_URL:-}"               # direkter Link auf LoxoneConfigSetup_*.zip, optional
LOXONE_SETUP_FILE="${LXC_SETUP_FILE:-}"             # lokale .zip oder .exe, optional
LOXONE_SETUP_ARGS="${LXC_SETUP_ARGS:-}"             # zusaetzliche Installer-Argumente, optional
# Starter landet im Finder-Ordner "Programme" (/Applications), sonst im persoenlichen ~/Applications.
if [ -n "${LXC_APP_DIR:-}" ]; then
    APP_DIR="$LXC_APP_DIR"
elif [ -w /Applications ]; then
    APP_DIR="/Applications"
else
    APP_DIR="$HOME/Applications"
fi
CMD_IS_CTRL="${LXC_CMD_IS_CTRL:-y}"                 # Cmd-Taste als Strg (Cmd+C/V/S)
RETINA_MODE="${LXC_RETINA:-n}"                      # y = volle Retina-Aufloesung (kleinere UI)

WINE_ROOT="$BASE_DIR/wine"
WINEPREFIX="$BASE_DIR/prefix"
CACHE_DIR="$BASE_DIR/cache"
STATE_DIR="$BASE_DIR/state"
LOG_DIR="$BASE_DIR/logs"
WINETRICKS="$BASE_DIR/bin/winetricks"
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

export WINEPREFIX
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
# Loxone Config 17+ bringt QtWebEngine (Chromium) mit, dessen Sandbox laeuft unter Wine nicht.
export QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS:---no-sandbox}"
# Wine-Mono/Gecko-Dialoge beim ersten Start unterdruecken, beides bringt der Gcenx-Build mit.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarnung:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

state_get() { [ -f "$STATE_DIR/$1" ] && cat "$STATE_DIR/$1" || true; }
state_set() { mkdir -p "$STATE_DIR"; printf '%s\n' "$2" > "$STATE_DIR/$1"; }

fetch() {
    # fetch <url> <ziel>
    curl -fL --retry 3 --retry-delay 2 -A "Mozilla/5.0 (Macintosh) LoxoneConfigMac" -o "$2" "$1"
}

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "Dieses Skript ist fuer macOS gedacht."
}

require_rosetta() {
    # Die Wine-Builds sind x86_64. Auf Apple Silicon braucht es Rosetta 2.
    if [ "$(uname -m)" = "arm64" ]; then
        if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
            log "Rosetta 2 fehlt, wird installiert (Bestaetigung der Lizenz noetig)"
            /usr/sbin/softwareupdate --install-rosetta
        fi
    fi
}

require_cabextract() {
    # winetricks braucht cabextract fuer Schriften und VC++-Pakete.
    if command -v cabextract >/dev/null 2>&1; then return; fi
    if command -v brew >/dev/null 2>&1; then
        log "cabextract fehlt, installiere ueber Homebrew"
        brew install cabextract
    else
        die "cabextract fehlt. Homebrew installieren (https://brew.sh) und 'brew install cabextract' ausfuehren."
    fi
}

wine_bin_dir() {
    [ -L "$WINE_ROOT/current" ] || [ -d "$WINE_ROOT/current" ] || return 1
    local app
    app="$(find "$WINE_ROOT/current/" -maxdepth 1 -name '*.app' -type d | head -1)"
    [ -n "$app" ] || return 1
    printf '%s\n' "$app/Contents/Resources/wine/bin"
}

setup_wine_env() {
    local bindir
    bindir="$(wine_bin_dir)" || die "Wine ist nicht installiert. Zuerst '$0 install' ausfuehren."
    if [ -x "$bindir/wine" ]; then
        WINE="$bindir/wine"
    elif [ -x "$bindir/wine64" ]; then
        WINE="$bindir/wine64"
    else
        die "Kein Wine-Binary in $bindir gefunden."
    fi
    WINESERVER="$bindir/wineserver"
    export WINE WINESERVER
    export PATH="$bindir:$PATH"
}

wine_run() { "$WINE" "$@"; }

wait_wineserver() { "$WINESERVER" -w 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Wine
# ---------------------------------------------------------------------------
latest_wine_asset() {
    # Gibt "<kanal>-<version> <download-url>" aus.
    local json urls url
    json="$(curl -fsSL "$WINE_RELEASES_API")" || die "GitHub-API fuer Wine-Builds nicht erreichbar."
    urls="$(printf '%s\n' "$json" \
        | grep -oE '"browser_download_url": *"[^"]+"' \
        | sed -E 's/.*"(https[^"]+)"/\1/')"
    url="$(printf '%s\n' "$urls" | grep -E "/wine-${WINE_CHANNEL}-[0-9][^/]*-osx64\.tar\.xz$" | head -1 || true)"
    if [ -z "$url" ] && [ "$WINE_CHANNEL" = "stable" ]; then
        # Stable-Builds erscheinen nur einmal im Jahr und koennen aus der Liste fallen.
        warn "Kein aktueller Stable-Build gefunden, nehme den Devel-Kanal."
        WINE_CHANNEL=devel
        url="$(printf '%s\n' "$urls" | grep -E "/wine-devel-[0-9][^/]*-osx64\.tar\.xz$" | head -1 || true)"
    fi
    [ -n "$url" ] || die "Kein Wine-Build fuer Kanal '$WINE_CHANNEL' gefunden."
    printf '%s-%s %s\n' "$WINE_CHANNEL" "$(basename "$url" | sed -E "s/^wine-${WINE_CHANNEL}-(.+)-osx64\.tar\.xz$/\1/")" "$url"
}

install_wine() {
    local force="${1:-}" info version url target archive current previous
    info="$(latest_wine_asset)"
    version="${info%% *}"
    url="${info#* }"
    current="$(state_get wine_version)"

    if [ "$force" != "force" ] && [ "$current" = "$version" ] && wine_bin_dir >/dev/null; then
        log "Wine $version ist aktuell."
        return 1
    fi

    log "Lade Wine $version"
    target="$WINE_ROOT/$version"
    archive="$CACHE_DIR/$(basename "$url")"
    mkdir -p "$WINE_ROOT" "$CACHE_DIR"
    [ -f "$archive" ] || fetch "$url" "$archive"

    rm -rf "$target.tmp"
    mkdir -p "$target.tmp"
    tar -xJf "$archive" -C "$target.tmp"
    # Downloads per curl tragen normalerweise kein Quarantaene-Attribut, sicher ist sicher.
    xattr -dr com.apple.quarantine "$target.tmp" 2>/dev/null || true
    rm -rf "$target"
    mv "$target.tmp" "$target"
    previous="$(readlink "$WINE_ROOT/current" 2>/dev/null || true)"
    ln -sfn "$target" "$WINE_ROOT/current"
    state_set wine_version "$version"

    # Aeltere Wine-Versionen aufraeumen, die zuletzt genutzte bleibt als Rueckfallebene.
    find "$WINE_ROOT" -mindepth 1 -maxdepth 1 -type d -print | while IFS= read -r old; do
        [ "$old" = "$target" ] && continue
        [ -n "$previous" ] && [ "$old" = "$previous" ] && continue
        log "Entferne alte Wine-Version $(basename "$old")"
        rm -rf "$old"
    done
    rm -f "$archive"
    return 0
}

install_winetricks() {
    log "Lade aktuelles winetricks"
    mkdir -p "$BASE_DIR/bin"
    fetch "$WINETRICKS_URL" "$WINETRICKS.tmp"
    chmod +x "$WINETRICKS.tmp"
    mv "$WINETRICKS.tmp" "$WINETRICKS"
}

winetricks_q() {
    WINETRICKS_LATEST_VERSION_CHECK=disabled "$WINETRICKS" -q --unattended "$@"
}

# ---------------------------------------------------------------------------
# Prefix, Laufzeiten, Schriften
# ---------------------------------------------------------------------------
init_prefix() {
    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        log "Lege Wine-Prefix an: $WINEPREFIX"
        mkdir -p "$WINEPREFIX"
        wine_run wineboot --init >/dev/null 2>&1
    else
        log "Aktualisiere Wine-Prefix auf die installierte Wine-Version"
        wine_run wineboot --update >/dev/null 2>&1
    fi
    wait_wineserver
    winetricks_q win10
}

install_runtimes() {
    # Loxone Config 17 braucht mfc140u.dll aus dem VC++-2015-2022-Paket.
    # Die .NET-Laufzeit braucht Loxone Config nicht, Wine-Mono reicht fuer Reste.
    log "Installiere Visual C++ 2015-2022 Laufzeit (vcrun2022)"
    winetricks_q vcrun2022
}

install_fonts() {
    log "Installiere Windows-Kernschriften (Arial, Verdana, Tahoma, Courier New u.a.)"
    winetricks_q corefonts tahoma
    log "Aktiviere Schriftglaettung (Subpixel RGB)"
    winetricks_q fontsmooth=rgb

    # Segoe UI und Microsoft Sans Serif gibt es nicht frei. Ohne Ersatz faellt Wine auf
    # Bitmap-Schriften zurueck, das erzeugt verschobene und abgeschnittene Beschriftungen.
    log "Setze Schrift-Ersetzungen fuer Segoe UI und MS Shell Dlg"
    local reg="$CACHE_DIR/fonts.reg"
    mkdir -p "$CACHE_DIR"
    cat > "$reg" <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]
"Segoe UI"="Tahoma"
"Segoe UI Semibold"="Tahoma"
"Segoe UI Light"="Tahoma"
"Microsoft Sans Serif"="Tahoma"
"MS Sans Serif"="Tahoma"
"MS Shell Dlg"="Tahoma"
"MS Shell Dlg 2"="Tahoma"

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]
"MS Shell Dlg"="Tahoma"
"MS Shell Dlg 2"="Tahoma"
"Segoe UI"="Tahoma"
EOF
    wine_run regedit /S "$reg" >/dev/null 2>&1
    wait_wineserver
}

apply_mac_settings() {
    log "Setze macOS-Treiberoptionen (Cmd als Strg: $CMD_IS_CTRL, Retina: $RETINA_MODE)"
    local reg="$CACHE_DIR/mac.reg"
    mkdir -p "$CACHE_DIR"
    cat > "$reg" <<EOF
REGEDIT4

[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
"LeftCommandIsCtrl"="$CMD_IS_CTRL"
"RightCommandIsCtrl"="$CMD_IS_CTRL"
"RetinaMode"="$RETINA_MODE"
EOF
    wine_run regedit /S "$reg" >/dev/null 2>&1
    wait_wineserver
}

# ---------------------------------------------------------------------------
# Loxone Config
# ---------------------------------------------------------------------------
find_loxone_exe() {
    find "$WINEPREFIX/drive_c/Program Files (x86)" "$WINEPREFIX/drive_c/Program Files" \
        -maxdepth 4 -iname 'LoxoneConfig.exe' 2>/dev/null | head -1
}

latest_loxone_url() {
    if [ -n "$LOXONE_SETUP_URL" ]; then
        printf '%s\n' "$LOXONE_SETUP_URL"
        return
    fi
    # Loxone bietet keinen festen Link auf die neueste Version, daher aus der Download-Seite lesen.
    curl -fsSL -A "Mozilla/5.0 (Macintosh)" "$LOXONE_DOWNLOAD_PAGE" \
        | grep -oE 'https?://[^"'"'"' ]*LoxoneConfigSetup_[0-9]+\.zip' \
        | awk -F'LoxoneConfigSetup_' '{ print $NF " " $0 }' \
        | sort -n | tail -1 | cut -d' ' -f2
}

version_from_name() {
    # LoxoneConfigSetup_17020828.zip -> 17.2.8.28
    local digits
    digits="$(basename "$1" | sed -nE 's/.*LoxoneConfigSetup_([0-9]{8}).*/\1/p')"
    [ -n "$digits" ] || { printf 'unbekannt\n'; return; }
    printf '%d.%d.%d.%d\n' "$((10#${digits:0:2}))" "$((10#${digits:2:2}))" \
        "$((10#${digits:4:2}))" "$((10#${digits:6:2}))"
}

prepare_setup_exe() {
    # Gibt den Pfad zur Setup-EXE aus. Quelle: LXC_SETUP_FILE, LXC_SETUP_URL oder Download-Seite.
    local src="$1" work="$CACHE_DIR/setup" exe
    rm -rf "$work"
    mkdir -p "$work"
    case "$src" in
        *.zip) unzip -q -o "$src" -d "$work" ;;
        *.exe) cp "$src" "$work/" ;;
        *) die "Unbekanntes Installer-Format: $src" ;;
    esac
    exe="$(find "$work" -iname 'LoxoneConfigSetup*.exe' | head -1)"
    [ -n "$exe" ] || die "Keine LoxoneConfigSetup*.exe in $src gefunden."
    printf '%s\n' "$exe"
}

install_loxone() {
    local force="${1:-}" url src version current exe
    current="$(state_get loxone_version)"

    if [ -n "$LOXONE_SETUP_FILE" ]; then
        src="$LOXONE_SETUP_FILE"
        [ -f "$src" ] || die "Datei nicht gefunden: $src"
    else
        url="$(latest_loxone_url || true)"
        if [ -z "$url" ]; then
            warn "Download-Link fuer Loxone Config nicht gefunden (Seitenaufbau geaendert?)."
            warn "Installer manuell laden und mit LXC_SETUP_FILE=/pfad/LoxoneConfigSetup_xxx.zip $0 update-loxone einspielen."
            return 1
        fi
        version="$(version_from_name "$url")"
        if [ "$force" != "force" ] && [ "$current" = "$version" ] && [ -n "$(find_loxone_exe)" ]; then
            log "Loxone Config $version ist aktuell."
            return 1
        fi
        src="$CACHE_DIR/$(basename "$url")"
        mkdir -p "$CACHE_DIR"
        log "Lade Loxone Config $version"
        fetch "$url" "$src"
    fi
    version="$(version_from_name "$src")"

    exe="$(prepare_setup_exe "$src")"
    log "Starte Loxone-Config-Installer ($version). Bitte im Installer durchklicken, Zielpfad nicht aendern."
    # shellcheck disable=SC2086  # LOXONE_SETUP_ARGS soll in Einzelargumente zerfallen
    (cd "$(dirname "$exe")" && wine_run "$exe" $LOXONE_SETUP_ARGS) || warn "Installer meldete einen Fehlercode."
    wait_wineserver

    [ -n "$(find_loxone_exe)" ] || die "LoxoneConfig.exe nach der Installation nicht gefunden."
    state_set loxone_version "$version"
    if [ -z "$LOXONE_SETUP_FILE" ]; then rm -f "$src"; fi
    rm -rf "$CACHE_DIR/setup"
    log "Loxone Config $version installiert."
}

# ---------------------------------------------------------------------------
# App-Starter
# ---------------------------------------------------------------------------
build_app() {
    local app="$APP_DIR/Loxone Config.app" icon_src
    log "Erzeuge App-Starter: $app"
    rm -rf "$app"
    # Aeltere Versionen haben den Starter immer in ~/Applications abgelegt.
    if [ "$APP_DIR" != "$HOME/Applications" ]; then rm -rf "$HOME/Applications/Loxone Config.app"; fi
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

    # Das Steuer-Skript wird in den Datenordner kopiert, damit die App unabhaengig vom Repo laeuft.
    mkdir -p "$BASE_DIR/bin"
    if [ "$SCRIPT_PATH" != "$BASE_DIR/bin/loxone-config.sh" ]; then
        cp "$SCRIPT_PATH" "$BASE_DIR/bin/loxone-config.sh"
    fi
    chmod +x "$BASE_DIR/bin/loxone-config.sh"

    cat > "$app/Contents/MacOS/LoxoneConfig" <<EOF
#!/bin/bash
mkdir -p "$LOG_DIR"
exec "$BASE_DIR/bin/loxone-config.sh" run >>"$LOG_DIR/app.log" 2>&1
EOF
    chmod +x "$app/Contents/MacOS/LoxoneConfig"

    cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Loxone Config</string>
    <key>CFBundleDisplayName</key><string>Loxone Config</string>
    <key>CFBundleIdentifier</key><string>local.loxoneconfig.wine</string>
    <key>CFBundleExecutable</key><string>LoxoneConfig</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

    # Optionales Icon: eine AppIcon.icns neben diesem Skript wird uebernommen.
    icon_src="$(dirname "$SCRIPT_PATH")/AppIcon.icns"
    [ -f "$icon_src" ] && cp "$icon_src" "$app/Contents/Resources/AppIcon.icns"
    touch "$app"
}

# ---------------------------------------------------------------------------
# Befehle
# ---------------------------------------------------------------------------
cmd_install() {
    require_macos
    require_rosetta
    require_cabextract
    mkdir -p "$BASE_DIR" "$CACHE_DIR" "$LOG_DIR"
    install_wine force || true
    install_winetricks
    setup_wine_env
    init_prefix
    install_runtimes
    install_fonts
    apply_mac_settings
    install_loxone force || true
    build_app
    log "Fertig. Start ueber '$APP_DIR/Loxone Config.app' oder '$0 run'."
}

cmd_run() {
    setup_wine_env
    local exe
    exe="$(find_loxone_exe)"
    [ -n "$exe" ] || die "Loxone Config ist nicht installiert. Zuerst '$0 install' ausfuehren."
    mkdir -p "$LOG_DIR"
    cd "$(dirname "$exe")"
    exec "$WINE" "$exe" "$@"
}

cmd_update_wine() {
    require_macos
    require_rosetta
    if install_wine; then
        setup_wine_env
        init_prefix
    fi
}

cmd_update_loxone() {
    setup_wine_env
    install_loxone
}

cmd_update() {
    require_macos
    require_cabextract
    install_winetricks
    cmd_update_wine
    setup_wine_env
    cmd_update_loxone || true
    build_app
    log "Update abgeschlossen."
    cmd_doctor
}

cmd_fonts() {
    require_cabextract
    setup_wine_env
    install_fonts
}

cmd_doctor() {
    local exe fontdir
    printf 'macOS:          %s (%s)\n' "$(sw_vers -productVersion 2>/dev/null || echo '?')" "$(uname -m)"
    if [ "$(uname -m)" = "arm64" ]; then
        if arch -x86_64 /usr/bin/true 2>/dev/null; then echo "Rosetta 2:      ok"; else echo "Rosetta 2:      FEHLT"; fi
    fi
    printf 'Datenordner:    %s\n' "$BASE_DIR"
    printf 'Wine:           %s\n' "$(state_get wine_version || true)"
    if setup_wine_env 2>/dev/null; then
        printf 'Wine-Binary:    %s (%s)\n' "$WINE" "$("$WINE" --version 2>/dev/null || echo '?')"
    else
        echo "Wine-Binary:    nicht gefunden"
    fi
    printf 'winetricks:     %s\n' "$([ -x "$WINETRICKS" ] && "$WINETRICKS" --version 2>/dev/null | head -1 || echo 'fehlt')"
    printf 'cabextract:     %s\n' "$(command -v cabextract || echo 'fehlt')"
    exe="$(find_loxone_exe)"
    printf 'Loxone Config:  %s\n' "$(state_get loxone_version || true)"
    printf 'Programmdatei:  %s\n' "${exe:-nicht gefunden}"
    if [ -d "$APP_DIR/Loxone Config.app" ]; then
        printf 'App-Starter:    %s\n' "$APP_DIR/Loxone Config.app"
    else
        printf 'App-Starter:    fehlt (mit "%s app" anlegen)\n' "$0"
    fi
    fontdir="$WINEPREFIX/drive_c/windows/Fonts"
    printf 'Schriften:      %s\n' "$(find "$fontdir" -maxdepth 1 \( -iname 'arial*' -o -iname 'tahoma*' -o -iname 'verdana*' -o -iname 'cour*' \) 2>/dev/null | wc -l | tr -d ' ') Kernschrift-Dateien in $fontdir"
    if [ -f "$WINEPREFIX/drive_c/windows/system32/mfc140u.dll" ]; then
        echo "VC++ 2022:      ok (mfc140u.dll vorhanden)"
    else
        echo "VC++ 2022:      fehlt"
    fi
}

cmd_uninstall() {
    printf 'Entfernt %s und %s. Fortfahren? [j/N] ' "$BASE_DIR" "$APP_DIR/Loxone Config.app"
    read -r answer
    case "$answer" in
        j|J|y|Y)
            rm -rf "$BASE_DIR" "/Applications/Loxone Config.app" "$HOME/Applications/Loxone Config.app"
            log "Entfernt."
            ;;
        *) log "Abgebrochen." ;;
    esac
}

main() {
    local cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        install)        cmd_install ;;
        run)            cmd_run "$@" ;;
        update)         cmd_update ;;
        update-wine)    cmd_update_wine ;;
        update-loxone)  cmd_update_loxone ;;
        fonts)          cmd_fonts ;;
        app)            build_app ;;
        doctor)         cmd_doctor ;;
        winecfg)        setup_wine_env; wine_run winecfg ;;
        uninstall)      cmd_uninstall ;;
        *)              sed -n '2,16p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; exit 1 ;;
    esac
}

main "$@"
