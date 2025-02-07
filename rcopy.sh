# Helpfunction
show_help() {
    cat << EOF >&1
${BLUE}Remote Copy (rcopy) Function Help${RESET}
${YELLOW}=============================${RESET}

${BLUE}DESCRIPTION${RESET}
    rcopy is a versatile function for copying files and directories locally or to/from
    remote systems. It combines the power of rsync and scp with additional features
    like compression, file exclusion, and bandwidth control.

${BLUE}SYNTAX${RESET}
    rcopy [OPTIONS] source destination

${BLUE}OPTIONS${RESET}
    -z, --compress           Compress data during transfer (uses tar+gzip)
    -m, --move              Move instead of copy (delete source after transfer)
    -u, --user USERNAME     Specify remote username
    -p, --port PORT         Specify SSH port number
    -i, --identity FILE     Specify SSH identity file (private key)
    -l, --limit RATE        Limit bandwidth (KB/s, rsync only)
    -e, --exclude PATTERN   Exclude files matching pattern or use exclude file
    -s, --use-scp          Force using SCP instead of rsync
    -v, --verbose          Show detailed progress information
    -h, --help             Show this help message
    -S, --sync             Enable sync mode between remote servers
    --source-host HOST     Source server hostname/IP
    --target-host HOST     Target server hostname/IP
    --days DAYS           Sync files modified in last DAYS days (optional)

${BLUE}BASIC EXAMPLES${RESET}
    # Copy a local directory
    rcopy ~/documents/project /backup/

    # Copy to remote server
    rcopy ~/documents user@server:/backup/

    # Copy from remote server
    rcopy user@server:/remote/data ~/local/

${BLUE}ADVANCED EXAMPLES${RESET}
    # Compress and move with verbose output
    rcopy -z -m -v ~/large-project server:/backup/

    # Exclude log files and use custom SSH port
    rcopy -e "*.log" -p 2222 ~/project user@server:/backup/

    # Use file containing exclude patterns
    rcopy -e exclude.txt ~/source ~/destination/

    # Compress and limit bandwidth to 1MB/s
    rcopy -z -l 1024 ~/large-data server:/backup/

    # Use specific SSH key and SCP
    rcopy -s -i ~/.ssh/custom_key ~/data server:/backup/

${BLUE}SYNC MODE EXAMPLES${RESET}
    # Sync all files between servers
    rcopy -S --source-host server1 --target-host server2 /source/path /target/path

    # Sync files modified in last 7 days and move them
    rcopy -S -m --source-host server1 --target-host server2 \\
          --days 7 /source/path /target/path

${BLUE}SYNC MODE OPTIONS${RESET}
    -S, --sync              Enable sync mode between remote servers
    --source-host HOST      Source server hostname/IP
    --target-host HOST      Target server hostname/IP
    --days DAYS            Sync files modified in last DAYS days (optional)

${BLUE}EXCLUDE PATTERNS${RESET}
    You can exclude files in two ways:
    1. Direct pattern:
       rcopy -e "*.log" source dest    # Excludes all .log files

    2. Using an exclude file:
       Create a file (e.g., exclude.txt) containing patterns:
       *.log
       *.tmp
       .git/
       Then use: rcopy -e exclude.txt source dest

${BLUE}COMPRESSION NOTES${RESET}
    * Compression (-z) is useful for:
      - Text files, documents, source code
      - Transferring many small files
      - Slow network connections
    * Not recommended for:
      - Already compressed files (zip, jpg, mp4)
      - Very large single files
      - Fast local networks

${BLUE}PERFORMANCE TIPS${RESET}
    * Use compression (-z) over slow connections
    * Use bandwidth limit (-l) on busy networks
    * Use rsync (default) instead of scp for large directories
    * Exclude unnecessary files to speed up transfers
    * For local copies of large files, avoid compression

${BLUE}SSH CONFIGURATION${RESET}
    * Use SSH keys for passwordless authentication
    * Can specify custom port with -p
    * Use -i for non-default SSH key location
    * Works with SSH config file aliases

${BLUE}RETURN VALUES${RESET}
    0 - Success
    1 - Error occurred (invalid options, transfer failed, etc.)

${BLUE}ENVIRONMENT${RESET}
    Requires: bash, rsync or scp, ssh, tar
    Optional: gzip (for compression)
EOF
}

