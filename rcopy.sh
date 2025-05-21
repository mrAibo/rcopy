# Helpfunction
show_help() {
    cat << EOF >&1
${BLUE}Remote Copy (rcopy) Function Help${RESET}
${YELLOW}=============================${RESET}

${BLUE}DESCRIPTION${RESET}
    rcopy is a versatile function for copying files and directories locally or to/from
    remote systems. It combines the power of rsync and scp with additional features
    like compression, file exclusion, bandwidth control, and dry-run capabilities.

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
    -n, --dry-run          Show what would be done without actually doing it
    -h, --help             Show this help message
    -S, --sync             Enable sync mode between remote servers
    --source-host HOST     Source server hostname/IP (for sync mode)
    --target-host HOST     Target server hostname/IP (for sync mode)
    --days DAYS           Sync files modified in last DAYS days (optional, for sync mode)

${BLUE}BASIC EXAMPLES${RESET}
    # Copy a local directory
    rcopy ~/documents/project /backup/

    # Copy to remote server with verbose output
    rcopy -v ~/documents user@server:/backup/

    # Dry-run copy from remote server
    rcopy -n user@server:/remote/data ~/local/

${BLUE}ADVANCED EXAMPLES${RESET}
    # Compress, move, and show what would happen
    rcopy -z -m -n -v ~/large-project server:/backup/

    # Exclude log files, use custom SSH port 2222
    rcopy -e "*.log" -p 2222 ~/project user@server:/backup/

    # Use specific SSH key and SCP for transfer
    rcopy -s -i ~/.ssh/custom_key ~/data server:/backup/

${BLUE}SYNC MODE EXAMPLES${RESET}
    # Dry-run sync of all files between server1 and server2
    rcopy -n -S --source-host server1 --target-host server2 /source/path /target/path

    # Sync files modified in last 7 days and move them, with verbose output
    rcopy -v -S -m --source-host server1 --target-host server2 \\
          --days 7 /source/path /target/path

${BLUE}RETURN VALUES${RESET}
    0 - Success (or successful dry run)
    1 - Generic error
    2 - Invalid command-line option or argument
    3 - Missing dependency
    4 - Connection error (e.g., SSH connection failed)
    5 - Source or destination not found (or access error)
    6 - Transfer error (e.g., rsync or scp failure)
    7 - Compression or decompression error
    8 - Sync mode specific error
EOF
}

# Define Exit Codes (for clarity and consistency)
readonly RCOPY_EXIT_SUCCESS=0
readonly RCOPY_EXIT_GENERIC_ERROR=1
readonly RCOPY_EXIT_INVALID_OPTION=2
readonly RCOPY_EXIT_MISSING_DEPENDENCY=3
readonly RCOPY_EXIT_CONNECTION_ERROR=4
readonly RCOPY_EXIT_PATH_NOT_FOUND=5 # Or access error
readonly RCOPY_EXIT_TRANSFER_ERROR=6
readonly RCOPY_EXIT_COMPRESSION_ERROR=7
readonly RCOPY_EXIT_SYNC_ERROR=8


