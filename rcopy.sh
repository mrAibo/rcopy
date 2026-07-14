#!/bin/bash

# rcopy - Remote Copy Function with Advanced Features
# Author: Aleksej V
# Date: 2025-10-18

# Strict Error Handling
set -o errexit
set -o pipefail
set -o nounset

# Color Definitions (not readonly so NO_COLOR can clear them)
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
RESET=$'\033[0m'

# Disable colors if NO_COLOR is set
if [[ -n "${NO_COLOR:-}" ]]; then
    GREEN="" RED="" YELLOW="" BLUE="" CYAN="" RESET=""
fi

# Help Function
show_help() {
    cat << EOF
${BLUE}Remote Copy (rcopy) Function Help${RESET}

${YELLOW}=============================${RESET}

${BLUE}DESCRIPTION${RESET}
    rcopy is a versatile function for copying files and directories locally or to/from
    remote systems. It combines the power of rsync and scp with additional features
    like compression, file exclusion, bandwidth control, and dry-run mode.

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
    -d, --dry-run          Preview operation without making changes
    -f, --force            Skip confirmation prompts
    -r, --resume           Resume interrupted transfers
    -q, --quick            Quick mode (compress + verbose)
    -L, --log FILE         Log all output to file
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
    # Preview what would be transferred (dry-run)
    rcopy -d -z ~/large-project server:/backup/

    # Compress and move with verbose output
    rcopy -z -m -v ~/large-project server:/backup/

    # Exclude log files and use custom SSH port
    rcopy -e "*.log" -p 2222 ~/project user@server:/backup/

    # Resume interrupted transfer
    rcopy -r ~/large-data server:/backup/

    # Quick mode with automatic settings
    rcopy -q ~/project server:/backup/

${BLUE}SYNC MODE EXAMPLES${RESET}
    # Sync all files between servers
    rcopy -S --source-host server1 --target-host server2 /source/path /target/path

    # Sync files modified in last 7 days
    rcopy -S -m --source-host server1 --target-host server2 \\
          --days 7 /source/path /target/path

${BLUE}RETURN VALUES${RESET}
    0 - Success
    1 - Error occurred

${BLUE}REQUIREMENTS${RESET}
    bash, rsync or scp, ssh, tar, gzip
EOF
}