# rcopy - Remote Copy Function
rcopy() {
    # Farbdefinitionen
    local GREEN=$'\033[0;32m'
    local RED=$'\033[0;31m'
    local YELLOW=$'\033[0;33m'
    local BLUE=$'\033[0;34m'
    local RESET=$'\033[0m'

    # Basis-Vars
    local usage="Usage: rcopy [OPTIONS] source destination"
    local compress=false move=false
    local user="" port="" identity="" limit="" exclude_file=""
    local use_scp=false verbose=false
    local sync_mode=false source_host="" target_host="" days=""

    local temp_dir="" temp_src=""

    # Trap für Cleanup
    trap_cleanup() {
        [ -n "$temp_dir" ] && rm -rf "$temp_dir"
        [ -n "$temp_src" ] && rm -rf "$temp_src"
    }
    trap trap_cleanup EXIT

    # colors for help
    echo_color() {
        local color=$1
        shift
        echo -e "${color}$@${RESET}"
    }

    # check for utils
    check_dependencies() {
        for cmd in rsync scp ssh tar gzip; do
            command -v "$cmd" >/dev/null 2>&1 || {
                echo_color $RED "Error: $cmd is required but not installed."
                return 1
            }
        done
    }

    # Exclude-Patterns
    process_exclude_patterns() {
        local exclude_opts=()
        if [[ -f "$exclude_file" ]]; then
            while IFS= read -r pattern; do
                [[ -n "$pattern" ]] && exclude_opts+=("--exclude=$pattern")
            done < "$exclude_file"
        elif [[ -n "$exclude_file" ]]; then
            exclude_opts+=("--exclude=$exclude_file")
        fi
        echo "${exclude_opts[@]}"
    }

    # Options
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -z|--compress) compress=true; shift ;;
            -m|--move) move=true; shift ;;
            -u|--user)
                user="${2:?Error: --user requires an argument}"
                shift 2 ;;
            -p|--port)
                port="${2:?Error: --port requires an argument}"
                shift 2 ;;
            -i|--identity)
                identity="${2:?Error: --identity requires an argument}"
                shift 2 ;;
            -l|--limit)
                limit="${2:?Error: --limit requires an argument}"
                shift 2 ;;
            -e|--exclude)
                exclude_file="${2:?Error: --exclude requires an argument}"
                shift 2 ;;
            -s|--use-scp) use_scp=true; shift ;;
            -v|--verbose) verbose=true; shift ;;
            -S|--sync) sync_mode=true; shift ;;
            --source-host)
                source_host="${2:?Error: --source-host requires an argument}"
                shift 2 ;;
            --target-host)
                target_host="${2:?Error: --target-host requires an argument}"
                shift 2 ;;
            --days)
                days="${2:?Error: --days requires an argument}"
                [[ "$days" =~ ^[0-9]+$ ]] || {
                    echo_color $RED "Error: --days must be a number"
                    return 1
                }
                shift 2 ;;
            -h|--help|-?) show_help; return 0 ;;
            --*) echo_color $RED "Unknown option: $1"; return 1 ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    set -- "${positional[@]}"

    # Argumente check
    if [ $# -lt 2 ]; then
        echo_color $RED "Error: Missing source or destination."
        echo "$usage" >&2
        return 1
    fi

    local src="$1" dest="$2"
    local exclude_patterns
    exclude_patterns=($(process_exclude_patterns))

    # check dependencies
    check_dependencies || return 1

    # Nach der Argumentprüfung und vor der Kompression:
    # Sync-Mode Verarbeitung
    if $sync_mode; then
        if [[ -z "$source_host" || -z "$target_host" ]]; then
            echo_color $RED "Error: --source-host and --target-host are required for sync mode"
            return 1
        fi

        # Temporäre Dateien
        local sync_temp_dir sync_file_list
        sync_temp_dir=$(mktemp -d)
        sync_file_list=$(mktemp)

        # Cleanup für Sync-Mode
        trap 'rm -rf "$sync_temp_dir" "$sync_file_list"; trap - EXIT' EXIT

        # SSH-Verbindungen prüfen
        echo_color $YELLOW "Checking connections to hosts..."
        for host in "$source_host" "$target_host"; do
            if ! ssh -o ConnectTimeout=5 "$host" true 2>/dev/null; then
                echo_color $RED "Error: $host is not reachable"
                return 1
            fi
        done

        # Dateiliste erstellen
        local find_cmd="find '$src' -type f"
        if [[ -n "$days" ]]; then
            find_cmd+=" -mtime -$days"
            echo_color $YELLOW "Creating file list from $source_host (last $days days)..."
        else
            echo_color $YELLOW "Creating file list from $source_host..."
        fi

        if ! ssh "$source_host" "$find_cmd" 2>/dev/null | sed "s|^$src/||" > "$sync_file_list"; then
            echo_color $RED "Error: Failed to create file list"
            return 1
        fi

        if [ ! -s "$sync_file_list" ]; then
            echo_color $YELLOW "No files found"
            return 0
        fi

        # Rsync von Quelle zum Temp
        echo_color $YELLOW "Copying files from $source_host to temporary directory..."
        if ! rsync -az --files-from="$sync_file_list" "$source_host:$src/" "$sync_temp_dir/"; then
            echo_color $RED "Error: Failed to copy from source"
            return 1
        fi

        # Rsync von Temp zum Ziel
        echo_color $YELLOW "Copying files to $target_host..."
        if ! rsync -az --files-from="$sync_file_list" "$sync_temp_dir/" "$target_host:$dest/"; then
            echo_color $RED "Error: Failed to copy to target"
            return 1
        fi

        # Wenn move aktiviert ist, Dateien auf Quellserver löschen
        if $move; then
            echo_color $YELLOW "Removing files from source host..."
            if ! ssh "$source_host" "cd '$src' && xargs rm -f < '$sync_file_list'" 2>/dev/null; then
                echo_color $RED "Warning: Failed to remove some files from source"
            fi
        fi

        echo_color $GREEN "Sync completed successfully"
        return 0
    fi

    # Kompression vorbereiten
    if $compress; then
        local src_basename
        src_basename=$(basename "$src")
        temp_dir=$(mktemp -d)
        local tarfile="$temp_dir/${src_basename}.tar.gz"

        echo_color $YELLOW "Compressing $src..."
        tar -czf "$tarfile" --exclude="${exclude_patterns[@]}" -C "$(dirname "$src")" "$src_basename" || {
            echo_color $RED "Error: Compression failed."
            return 1
        }
        src="$tarfile"
    fi

    # Übertragungsbefehl erstellen
    local transfer_cmd="rsync"
    local transfer_opts="-avh --progress"
    if [[ -n "$exclude_file" ]]; then
        local exclude_opts
        exclude_opts=($(process_exclude_patterns))
        transfer_opts+=" ${exclude_opts[@]}"
    fi
    $use_scp && transfer_cmd="scp" && transfer_opts="-r"
    $move && transfer_opts+=" --remove-source-files"
    [ -n "$limit" ] && transfer_opts+=" --bwlimit=$limit"
    [ -n "$port" ] && transfer_opts+=" -e 'ssh -p $port'"
    [ -n "$identity" ] && transfer_opts+=" -e 'ssh -i $identity'"

    $verbose && echo_color $YELLOW "Executing: $transfer_cmd $transfer_opts $src $dest"

    # Übertragung ausführen
    $transfer_cmd $transfer_opts "$src" "$dest" || {
        echo_color $RED "Error: Transfer failed."
        return 1
    }

    # Nach der Übertragung entpacken, wenn komprimiert wurde
    if $compress; then
        local dest_dir
        if [[ "$dest" == *:* ]]; then
            dest_dir=$(dirname "${dest#*:}")
        else
            dest_dir="$dest"
            [[ "$dest_dir" != */ ]] && dest_dir="$(dirname "$dest")"
        fi

        echo_color $YELLOW "Decompressing at destination..."
        (cd "$dest_dir" && tar xzf "$(basename "$src")" && rm -f "$(basename "$src")") || {
            echo_color $RED "Error: Decompression failed."
            return 1
        }
    fi

    # Quelle aufräumen, wenn move aktiviert ist
    if $move; then
        echo_color $YELLOW "Cleaning up source..."
        rm -rf "$1"
    fi

    echo_color $GREEN "Operation completed successfully."
    return 0
}