# rcopy - Remote Copy Function
rcopy() {
    # Farbdefinitionen
    local GREEN=$'\033[0;32m'
    local RED=$'\033[0;31m'
    local YELLOW=$'\033[0;33m'
    local BLUE=$'\033[0;34m'
    local RESET=$'\033[0m'

    # Basis-Vars
    local usage="Usage: rcopy [OPTIONS] source destination. Use -h for help."
    
    # Global option variables - will be set by _parse_options
    # Default values
    compress=false; move=false; user=""; port=""; identity=""; limit=""; exclude_file=""
    use_scp=false; verbose=false; sync_mode=false; source_host=""; target_host=""; days=""
    dry_run=false # New option for dry-run
    
    # Global array for positional arguments, populated by _parse_options
    RCOPY_POSITIONAL_ARGS=()
    
    # temp_dir_compress will be used for compression artifacts
    local temp_dir_compress 
    trap_cleanup() {
        if [ -n "$temp_dir_compress" ]; then
            # Only remove if not in dry_run, as it might not have been created
            ! $dry_run && [ -d "$temp_dir_compress" ] && rm -rf "$temp_dir_compress"
            temp_dir_compress=""
        fi
    }
    trap trap_cleanup EXIT INT TERM

    echo_color() {
        local color=$1
        shift
        echo -e "${color}$@${RESET}"
    }

    check_dependencies() {
        for cmd in rsync scp ssh tar gzip; do
            command -v "$cmd" >/dev/null 2>&1 || {
                echo_color $RED "Error: Dependency missing - '$cmd' is required but not installed."
                return $RCOPY_EXIT_MISSING_DEPENDENCY
            }
        done
        return $RCOPY_EXIT_SUCCESS
    }

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

    _parse_options() {
        RCOPY_POSITIONAL_ARGS=() # Reset for each call
        local OPTIND_SAVE=$OPTIND
        OPTIND=1 

        while [[ $# -gt 0 ]]; do
            case "$1" in
                -z|--compress) compress=true; shift ;;
                -m|--move) move=true; shift ;;
                -u|--user) user="${2:?Error: --user requires an argument}"; shift 2 ;;
                -p|--port) port="${2:?Error: --port requires an argument}"; shift 2 ;;
                -i|--identity) identity="${2:?Error: --identity requires an argument}"; shift 2 ;;
                -l|--limit) limit="${2:?Error: --limit requires an argument}"; shift 2 ;;
                -e|--exclude) exclude_file="${2:?Error: --exclude requires an argument}"; shift 2 ;;
                -s|--use-scp) use_scp=true; shift ;;
                -v|--verbose) verbose=true; shift ;;
                -n|--dry-run) dry_run=true; shift ;;
                -S|--sync) sync_mode=true; shift ;;
                --source-host) source_host="${2:?Error: --source-host requires an argument}"; shift 2 ;;
                --target-host) target_host="${2:?Error: --target-host requires an argument}"; shift 2 ;;
                --days)
                    days="${2:?Error: --days requires an argument}"
                    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
                        echo_color $RED "Error: Invalid argument for --days: '$days'. Must be a number."
                        return $RCOPY_EXIT_INVALID_OPTION
                    fi
                    shift 2 ;;
                -h|--help|-?) show_help; return $RCOPY_EXIT_SUCCESS ;; 
                --*) echo_color $RED "Error: Unknown option '$1'"; return $RCOPY_EXIT_INVALID_OPTION ;;
                *) RCOPY_POSITIONAL_ARGS+=("$1"); shift ;;
            esac
        done
        OPTIND=$OPTIND_SAVE
        return $RCOPY_EXIT_SUCCESS
    }

    _perform_sync_mode() {
        local sync_src="$1"
        local sync_dest="$2"

        if [[ -z "$source_host" || -z "$target_host" ]]; then
            echo_color $RED "Sync Error: --source-host and --target-host are required for sync mode."
            return $RCOPY_EXIT_SYNC_ERROR 
        fi

        local sync_temp_dir sync_file_list
        sync_temp_dir=$(mktemp -d)
        sync_file_list=$(mktemp)
        
        trap 'rm -rf "$sync_temp_dir" "$sync_file_list"; trap - EXIT INT TERM; trap_cleanup' EXIT INT TERM

        if ! $dry_run; then
            echo_color $YELLOW "Checking connections to hosts..."
            for host in "$source_host" "$target_host"; do
                if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" true 2>/dev/null; then 
                    echo_color $RED "Connection Error: Host '$host' is not reachable or SSH connection failed."
                    return $RCOPY_EXIT_CONNECTION_ERROR
                fi
            done
        else
            echo_color $BLUE "[DRY RUN] Would check connections to $source_host and $target_host."
        fi

        local find_cmd_str="find '$sync_src' -type f"
        [[ -n "$days" ]] && find_cmd_str+=" -mtime -$days"
        
        echo_color $YELLOW "Sync: Creating file list from $source_host:$sync_src..."
        local ssh_find_cmd="ssh -o BatchMode=yes \"$source_host\" \"$find_cmd_str\""

        if $dry_run; then
            echo_color $BLUE "[DRY RUN] Would execute to find files: $ssh_find_cmd | sed 's|^$sync_src/||' > \"$sync_file_list\""
            echo_color $BLUE "[DRY RUN] Creating dummy file list for subsequent sync steps."
            echo "dummy_file1.txt" > "$sync_file_list"
            echo "dummy_dir/dummy_file2.txt" >> "$sync_file_list"
        else
            if ! (eval "$ssh_find_cmd" 2>/dev/null | sed "s|^$sync_src/||" > "$sync_file_list"); then
                 if ! ssh -o BatchMode=yes "$source_host" "test -e '$sync_src'" 2>/dev/null; then
                    echo_color $RED "Sync Error: Source path '$sync_src' does not exist or is not accessible on host '$source_host'."
                    return $RCOPY_EXIT_PATH_NOT_FOUND
                fi
                echo_color $RED "Sync Error: Failed to create file list from '$source_host:$sync_src'. Check permissions or path validity."
                return $RCOPY_EXIT_SYNC_ERROR 
            fi
        fi

        if [ ! -s "$sync_file_list" ] && ! $dry_run; then 
            echo_color $YELLOW "Sync: No files found matching criteria to sync."
            return $RCOPY_EXIT_SUCCESS 
        fi
        if [ ! -s "$sync_file_list" ] && $dry_run; then 
             echo_color $YELLOW "[DRY RUN] Dummy file list is empty. No files to sync."
             return $RCOPY_EXIT_SUCCESS
        fi

        echo_color $YELLOW "Sync: Copying files from $source_host:$sync_src to temporary directory..."
        local rsync_to_temp_cmd="rsync -az --files-from=\"$sync_file_list\" \"$source_host:$sync_src/\" \"$sync_temp_dir/\""
        if $dry_run; then
            echo_color $BLUE "[DRY RUN] Would execute: $rsync_to_temp_cmd"
        else
            if ! eval "$rsync_to_temp_cmd"; then
                echo_color $RED "Sync Error: Rsync failed to copy files from '$source_host:$sync_src' to temporary directory."
                return $RCOPY_EXIT_TRANSFER_ERROR
            fi
        fi

        echo_color $YELLOW "Sync: Copying files from temporary directory to $target_host:$sync_dest..."
        if ! $dry_run ; then 
            if ! ssh -o BatchMode=yes "$target_host" "test -d '$sync_dest' && touch '$sync_dest/.rcopy_writetest'" 2>/dev/null; then
                echo_color $RED "Sync Error: Target directory '$sync_dest' does not exist or is not writable on host '$target_host'."
                ssh -o BatchMode=yes "$target_host" "rm -f '$sync_dest/.rcopy_writetest'" 2>/dev/null
                return $RCOPY_EXIT_PATH_NOT_FOUND
            fi
            ssh -o BatchMode=yes "$target_host" "rm -f '$sync_dest/.rcopy_writetest'" 2>/dev/null
        else
             echo_color $BLUE "[DRY RUN] Would check if target directory '$sync_dest' exists and is writable on $target_host."
        fi
        
        local rsync_to_target_cmd="rsync -az --files-from=\"$sync_file_list\" \"$sync_temp_dir/\" \"$target_host:$sync_dest/\""
        if $dry_run; then
            echo_color $BLUE "[DRY RUN] Would execute: $rsync_to_target_cmd"
        else
            if ! eval "$rsync_to_target_cmd"; then
                echo_color $RED "Sync Error: Rsync failed to copy files from temporary directory to '$target_host:$sync_dest'."
                return $RCOPY_EXIT_TRANSFER_ERROR
            fi
        fi

        if $move; then
            echo_color $YELLOW "Sync: Removing files from source host ($source_host:$sync_src)..."
            if [ -s "$sync_file_list" ]; then 
                local files_to_delete_str_for_cmd=""
                local files_to_delete_array_for_cmd=()
                while IFS= read -r line; do files_to_delete_array_for_cmd+=("$line"); done < "$sync_file_list"
                if [ ${#files_to_delete_array_for_cmd[@]} -gt 0 ]; then
                    files_to_delete_str_for_cmd=$(printf "'%s' " "${files_to_delete_array_for_cmd[@]}")
                fi
                
                if [ -n "$files_to_delete_str_for_cmd" ]; then
                    local delete_cmd_on_source="ssh -o BatchMode=yes \"$source_host\" \"cd '$sync_src' && rm -f $files_to_delete_str_for_cmd\""
                    if $dry_run; then
                        echo_color $BLUE "[DRY RUN] Would execute: $delete_cmd_on_source"
                    else
                       if eval "$delete_cmd_on_source"; then
                           echo_color $GREEN "Sync: Successfully removed files from $source_host:$sync_src."
                       else
                           echo_color $YELLOW "Sync Warning: Failed to remove some or all files from '$source_host:$sync_src'."
                       fi
                    fi
                else
                     echo_color $YELLOW "Sync: (Move) No file names generated for deletion command from '$sync_file_list'."
                fi
            else
                 echo_color $YELLOW "Sync: File list '$sync_file_list' is empty. No files to delete on source (move operation)."
            fi
        fi
        return $RCOPY_EXIT_SUCCESS
    }

    _handle_compression() {
        local original_src_path="$1"
        local original_src_basename="$2"
        if ! $compress; then
            echo "$original_src_path"; return $RCOPY_EXIT_SUCCESS
        fi

        temp_dir_compress=$(mktemp -d) 
        local tarfile="$temp_dir_compress/${original_src_basename}.tar.gz"
        local current_exclude_patterns_arr=($(process_exclude_patterns))
        
        echo_color $YELLOW "Compressing $original_src_path..."
        local src_parent_dir=$(dirname "$original_src_path")
        local src_actual_name=$(basename "$original_src_path")
        local tar_cmd

        if [[ "$src_parent_dir" == "." ]]; then
            if [ ! -e "$original_src_path" ] && ! $dry_run; then
                echo_color $RED "Compression Error: Source path '$original_src_path' not found."
                return $RCOPY_EXIT_PATH_NOT_FOUND
            elif [ ! -e "$original_src_path" ] && $dry_run; then
                echo_color $YELLOW "[DRY RUN] Warning: Compression source '$original_src_path' not found."
            fi
            tar_cmd="tar -czf \"$tarfile\" ${current_exclude_patterns_arr[*]} \"$original_src_path\""
        else
            if [ ! -d "$src_parent_dir" ] && ! $dry_run; then 
                echo_color $RED "Compression Error: Parent directory '$src_parent_dir' for source '$src_actual_name' not found."
                return $RCOPY_EXIT_PATH_NOT_FOUND
            elif [ ! -d "$src_parent_dir" ] && $dry_run; then
                 echo_color $YELLOW "[DRY RUN] Warning: Compression parent source dir '$src_parent_dir' not found."
            fi
            if [ ! -e "$original_src_path" ] && ! $dry_run; then 
                echo_color $RED "Compression Error: Source path '$original_src_path' not found."
                return $RCOPY_EXIT_PATH_NOT_FOUND
            elif [ ! -e "$original_src_path" ] && $dry_run; then
                 echo_color $YELLOW "[DRY RUN] Warning: Compression source '$original_src_path' not found."
            fi
            tar_cmd="tar -czf \"$tarfile\" ${current_exclude_patterns_arr[*]} -C \"$src_parent_dir\" \"$src_actual_name\""
        fi
        
        if $dry_run; then
            echo_color $BLUE "[DRY RUN] Would execute for compression: $tar_cmd"
        else
            eval "$tar_cmd" || {
                echo_color $RED "Compression Error: tar command failed: $tar_cmd"
                return $RCOPY_EXIT_COMPRESSION_ERROR
            }
        fi
        echo "$tarfile" 
        return $RCOPY_EXIT_SUCCESS
    }

    _build_transfer_command() {
        local cmd_src="$1"
        local cmd_dest="$2"
        local cmd_transfer_cmd="rsync"
        local cmd_transfer_opts="-avh --progress" 

        if $dry_run && [[ "$cmd_transfer_cmd" == "rsync" ]]; then
             cmd_transfer_opts+=" --dry-run" 
        fi

        if [[ -n "$exclude_file" ]] && ! $use_scp; then 
            local current_exclude_patterns_opts_arr
            current_exclude_patterns_opts_arr=($(process_exclude_patterns)) 
            cmd_transfer_opts+=" ${current_exclude_patterns_opts_arr[@]}"
        fi

        if $use_scp; then
            cmd_transfer_cmd="scp"
            cmd_transfer_opts="-r" 
            [ -n "$port" ] && cmd_transfer_opts+=" -P $port"
            [ -n "$identity" ] && cmd_transfer_opts+=" -i $identity"
            $verbose && cmd_transfer_opts+=" -v"
        else 
            $move && ! ($dry_run && [[ "$cmd_transfer_opts" == *"--dry-run"* ]]) && cmd_transfer_opts+=" --remove-source-files"
            $move && ($dry_run && [[ "$cmd_transfer_opts" == *"--dry-run"* ]]) && cmd_transfer_opts+=" --remove-source-files" # show it for rsync's dry-run too

            [ -n "$limit" ] && cmd_transfer_opts+=" --bwlimit=$limit"
            
            local ssh_cmd_part=""
            [[ -n "$port" ]] && ssh_cmd_part+="ssh -p $port"
            if [[ -n "$identity" ]]; then
                [[ -n "$ssh_cmd_part" ]] && ssh_cmd_part+=" -i $identity" || ssh_cmd_part+="ssh -i $identity"
            fi
            [[ -n "$ssh_cmd_part" ]] && cmd_transfer_opts+=" -e '$ssh_cmd_part'"
        fi
        echo "$cmd_transfer_cmd $cmd_transfer_opts \"$cmd_src\" \"$cmd_dest\""
    }

    _execute_transfer() {
        local command_to_execute="$1"
        if $verbose || $dry_run; then 
            if $dry_run && [[ "$command_to_execute" != *"--dry-run"* ]]; then 
                echo_color $BLUE "[DRY RUN] Would execute transfer: $command_to_execute"
            elif $dry_run && [[ "$command_to_execute" == *"--dry-run"* ]]; then 
                 echo_color $BLUE "[DRY RUN] Executing rsync with --dry-run: $command_to_execute"
                 eval "$command_to_execute" || {
                    echo_color $RED "Rsync Dry-run Error: Command failed: $command_to_execute"
                    return $RCOPY_EXIT_TRANSFER_ERROR
                 }
                 return $RCOPY_EXIT_SUCCESS
            else 
                echo_color $YELLOW "Executing: $command_to_execute"
            fi
        fi

        if $dry_run && [[ "$command_to_execute" != *"--dry-run"* ]]; then 
            return $RCOPY_EXIT_SUCCESS 
        fi
        
        eval "$command_to_execute" || {
            local transfer_type="Transfer"
            if [[ "$command_to_execute" == scp* ]]; then transfer_type="SCP"; 
            elif [[ "$command_to_execute" == rsync* ]]; then transfer_type="Rsync"; fi
            echo_color $RED "$transfer_type Error: Command failed during execution of: $command_to_execute"
            return $RCOPY_EXIT_TRANSFER_ERROR
        }
        return $RCOPY_EXIT_SUCCESS
    }

    _handle_decompression() {
        local final_dest_path="$1"
        local compressed_basename="$2" 
        if ! $compress; then return $RCOPY_EXIT_SUCCESS; fi

        echo_color $YELLOW "Decompressing at destination..."
        local decompress_command_core="tar xzf '$compressed_basename' && rm -f '$compressed_basename'"
        
        if [[ "$final_dest_path" == *:* ]]; then 
            local target_host_part="${final_dest_path%%:*}"
            local dest_decompress_dir_remote="${final_dest_path#*:}"
            [[ "$dest_decompress_dir_remote" != */ ]] && dest_decompress_dir_remote=$(dirname "$dest_decompress_dir_remote")
            [ -z "$dest_decompress_dir_remote" ] && dest_decompress_dir_remote="."

            local ssh_opts_for_decomp=""
            [ -n "$port" ] && ssh_opts_for_decomp+=" -p $port"
            [ -n "$identity" ] && ssh_opts_for_decomp+=" -i $identity"
            local full_remote_decompress_cmd="ssh $ssh_opts_for_decomp \"$target_host_part\" \"cd '$dest_decompress_dir_remote' && $decompress_command_core\""

            if $dry_run; then
                 echo_color $BLUE "[DRY RUN] Would execute for remote decompression: $full_remote_decompress_cmd"
            else
                if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$target_host_part" true 2>/dev/null; then
                    echo_color $RED "Connection Error: Target host '$target_host_part' for decompression is not reachable."
                    return $RCOPY_EXIT_CONNECTION_ERROR
                fi
                eval "$full_remote_decompress_cmd" || {
                    echo_color $RED "Decompression Error: Command failed on remote host '$target_host_part': $full_remote_decompress_cmd"
                    return $RCOPY_EXIT_COMPRESSION_ERROR
                }
            fi
        else 
            local dest_decompress_dir_local="$final_dest_path"
            [[ "$dest_decompress_dir_local" != */ ]] && dest_decompress_dir_local=$(dirname "$final_dest_path")
            [ -z "$dest_decompress_dir_local" ] && dest_decompress_dir_local="." 

            local local_tarball_path="$dest_decompress_dir_local/$compressed_basename"
            local local_decompress_cmd="(cd \"$dest_decompress_dir_local\" && $decompress_command_core)"

            if $dry_run; then
                echo_color $BLUE "[DRY RUN] Would execute for local decompression: $local_decompress_cmd"
                if [ ! -e "$local_tarball_path" ]; then 
                    echo_color $YELLOW "[DRY RUN] Warning: Local tarball '$local_tarball_path' for decompression not found."
                fi
            else
                if [ ! -f "$local_tarball_path" ]; then
                    echo_color $RED "Decompression Error: Local tarball '$local_tarball_path' not found."
                    return $RCOPY_EXIT_PATH_NOT_FOUND 
                fi
                if [ ! -w "$dest_decompress_dir_local" ]; then 
                    echo_color $RED "Decompression Error: Local destination directory '$dest_decompress_dir_local' is not writable."
                    return $RCOPY_EXIT_PATH_NOT_FOUND 
                fi
                ($verbose) && echo_color $YELLOW "Local decompress command: $local_decompress_cmd"
                eval "$local_decompress_cmd" || {
                    echo_color $RED "Decompression Error: Command failed to decompress '$compressed_basename' in '$dest_decompress_dir_local': $local_decompress_cmd"
                    return $RCOPY_EXIT_COMPRESSION_ERROR
                }
            fi
        fi
        return $RCOPY_EXIT_SUCCESS
    }

    # --- Main rcopy logic ---
    _parse_options "$@"
    local parse_status=$?
    if [ $parse_status -ne $RCOPY_EXIT_SUCCESS ]; then return $parse_status; fi

    if $dry_run; then
        echo_color $BLUE "[DRY RUN] Dry run mode enabled. No actual changes will be made."
    fi

    if ! $sync_mode && [ "${#RCOPY_POSITIONAL_ARGS[@]}" -lt 2 ]; then
        echo_color $RED "Error: Missing source or destination arguments."
        echo "$usage" >&2; return $RCOPY_EXIT_INVALID_OPTION
    elif $sync_mode && [ "${#RCOPY_POSITIONAL_ARGS[@]}" -ne 2 ]; then
        echo_color $RED "Error: Sync mode requires exactly two path arguments."
        echo "$usage" >&2; return $RCOPY_EXIT_INVALID_OPTION
    fi

    local src="${RCOPY_POSITIONAL_ARGS[0]}"
    local dest="${RCOPY_POSITIONAL_ARGS[1]}"
    local src_for_cleanup="$src" 

    check_dependencies; local dep_status=$?
    if [ $dep_status -ne $RCOPY_EXIT_SUCCESS ]; then return $dep_status; fi

    if $sync_mode; then
        _perform_sync_mode "$src" "$dest"; return $?
    fi
    
    if [[ "$src" != *:* ]] && [ ! -e "$src" ] && ! $dry_run; then 
        echo_color $RED "Error: Source path '$src' not found or not accessible."
        return $RCOPY_EXIT_PATH_NOT_FOUND
    elif [[ "$src" != *:* ]] && [ ! -e "$src" ] && $dry_run; then
        echo_color $YELLOW "[DRY RUN] Warning: Source path '$src' not found. Proceeding with dry run."
    fi

    local current_src="$src" 
    local src_basename=$(basename "$src")

    if $compress; then
        local compressed_file_path
        compressed_file_path=$(_handle_compression "$current_src" "$src_basename")
        local compress_status=$?
        if [ $compress_status -ne $RCOPY_EXIT_SUCCESS ]; then return $compress_status; fi
        current_src="$compressed_file_path"
        src_basename=$(basename "$current_src") 
    fi
    
    local transfer_command=$(_build_transfer_command "$current_src" "$dest")
    _execute_transfer "$transfer_command"; local transfer_status=$?
    if [ $transfer_status -ne $RCOPY_EXIT_SUCCESS ]; then
        if $compress && [ -n "$temp_dir_compress" ] && ! $dry_run ; then 
            rm -rf "$temp_dir_compress"; temp_dir_compress=""
        fi
        return $transfer_status
    fi

    if $compress; then
        _handle_decompression "$dest" "$src_basename"; local decompress_status=$?
        if [ -n "$temp_dir_compress" ] && ! $dry_run; then
            rm -rf "$temp_dir_compress"; temp_dir_compress=""
        fi
        if [ $decompress_status -ne $RCOPY_EXIT_SUCCESS ]; then return $decompress_status; fi
    fi

    if $move; then
        if ( [ -e "$src_for_cleanup" ] || ($dry_run && [[ "$src_for_cleanup" == "$src" ]]) ); then
            local rm_cmd="rm -rf \"$src_for_cleanup\""
            echo_color $YELLOW "Move: Cleaning up source '$src_for_cleanup'..."
            if $dry_run; then
                echo_color $BLUE "[DRY RUN] Would execute for source cleanup: $rm_cmd"
                if [[ "$src_for_cleanup" != *:* ]] && [ ! -e "$src_for_cleanup" ]; then
                     echo_color $BLUE "[DRY RUN] Note: Original source '$src_for_cleanup' for move did not exist or was a placeholder."
                fi
            else
                if eval "$rm_cmd"; then 
                    echo_color $GREEN "Move: Successfully removed source '$src_for_cleanup'."
                else
                    echo_color $YELLOW "Move Warning: Failed to remove source '$src_for_cleanup'. Check permissions or if it's in use."
                fi
            fi
        elif $verbose && ! $dry_run; then 
            echo_color $YELLOW "Move: Source '$src_for_cleanup' already removed or did not exist."
        fi
    fi
    
    if $dry_run; then
        echo_color $GREEN "[DRY RUN] Operation dry run completed."
    else
        echo_color $GREEN "Operation completed successfully."
    fi
    return $RCOPY_EXIT_SUCCESS
}
# --- Autocomplete Helper Functions ---

# Suggests usernames
_ac_suggest_users() {
    local cur="$1"
    COMPREPLY=($(compgen -u -- "$cur"))
}

# Suggests SSH private key files (common extensions, excluding .pub)
_ac_suggest_ssh_keys() {
    local cur="$1"
    # Prioritize files in ~/.ssh
    if [[ -d ~/.ssh ]] && [[ "$cur" != '~/.ssh/'* ]]; then
        COMPREPLY=($(compgen -f -X '!*.@(pem|key|pub|config|known_hosts)' -P '~/.ssh/' -- ~/.ssh/"$cur"))
    else
        COMPREPLY=($(compgen -f -X '!*.@(pem|key|pub)' -- "$cur"))
    fi
}

# Suggests common SSH ports
_ac_suggest_common_ports() {
    local cur="$1"
    local ports=("22" "2222" "8022")
    COMPREPLY=($(compgen -W "${ports[*]}" -- "$cur"))
}

# Suggests sample bandwidth limits
_ac_suggest_bandwidth_limits() {
    local cur="$1"
    local limits=("100K" "500K" "1M" "2M" "5M" "10M" "50M" "100M") # Common rsync --bwlimit formats
    COMPREPLY=($(compgen -W "${limits[*]}" -- "$cur")) # No -S suffix, user types K/M
}

# Suggests common day counts
_ac_suggest_days() {
    local cur="$1"
    local days=("1" "3" "7" "14" "30" "60" "90")
    COMPREPLY=($(compgen -W "${days[*]}" -- "$cur"))
}

# Suggests common exclude patterns or completes local file/directory paths
_ac_suggest_exclude_patterns_or_paths() {
    local cur="$1"
    local common_patterns=(
        "*.log" "*.tmp" "*.temp" "*.bak" "*.swp" "*~" ".git/" ".svn/" ".hg/"
        "node_modules/" "vendor/" "build/" "dist/" "target/" "out/"
        ".DS_Store" "Thumbs.db" ".idea/" ".vscode/" "*.pyc" "*.class" "*.o"
        "*.tar.gz" "*.zip" "*.rar"
    )
    # If current input looks like an existing local path, prioritize path completion
    if [[ -n "$cur" && ( "$cur" == */* || "$cur" == ./* || "$cur" == ~/* || -e "$cur" ) ]]; then
        COMPREPLY=($(compgen -o default -- "$cur"))
    else
        # Combine common patterns and local file/directory suggestions
        local suggestions
        suggestions=$(printf "%s\n" "${common_patterns[@]}" $(compgen -f -d -- "$cur"))
        COMPREPLY=($(compgen -W "$suggestions" -- "$cur"))
    fi
}

# Fetches SSH hosts from known_hosts and ssh_config.
_ac_suggest_ssh_hosts() {
    local cur="$1"
    local hosts_array=()

    if [ -f ~/.ssh/known_hosts ]; then
        hosts_array+=($(
            awk '{ 
                # Skip hashed hosts, comments, or lines not starting with a hostname/IP
                if ($1 ~ /^[|#@]/) next 
                # Handle multiple hostnames on a line (comma-separated)
                split($1, host_entries, ",")
                for (i in host_entries) {
                    # Remove port if present (e.g., [host]:port)
                    gsub(/:[0-9]+$/, "", host_entries[i])
                    # Remove brackets for [host] format
                    gsub(/^\[|\]$/, "", host_entries[i])
                    print host_entries[i]
                }
            }' ~/.ssh/known_hosts
        ))
    fi
    if [ -f ~/.ssh/config ]; then
        hosts_array+=($(
            awk '
                tolower($1) == "host" {
                    for (i=2; i<=NF; i++) {
                        # Skip wildcard hosts and comments
                        if ($i ~ /[*?#]/) continue
                        print $i
                    }
                }
            ' ~/.ssh/config
        ))
    fi
    if [ -f /etc/hosts ]; then
        hosts_array+=($(
            awk '
                # Skip comments and empty lines
                $1 ~ /^#/ || $1 == "" {next}
                # Print all host aliases after the IP
                for (i=2; i<=NF; i++) {
                    # Stop if a comment char is found
                    if ($i ~ /#/) break
                    if ($i != "localhost" && $i != "::1" && $i != "127.0.0.1") print $i
                }
            ' /etc/hosts
        ))
    fi
    # Remove duplicates and filter by current input
    local unique_hosts=$(printf '%s\n' "${hosts_array[@]}" | sort -u)
    COMPREPLY=($(compgen -W "$unique_hosts" -- "$cur"))
}

# Completes remote paths using SSH. host_part should be user@host or host.
_ac_complete_remote_path_ssh() {
    local cur_full="$1" # The full current word, e.g., user@host:path/so/f
    local host_part="${cur_full%%:*}"
    local path_part="${cur_full#*:}" # Includes the colon initially if present

    if [[ "$cur_full" != *:* ]]; then # Not a remote path string yet
        return 1
    fi

    # If path_part is empty or just colon, it means we list from remote root for user
    [[ "$path_part" == ":" ]] && path_part=""


    local remote_listing
    # Use a short timeout for SSH to prevent long hangs if host is slow/unreachable
    # The `stty -echo` and `stty echo` are to prevent remote command output messing with terminal if it errors weirdly.
    # However, compgen functions should not print to stdout other than suggestions.
    # stderr from ssh is ignored by `2>/dev/null`.
    remote_listing=$(ssh -o ConnectTimeout=3 -o BatchMode=yes "$host_part" "ls -dp -- \"${path_part}*\" 2>/dev/null" 2>/dev/null)

    if [ -n "$remote_listing" ]; then
        local suggestions=()
        while IFS= read -r entry; do
            # Prepend host_part and colon to each entry for the completion
            suggestions+=("${host_part}:${entry}")
        done <<< "$remote_listing"
        COMPREPLY=($(compgen -W "${suggestions[*]}" -- "$cur_full"))
        return 0
    fi
    return 1
}

# Main path completion handler (local and remote)
_ac_complete_paths() {
    local cur="$1"
    # Try remote path completion first if ":" is present
    if [[ "$cur" == *:* ]]; then
        if _ac_complete_remote_path_ssh "$cur"; then
            return 0
        fi
        # If remote completion failed but ":" is present, it might be a partially typed host
        # or an invalid remote path. Fallback to suggesting hosts if path part is empty.
        local host_part_check="${cur%%:*}"
        local path_part_check="${cur#*:}"
        if [[ -z "$path_part_check" || "$path_part_check" == ":" ]]; then
             _ac_suggest_ssh_hosts "$host_part_check"
             # Add colon suffix to host suggestions if it's for the source/dest part
             local i
             for i in "${!COMPREPLY[@]}"; do
                 COMPREPLY[i]="${COMPREPLY[i]}:"
             done
             return 0
        fi
        # If path_part is not empty and remote completion failed, let it fall through to local,
        # though this is unlikely to be what user wants.
    fi
    # Default to local file/directory completion
    COMPREPLY=($(compgen -o default -- "$cur"))
}


# Main rcopy autocomplete function (refactored)
_rcopy_autocomplete() {
    local cur prev words cword
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD

    # General options for rcopy
    local general_opts=(
        "-z" "--compress" "-m" "--move" "-u" "--user" "-p" "--port"
        "-i" "--identity" "-l" "--limit" "-e" "--exclude" "-s" "--use-scp"
        "-v" "--verbose" "-n" "--dry-run" "-h" "--help" "-S" "--sync"
        "--source-host" "--target-host" "--days"
    )

    # Handle argument suggestions for options
    case "$prev" in
        -u|--user) _ac_suggest_users "$cur"; return 0 ;;
        -i|--identity) _ac_suggest_ssh_keys "$cur"; return 0 ;;
        -p|--port) _ac_suggest_common_ports "$cur"; return 0 ;;
        -l|--limit) _ac_suggest_bandwidth_limits "$cur"; return 0 ;;
        -e|--exclude) _ac_suggest_exclude_patterns_or_paths "$cur"; return 0 ;;
        --source-host|--target-host) _ac_suggest_ssh_hosts "$cur"; return 0 ;;
        --days) _ac_suggest_days "$cur"; return 0 ;;
        # Options that do not take arguments, or after which a new option/path is expected
        -z|--compress|-m|--move|-s|--use-scp|-v|--verbose|-n|--dry-run|-h|--help|-S|--sync)
            # Suggest general options or start path completion
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "${general_opts[*]}" -- "$cur"))
            else
                _ac_complete_paths "$cur"
            fi
            return 0 ;;
    esac

    # If current word starts with '-', suggest general options
    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "${general_opts[*]}" -- "$cur"))
        return 0
    fi

    # Default: path completion for source/destination arguments
    _ac_complete_paths "$cur"
    return 0
}
# Ensure the new autocomplete functions are defined before this line.
complete -F _rcopy_autocomplete rcopy

[end of rcopy.sh]