# rcopy Main Function
rcopy() {
    # Local variables initialization
    local usage="Usage: rcopy [OPTIONS] source destination"
    local compress=false move=false dry_run=false
    local user="" port="" identity="" limit="" exclude_file=""
    local use_scp=false verbose=false force=false resume=false
    local sync_mode=false source_host="" target_host="" days=""
    local log_file=""
    local temp_dir="" temp_src=""

    # Cleanup function with proper exit code preservation
    trap_cleanup() {
        local exit_code=$?
        if [[ -n "${temp_dir:-}" ]] && [[ -d "${temp_dir:-}" ]]; then
            rm -rf "${temp_dir:-}" 2>/dev/null || true
        fi
        if [[ -n "${temp_src:-}" ]] && [[ -d "${temp_src:-}" ]]; then
            rm -rf "${temp_src:-}" 2>/dev/null || true
        fi
        exit $exit_code
    }
    trap trap_cleanup EXIT INT TERM

    # Color output helper
    echo_color() {
        local color=$1
        shift
        echo -e "${color}$*${RESET}"
    }

    # Check for required dependencies
    check_dependencies() {
        local missing_deps=()
        for cmd in ssh tar gzip; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                missing_deps+=("$cmd")
            fi
        done
        
        # Check for rsync or scp
        if ! command -v rsync >/dev/null 2>&1 && ! command -v scp >/dev/null 2>&1; then
            missing_deps+=("rsync or scp")
        fi
        
        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            echo_color "$RED" "✗ Error: Missing required dependencies: ${missing_deps[*]}"
            return 1
        fi
        return 0
    }

    # Process exclude patterns
    process_exclude_patterns() {
        local exclude_opts=()
        if [[ -n "$exclude_file" ]]; then
            if [[ -f "$exclude_file" ]]; then
                while IFS= read -r pattern; do
                    [[ -n "$pattern" ]] && [[ ! "$pattern" =~ ^# ]] && exclude_opts+=("--exclude=$pattern")
                done < "$exclude_file"
            else
                exclude_opts+=("--exclude=$exclude_file")
            fi
        fi
        printf '%s\n' "${exclude_opts[@]}"
    }

    # Confirmation prompt
    confirm_action() {
        local message="$1"
        if $force; then
            return 0
        fi
        
        while true; do
            read -r -p "${YELLOW}${message} (yes/no): ${RESET}" yn
            case $yn in
                [Yy]es|[Yy]) return 0 ;;
                [Nn]o|[Nn]) echo_color "$RED" "Operation cancelled."; return 1 ;;
                *) echo "Please answer yes or no." ;;
            esac
        done
    }

    # Calculate size and file count
    calculate_stats() {
        local path=$1
        local size="" count=""
        
        if [[ -d "$path" ]]; then
            size=$(du -sh "$path" 2>/dev/null | cut -f1)
            count=$(find "$path" -type f 2>/dev/null | wc -l | tr -d ' ')
        elif [[ -f "$path" ]]; then
            size=$(du -sh "$path" 2>/dev/null | cut -f1)
            count="1"
        fi
        
        echo "$size|$count"
    }

    # Show transfer summary
    show_transfer_summary() {
        local src=$1
        local dest=$2
        
        echo_color "$BLUE" "═══════════════════════════════════════"
        echo_color "$CYAN" "Transfer Summary"
        echo_color "$BLUE" "═══════════════════════════════════════"
        echo "  Source:      $src"
        echo "  Destination: $dest"
        
        # Calculate size only for local source
        if [[ "$src" != *:* ]] && [[ -e "$src" ]]; then
            local stats
            stats=$(calculate_stats "$src")
            local size="${stats%%|*}"
            local files="${stats##*|}"
            [[ -n "$size" ]] && echo "  Size:        $size"
            [[ -n "$files" ]] && echo "  Files:       $files"
        fi
        
        echo "  Method:      $([ "$use_scp" = true ] && echo 'SCP' || echo 'rsync')"
        echo "  Compress:    $([ "$compress" = true ] && echo 'Yes' || echo 'No')"
        [[ -n "$limit" ]] && echo "  Bandwidth:   ${limit}KB/s"
        [[ -n "$port" ]] && echo "  SSH Port:    $port"
        $resume && echo "  Resume:      Enabled"
        $move && echo_color "$RED" "  Mode:        MOVE (source will be deleted!)"
        $dry_run && echo_color "$YELLOW" "  Mode:        DRY RUN (no changes)"
        echo_color "$BLUE" "═══════════════════════════════════════"
    }

    # Validate inputs before execution
    validate_inputs() {
        local src=$1
        local dest=$2
        local errors=()

        # Compression is implemented as a local tar; a remote source can't be tarred here
        if $compress && [[ "$src" == *:* ]]; then
            errors+=("Compression (-z) requires a local source")
        fi

        # Check if source exists (local only)
        if [[ "$src" != *:* ]] && [[ ! -e "$src" ]]; then
            errors+=("Source '$src' does not exist")
        fi
        
        # Check SSH key
        if [[ -n "$identity" ]] && [[ ! -f "$identity" ]]; then
            errors+=("Identity file '$identity' not found")
        fi
        
        # Check bandwidth limit format
        if [[ -n "$limit" ]] && ! [[ "$limit" =~ ^[0-9]+$ ]]; then
            errors+=("Bandwidth limit must be a number")
        fi
        
        # Check port format
        if [[ -n "$port" ]] && ! [[ "$port" =~ ^[0-9]+$ ]]; then
            errors+=("Port must be a number")
        fi
        
        # Check remote host connectivity
        if [[ "$dest" == *:* ]]; then
            local host="${dest%%:*}"
            local ssh_opts=(-o ConnectTimeout=5 -o BatchMode=yes)
            [[ -n "$port" ]] && ssh_opts+=(-p "$port")
            [[ -n "$identity" ]] && ssh_opts+=(-i "$identity")
            
            if ! ssh "${ssh_opts[@]}" "$host" true 2>/dev/null; then
                errors+=("Cannot connect to remote host '$host'")
            fi
        fi
        
        if [[ ${#errors[@]} -gt 0 ]]; then
            echo_color "$RED" "✗ Validation failed:"
            for err in "${errors[@]}"; do
                echo "  • $err"
            done
            return 1
        fi
        
        echo_color "$GREEN" "✓ All pre-flight checks passed"
        return 0
    }

    # Parse command line options
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -z|--compress) compress=true; shift ;;
            -m|--move) move=true; shift ;;
            -d|--dry-run) dry_run=true; shift ;;
            -f|--force) force=true; shift ;;
            -r|--resume) resume=true; shift ;;
            -q|--quick) 
                compress=true
                verbose=true
                echo_color "$YELLOW" "ℹ️  Quick mode enabled (compress + verbose)"
                shift ;;
            -u|--user)
                [[ -z "${2:-}" ]] && { echo_color "$RED" "Error: --user requires an argument"; return 1; }
                user="$2"
                shift 2 ;;
            -p|--port)
                [[ -z "${2:-}" ]] && { echo_color "$RED" "Error: --port requires an argument"; return 1; }
                port="$2"
                shift 2 ;;
            -i|--identity)
                [[ -z "${2:-}" ]] && { echo_color "$RED" "Error: --identity requires an argument"; return 1; }
                identity="$2"
                shift 2 ;;
            -l|--limit)
                [[ -z "${2:-}" ]] && { echo_color "$RED" "Error: --limit requires an argument"; return 1; }
                limit="$2"
                shift 2 ;;
            -e|--exclude)
                [[ -z "${2:-}" ]] && { echo_color "$RED" "Error: --exclude requires an argument"; return 1; }
                exclude_file="$2"
                shift 2 ;;
            -L|--log)
                [[ -z "${2:-}" ]] && { echo_color "$RED" "Error: --log requires an argument"; return 1; }
                log_file="$2"
                shift 2 ;;
            -s|--use-scp) use_scp=true; shift ;;
            -v|--verbose) verbose=true; shift ;;
            -S|--sync) sync_mode=true; shift ;;
            --source-host)
                [[ -z "${2:-}" ]] && { echo_color "$RED" "Error: --source-host requires an argument"; return 1; }
                source_host="$2"
                shift 2 ;;
            --target-host)
                [[ -z "${2:-}" ]] && { echo_color "$RED" "Error: --target-host requires an argument"; return 1; }
                target_host="$2"
                shift 2 ;;
            --days)
                [[ -z "${2:-}" ]] && { echo_color "$RED" "Error: --days requires an argument"; return 1; }
                days="$2"
                [[ "$days" =~ ^[0-9]+$ ]] || {
                    echo_color "$RED" "Error: --days must be a number"
                    return 1
                }
                shift 2 ;;
            -h|--help|-?) show_help; return 0 ;;
            --*) echo_color "$RED" "Unknown option: $1"; return 1 ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    set -- "${positional[@]}"

    # Check arguments
    if [[ $# -lt 2 ]]; then
        echo_color "$RED" "✗ Error: Missing source or destination."
        echo "$usage" >&2
        return 1
    fi

    local src="$1"
    local dest="$2"

    # Apply -u/--user to remote specs (root-cause fix: was ignored before)
    apply_user_prefix() {
        local spec=$1
        if [[ -n "$user" && "$spec" == *:* && "$spec" != *@*:* ]]; then
            local host=${spec%%:*} rest=${spec#*:}
            echo "${user}@${host}:${rest}"
        else
            echo "$spec"
        fi
    }
    src=$(apply_user_prefix "$src")
    dest=$(apply_user_prefix "$dest")

    # Start logging only after validation so errors stay on the terminal
    if [[ -n "$log_file" ]]; then
        exec > >(tee -a "$log_file")
        exec 2>&1
    fi

    # Check dependencies first
    check_dependencies || return 1

    # Sync Mode Processing
    if $sync_mode; then
        if [[ -z "$source_host" ]] || [[ -z "$target_host" ]]; then
            echo_color "$RED" "✗ Error: --source-host and --target-host are required for sync mode"
            return 1
        fi

        # Honor -u/--user for sync SSH/rsync specs
        if [[ -n "$user" ]]; then
            [[ -n "$source_host" && "$source_host" != *@* ]] && source_host="${user}@${source_host}"
            [[ -n "$target_host" && "$target_host" != *@* ]] && target_host="${user}@${target_host}"
        fi

        local sync_temp_dir sync_file_list
        sync_temp_dir=$(mktemp -d)
        sync_file_list=$(mktemp)

        trap 'rm -rf "$sync_temp_dir" "$sync_file_list" 2>/dev/null || true; trap - EXIT' EXIT

        # Check SSH connections
        echo_color "$YELLOW" "Checking connections to hosts..."
        for host in "$source_host" "$target_host"; do
            if ! ssh -o ConnectTimeout=5 "$host" true 2>/dev/null; then
                echo_color "$RED" "✗ Error: $host is not reachable"
                return 1
            fi
        done

        # Create file list
        local find_cmd="find '$src' -type f"
        if [[ -n "$days" ]]; then
            find_cmd+=" -mtime -$days"
            echo_color "$YELLOW" "Creating file list from $source_host (last $days days)..."
        else
            echo_color "$YELLOW" "Creating file list from $source_host..."
        fi

        if ! ssh "$source_host" "$find_cmd" 2>/dev/null | sed "s|^$src/||" > "$sync_file_list"; then
            echo_color "$RED" "✗ Error: Failed to create file list"
            return 1
        fi

        if [[ ! -s "$sync_file_list" ]]; then
            echo_color "$YELLOW" "⚠️  No files found"
            return 0
        fi

        # Rsync from source to temp
        echo_color "$YELLOW" "Copying files from $source_host to temporary directory..."
        if ! rsync -az --files-from="$sync_file_list" "$source_host:$src/" "$sync_temp_dir/"; then
            echo_color "$RED" "✗ Error: Failed to copy from source"
            return 1
        fi

        # Rsync from temp to target
        echo_color "$YELLOW" "Copying files to $target_host..."
        if ! rsync -az --files-from="$sync_file_list" "$sync_temp_dir/" "$target_host:$dest/"; then
            echo_color "$RED" "✗ Error: Failed to copy to target"
            return 1
        fi

        # Remove files from source if move is enabled
        if $move; then
            echo_color "$YELLOW" "Removing files from source host..."
            while IFS= read -r file; do
                ssh "$source_host" "rm -f '$src/$file'" 2>/dev/null || true
            done < "$sync_file_list"
        fi

        echo_color "$GREEN" "✓ Sync completed successfully"
        return 0
    fi

    # Validate inputs
    validate_inputs "$src" "$dest" || return 1

    # Show summary
    show_transfer_summary "$src" "$dest"

    # Dry-run mode
    if $dry_run; then
        echo_color "$YELLOW" "DRY RUN MODE - No changes will be made"
        
        # Build command preview
        local cmd_preview="rsync"
        if $use_scp; then
            cmd_preview="scp -r"
        else
            cmd_preview+=" -avh --info=progress2"
        fi
        
        local ssh_preview="ssh"
        [[ -n "$port" ]] && ssh_preview+=" -p $port"
        [[ -n "$identity" ]] && ssh_preview+=" -i $identity"
        [[ "$ssh_preview" != "ssh" ]] && cmd_preview+=" -e '$ssh_preview'"
        [[ -n "$limit" ]] && cmd_preview+=" --bwlimit=$limit"
        $resume && cmd_preview+=" --partial"
        
        echo_color "$BLUE" "Would execute: $cmd_preview $src $dest"
        return 0
    fi

    # Confirm dangerous operations
    if $move; then
        confirm_action "⚠️  This will DELETE source files after transfer. Continue?" || return 1
    fi

    # Prepare compression
    local original_src="$src"
    if $compress; then
        local src_basename
        src_basename=$(basename "$src")
        temp_dir=$(mktemp -d)
        local tarfile="$temp_dir/${src_basename}.tar.gz"

        echo_color "$YELLOW" "Compressing $src..."
        
        # Build tar command with excludes
        local tar_cmd=(tar -czf "$tarfile" -C "$(dirname "$src")")
        
        if [[ -n "$exclude_file" ]]; then
            mapfile -t exclude_opts < <(process_exclude_patterns)
            for exclude_opt in "${exclude_opts[@]}"; do
                tar_cmd+=(--exclude="${exclude_opt#--exclude=}")
            done
        fi
        
        tar_cmd+=("$src_basename")
        
        if ! "${tar_cmd[@]}"; then
            echo_color "$RED" "✗ Error: Compression failed"
            return 1
        fi
        
        src="$tarfile"
    fi

    # Build transfer command using arrays for proper quoting
    local transfer_cmd
    local transfer_opts=()
    
    if $use_scp; then
        transfer_cmd="scp"
        transfer_opts=(-r)
        $verbose && transfer_opts+=(-v)
    else
        transfer_cmd="rsync"
        transfer_opts=(-avh --info=progress2)
        $verbose && transfer_opts+=(--stats)
        $resume && transfer_opts+=(--partial)
        
        # Add exclude patterns
        if [[ -n "$exclude_file" ]]; then
            mapfile -t exclude_opts < <(process_exclude_patterns)
            transfer_opts+=("${exclude_opts[@]}")
        fi
        
        # Add bandwidth limit
        [[ -n "$limit" ]] && transfer_opts+=(--bwlimit="$limit")
    fi

    # Build SSH options
    local ssh_cmd="ssh"
    local ssh_opts=()
    [[ -n "$port" ]] && ssh_opts+=(-p "$port")
    [[ -n "$identity" ]] && ssh_opts+=(-i "$identity")
    
    if [[ ${#ssh_opts[@]} -gt 0 ]]; then
        if $use_scp; then
            transfer_opts+=("${ssh_opts[@]}")
        else
            transfer_opts+=(-e "${ssh_cmd} ${ssh_opts[*]}")
        fi
    fi

    $verbose && echo_color "$YELLOW" "Executing: $transfer_cmd ${transfer_opts[*]} $src $dest"

    # Execute transfer
    echo_color "$YELLOW" "Transferring..."
    if ! "$transfer_cmd" "${transfer_opts[@]}" "$src" "$dest"; then
        echo_color "$RED" "✗ Error: Transfer failed"
        return 1
    fi

    # Decompress at destination if compressed
    if $compress; then
        echo_color "$YELLOW" "Decompressing at destination..."
        
        local tarfile_name
        tarfile_name=$(basename "$src")
        
        if [[ "$dest" == *:* ]]; then
            # Remote destination
            local remote_host="${dest%%:*}"
            local remote_path="${dest#*:}"
            
            # Build SSH command for remote decompression
            local decompress_ssh_opts=()
            [[ -n "$port" ]] && decompress_ssh_opts+=(-p "$port")
            [[ -n "$identity" ]] && decompress_ssh_opts+=(-i "$identity")
            
            if ! ssh "${decompress_ssh_opts[@]}" "$remote_host" "cd '$remote_path' && tar -xzf '$tarfile_name' && rm -f '$tarfile_name'"; then
                echo_color "$RED" "✗ Error: Remote decompression failed"
                return 1
            fi
        else
            # Local destination
            local dest_dir="$dest"
            [[ ! -d "$dest_dir" ]] && dest_dir=$(dirname "$dest")
            
            if ! (cd "$dest_dir" && tar -xzf "$tarfile_name" && rm -f "$tarfile_name"); then
                echo_color "$RED" "✗ Error: Local decompression failed"
                return 1
            fi
        fi
    fi

    # Clean up source if move is enabled (local source only — never delete a
    # remote source automatically, that would be silent data loss)
    if $move && [[ "$original_src" != *:* ]]; then
        echo_color "$YELLOW" "Removing source files..."
        if [[ -e "$original_src" ]]; then
            rm -rf "$original_src"
        fi
    fi

    echo_color "$GREEN" "✓ Operation completed successfully"
    return 0
}

# Remote path completion helper
_complete_remote_path() {
    local host_part=$1
    local path_part=$2

    if [[ -n "$host_part" ]]; then
        local remote_files
        remote_files=$(ssh -o ConnectTimeout=2 "$host_part" "ls -dp ${path_part}* 2>/dev/null" 2>/dev/null) || return 1
        while IFS= read -r file; do
            echo "${host_part}:${file}"
        done <<< "$remote_files"
        return 0
    fi
    return 1
}

# Enhanced autocomplete for rcopy
_rcopy_autocomplete() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # All available options
    local options=(
        "-z" "--compress"
        "-m" "--move"
        "-u" "--user"
        "-p" "--port"
        "-i" "--identity"
        "-l" "--limit"
        "-e" "--exclude"
        "-s" "--use-scp"
        "-v" "--verbose"
        "-d" "--dry-run"
        "-f" "--force"
        "-r" "--resume"
        "-q" "--quick"
        "-L" "--log"
        "-h" "--help"
        "-S" "--sync"
        "--source-host"
        "--target-host"
        "--days"
    )

    # Extract SSH hosts
    _get_ssh_hosts() {
        local hosts=()

        # From known_hosts
        if [[ -f ~/.ssh/known_hosts ]]; then
            hosts+=($(awk '
                $1 ~ /^[|\[]/ { next }
                { split($1, a, ",")
                  for (i in a) {
                    if (a[i] ~ /@/) {
                        split(a[i], b, "@")
                        print b[2]
                    } else {
                        print a[i]
                    }
                  }
                }' ~/.ssh/known_hosts 2>/dev/null))
        fi

        # From SSH config
        if [[ -f ~/.ssh/config ]]; then
            hosts+=($(awk '
                tolower($1) == "host" && $2 !~ /[*?]/ {
                    for (i=2; i<=NF; i++) print $i
                }' ~/.ssh/config 2>/dev/null))
        fi

        # From /etc/hosts
        if [[ -f /etc/hosts ]]; then
            hosts+=($(awk '
                $1 !~ /^#/ && $1 !~ /^[[:space:]]*$/ && $1 != "localhost" {
                    for (i=2; i<=NF; i++)
                        if ($i !~ /^#/) print $i
                }' /etc/hosts 2>/dev/null))
        fi

        printf '%s\n' "${hosts[@]}" | sort -u
    }

    # Context-dependent completion
    case "$prev" in
        -u|--user)
            COMPREPLY=($(compgen -u -- "$cur"))
            return 0
            ;;
        -i|--identity)
            COMPREPLY=($(compgen -f -X '!*.@(pem|key|id_rsa|id_ed25519)' -- "$cur"))
            return 0
            ;;
        -e|--exclude)
            local exclude_patterns=(
                ".git/" ".svn/" ".hg/"
                "node_modules/" "build/" "dist/" "target/"
                "*.tmp" "*.temp" "*.swp" "*~"
                "*.log" "logs/"
                ".cache/" ".npm/" ".yarn/"
                ".DS_Store" "Thumbs.db"
                ".idea/" ".vscode/"
                "*.pyc" "*.class" "*.o"
            )
            
            if [[ "$cur" == */* ]]; then
                COMPREPLY=($(compgen -d -- "$cur"))
            else
                COMPREPLY=($(compgen -W "${exclude_patterns[*]}" -- "$cur"))
            fi
            return 0
            ;;
        -p|--port)
            COMPREPLY=($(compgen -W "22 2222 8022" -- "$cur"))
            return 0
            ;;
        -l|--limit)
            COMPREPLY=($(compgen -W "1024 2048 5120 10240 51200 102400" -- "$cur"))
            return 0
            ;;
        -L|--log)
            COMPREPLY=($(compgen -f -- "$cur"))
            return 0
            ;;
        --source-host|--target-host)
            local hosts
            hosts=$(_get_ssh_hosts)
            COMPREPLY=($(compgen -W "$hosts" -- "$cur"))
            return 0
            ;;
        --days)
            COMPREPLY=($(compgen -W "1 7 14 30 90" -- "$cur"))
            return 0
            ;;
    esac

    # Option completion
    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "${options[*]}" -- "$cur"))
        return 0
    fi

    # Remote path completion
    if [[ "$cur" == *:* ]]; then
        local host_part="${cur%%:*}"
        local path_part="${cur#*:}"

        if _complete_remote_path "$host_part" "$path_part"; then
            return 0
        fi

        local hosts
        hosts=$(_get_ssh_hosts)
        COMPREPLY=($(compgen -W "$hosts" -S ":" -- "$cur"))
        return 0
    fi

    # Default filesystem completion
    COMPREPLY=($(compgen -d -- "$cur") $(compgen -f -- "$cur"))
    return 0
}

# Activate autocomplete
complete -F _rcopy_autocomplete rcopy

# Export function if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f rcopy
    export -f show_help
    echo "rcopy function loaded. Type 'rcopy --help' for usage information."
fi