# Neue Funktion für Remote-Pfad-Vervollständigung
_complete_remote_path() {
    local host_part=$1
    local path_part=$2

    # Remote-Verzeichnisliste per SSH abrufen
    if [[ -n "$host_part" ]]; then
        local remote_files
        remote_files=$(ssh "$host_part" "ls -dp ${path_part}* 2>/dev/null" 2>/dev/null) || return 1
        while IFS= read -r file; do
            echo "${host_part}:${file}"
        done <<< "$remote_files"
        return 0
    fi
    return 1
}

# Verbesserte Autovervollständigung für rcopy
_rcopy_autocomplete() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Alle verfügbaren Optionen (ohne Beschreibungen für die erste Ebene)
    local options=(
        "-z --compress"
        "-m --move"
        "-u --user"
        "-p --port"
        "-i --identity"
        "-l --limit"
        "-e --exclude"
        "-s --use-scp"
        "-v --verbose"
        "-h --help"
        "-S --sync"
        "--source-host"
        "--target-host"
        "--days"
    )

    # Funktion zum Extrahieren von SSH-Hosts (bleibt unverändert)
    _get_ssh_hosts() {
        local hosts=()

        # Hosts aus known_hosts extrahieren (mit besserer Behandlung von Hashed-Hosts)
        if [ -f ~/.ssh/known_hosts ]; then
            hosts+=($(awk '
                $1 ~ /^[|\[]/ { next }  # Überspringe Hashed-Hosts
                { split($1, a, ",")      # Trenne mehrere Hostnamen
                  for (i in a) {
                    if (a[i] ~ /@/) {    # Host mit Benutzer
                        split(a[i], b, "@")
                        print b[2]
                    } else {             # Nur Host
                        print a[i]
                    }
                  }
                }' ~/.ssh/known_hosts
            ))
        fi

        # Hosts aus SSH config mit besserer Parsing-Logik
        if [ -f ~/.ssh/config ]; then
            hosts+=($(awk '
                tolower($1) == "host" && $2 !~ /[*?]/ {
                    for (i=2; i<=NF; i++) print $i
                }' ~/.ssh/config
            ))
        fi

        # Lokale Hosts aus /etc/hosts hinzufügen
        if [ -f /etc/hosts ]; then
            hosts+=($(awk '
                $1 !~ /^#/ && $1 !~ /^[[:space:]]*$/ && $1 != "localhost" {
                    for (i=2; i<=NF; i++)
                        if ($i !~ /^#/) print $i
                }' /etc/hosts
            ))
        fi

        # Doppelte Einträge entfernen und sortieren
        echo "$(printf '%s\n' "${hosts[@]}" | sort -u)"
    }

    # Kontextabhängige Vervollständigung
    case "$prev" in
        -u|--user)
            # Benutzer aus /etc/passwd vorschlagen
            COMPREPLY=($(compgen -u -- "$cur"))
            return 0
            ;;
        -i|--identity)
            # SSH-Schlüssel vorschlagen (nur .pem und .key Dateien)
            COMPREPLY=($(compgen -f -X '!*.@(pem|key)' -- "$cur"))
            return 0
            ;;
        -e|--exclude)
            # Erweiterte Ausschlussmuster mit Kategorien und Verzeichnis-Vervollständigung
            local exclude_patterns=(
                # Versionskontrolle
                ".git/" ".svn/" ".hg/"
                # Build-Artefakte
                "node_modules/" "build/" "dist/" "target/"
                # Temporäre Dateien
                "*.tmp" "*.temp" "*.swp" "*~"
                # Logs
                "*.log" "logs/" "*.log.*"
                # Caches
                ".cache/" ".npm/" ".yarn/"
                # System-Dateien
                ".DS_Store" "Thumbs.db"
                # IDE-Dateien
                ".idea/" ".vscode/" "*.sublime-*"
                # Kompilierte Dateien
                "*.pyc" "*.class" "*.o"
            )

            if [[ "$cur" == */* ]]; then
                # Verzeichnisbasierte Vervollständigung
                COMPREPLY=($(compgen -d -- "$cur"))
            else
                # Pattern-basierte Vervollständigung (mit Präfix für bessere Sortierung)
                COMPREPLY=($(compgen -W "${exclude_patterns[*]}" -P "exclude: " -- "$cur"))
            fi
            return 0
            ;;
        -p|--port)
            # Häufige SSH-Ports vorschlagen
            local ports=("22" "2222" "8022")
            COMPREPLY=($(compgen -W "${ports[*]}" -- "$cur"))
            return 0
            ;;
        -l|--limit)
            # Bandbreitenlimits mit menschenlesbaren Einheiten (und Suffixen)
            local limits=("1M" "2M" "5M" "10M" "50M" "100M" "1G")
            COMPREPLY=($(compgen -W "${limits[*]}" -S "B/s" -- "$cur"))
            return 0
            ;;
        -S|--sync)
            # Keine spezifischen Vorschläge für -S, da es weitere Optionen benötigt
            return 0
            ;;
        --source-host|--target-host)
            # SSH-Hosts vorschlagen
            local hosts=$(_get_ssh_hosts)
            COMPREPLY=($(compgen -W "$hosts" -- "$cur"))
            return 0
            ;;
        --days)
            # Typische Tageswerte vorschlagen
            local days=("1" "7" "14" "30" "90")
            COMPREPLY=($(compgen -W "${days[*]}" -- "$cur"))
            return 0
            ;;
    esac

    # Wenn der aktuelle Parameter mit - oder -- beginnt (allgemeine Optionen)
    if [[ "$cur" == -* ]]; then
        # Optionen ohne Beschreibungen anzeigen (für bessere Übersicht)
        COMPREPLY=($(compgen -W "${options[*]}" -- "$cur"))
        return 0
    fi

    # Wenn es sich um eine Remote-Pfad-Eingabe handeln könnte
    if [[ "$cur" == *:* ]]; then
        local host_part=${cur%%:*}
        local path_part=${cur#*:}

        # Zuerst versuchen, Remote-Pfade zu vervollständigen
        if _complete_remote_path "$host_part" "$path_part"; then
            return 0
        fi

        # Fallback auf Host-Vervollständigung (mit Doppelpunkt als Suffix)
        local hosts=$(_get_ssh_hosts)
        COMPREPLY=($(compgen -W "$hosts" -S ":" -- "$cur"))
        return 0
    fi

    # Standard-Dateisystem-Vervollständigung (Verzeichnisse zuerst)
    COMPREPLY=($(compgen -d -- "$cur") $(compgen -f -- "$cur"))
    return 0
}

# Autovervollständigung aktivieren
complete -F _rcopy_autocomplete rcopy
