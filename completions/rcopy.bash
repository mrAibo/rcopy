_rcopy_complete() {
    local current previous
    COMPREPLY=()
    current=${COMP_WORDS[COMP_CWORD]}
    previous=${COMP_WORDS[COMP_CWORD-1]}

    case "${previous}" in
        -i|--identity|-e|--exclude|-L|--log)
            mapfile -t COMPREPLY < <(compgen -f -- "${current}")
            return
            ;;
        -p|--port)
            mapfile -t COMPREPLY < <(compgen -W '22 2222 8022' -- "${current}")
            return
            ;;
        -l|--limit)
            mapfile -t COMPREPLY < <(compgen -W '1024 2048 5120 10240 51200 102400' -- "${current}")
            return
            ;;
        --days)
            mapfile -t COMPREPLY < <(compgen -W '1 7 14 30 90' -- "${current}")
            return
            ;;
    esac

    if [[ ${current} == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W '-z --compress -m --move -u --user -p --port -i --identity -l --limit -e --exclude -s --use-scp -v --verbose -d --dry-run -f --force -r --resume -q --quick -L --log -S --sync --source-host --target-host --days --version -h --help' -- "${current}")
        return
    fi

    mapfile -t COMPREPLY < <(compgen -f -- "${current}")
}

complete -o filenames -F _rcopy_complete rcopy
