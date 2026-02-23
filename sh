#!/usr/bin/env bash
# SyncUtility - Compare two folders and list differences in table format
# Read-only mode: no files are modified
# Compatible with Linux and macOS

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour / style helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    BOLD="\033[1m"; RESET="\033[0m"
    RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"
else
    BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; CYAN=""
fi

# ---------------------------------------------------------------------------
# Detect operating system
# ---------------------------------------------------------------------------
detect_os() {
    case "$(uname -s)" in
        Linux*)  OS="Linux"  ;;
        Darwin*) OS="macOS"  ;;
        *)       echo "ERROR: Unsupported OS '$(uname -s)'. Only Linux and macOS are supported." >&2; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Return human-readable file size (cross-platform)
# ---------------------------------------------------------------------------
human_size() {
    local file="$1"
    if [[ "$OS" == "macOS" ]]; then
        stat -f "%z" "$file" 2>/dev/null || echo "?"
    else
        stat -c "%s" "$file" 2>/dev/null || echo "?"
    fi
}

# ---------------------------------------------------------------------------
# Print usage
# ---------------------------------------------------------------------------
usage() {
    echo ""
    echo -e "${BOLD}Usage:${RESET}  ./sh start [FOLDER1] [FOLDER2]"
    echo ""
    echo "  Compares FOLDER1 and FOLDER2 recursively (read-only) and lists"
    echo "  every difference in a table: filename, relative path, difference"
    echo "  type, and which folder contains / differs."
    echo ""
    echo "  FOLDER1 and FOLDER2 may be absolute or relative paths."
    echo "  If omitted you will be prompted to enter them interactively."
    echo ""
    echo -e "${BOLD}Examples:${RESET}"
    echo "  ./sh start /mnt/drive1 /mnt/drive2"
    echo "  ./sh start /Volumes/Disk1 /Volumes/Disk2"
    echo ""
}

# ---------------------------------------------------------------------------
# Validate a directory path
# ---------------------------------------------------------------------------
validate_dir() {
    local label="$1"
    local path="$2"

    if [[ -z "$path" ]]; then
        echo "ERROR: $label path is empty." >&2; return 1
    fi
    if [[ ! -e "$path" ]]; then
        echo "ERROR: $label path does not exist: '$path'" >&2; return 1
    fi
    if [[ ! -d "$path" ]]; then
        echo "ERROR: $label path is not a directory: '$path'" >&2; return 1
    fi
    if [[ ! -r "$path" ]]; then
        echo "ERROR: $label path is not readable (check permissions): '$path'" >&2; return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Prompt user for a directory path
# ---------------------------------------------------------------------------
prompt_dir() {
    local label="$1"
    local path=""
    while true; do
        echo -n "Enter path for $label: "
        read -r path || { echo ""; echo "ERROR: Could not read input." >&2; exit 1; }
        # Expand ~ manually so validate_dir sees the real path
        path="${path/#\~/$HOME}"
        if validate_dir "$label" "$path"; then
            echo "$path"
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# Collect all relative file/dir paths under a root (read-only)
# ---------------------------------------------------------------------------
collect_paths() {
    local root="$1"
    # find exits non-zero if it encounters permission errors on sub-dirs;
    # we continue and report those separately.
    find "$root" -mindepth 1 2>/dev/null \
        | sed "s|^${root}/\{0,1\}||" \
        | sort
}

# ---------------------------------------------------------------------------
# Print a horizontal rule
# ---------------------------------------------------------------------------
hr() {
    local width="${1:-80}"
    local i
    for (( i = 0; i < width; i++ )); do printf '─'; done
    echo
}

# ---------------------------------------------------------------------------
# Print the results table
# ---------------------------------------------------------------------------
print_table() {
    local -a rows=("$@")

    # Column widths
    local w_file=30 w_rel=35 w_diff=32 w_folder=10
    local total=$(( w_file + w_rel + w_diff + w_folder + 13 ))

    echo ""
    hr "$total"
    printf "${BOLD}| %-${w_file}s | %-${w_rel}s | %-${w_diff}s | %-${w_folder}s |${RESET}\n" \
        "FILENAME" "RELATIVE PATH" "DIFFERENCE" "FOLDER"
    hr "$total"

    if [[ ${#rows[@]} -eq 0 ]]; then
        printf "| %-$(( total - 4 ))s |\n" "No differences found – folders are identical."
        hr "$total"
        echo ""
        return
    fi

    for row in "${rows[@]}"; do
        IFS='|' read -r fname relpath diff folder <<< "$row"
        # Colour-code by difference type
        local colour="$RESET"
        case "$diff" in
            "Only in Folder 1")    colour="$YELLOW" ;;
            "Only in Folder 2")    colour="$GREEN"  ;;
            "Content differs")     colour="$RED"    ;;
            "Size differs")        colour="$RED"    ;;
            "Type differs")        colour="$CYAN"   ;;
            "Permission error")    colour="$CYAN"   ;;
        esac
        # Truncate long strings to keep columns tidy
        fname="${fname:0:$w_file}"
        relpath="${relpath:0:$w_rel}"
        diff="${diff:0:$w_diff}"
        folder="${folder:0:$w_folder}"
        printf "${colour}| %-${w_file}s | %-${w_rel}s | %-${w_diff}s | %-${w_folder}s |${RESET}\n" \
            "$fname" "$relpath" "$diff" "$folder"
    done

    hr "$total"
    echo ""
}

# ---------------------------------------------------------------------------
# Core comparison logic (read-only)
# ---------------------------------------------------------------------------
compare_folders() {
    local dir1="$1"
    local dir2="$2"

    # Canonicalise paths (resolve symlinks where possible)
    if [[ "$OS" == "macOS" ]]; then
        dir1="$(cd "$dir1" && pwd -P)"
        dir2="$(cd "$dir2" && pwd -P)"
    else
        dir1="$(realpath "$dir1")"
        dir2="$(realpath "$dir2")"
    fi

    echo ""
    echo -e "${BOLD}Folder 1:${RESET} $dir1"
    echo -e "${BOLD}Folder 2:${RESET} $dir2"
    echo ""
    echo "Scanning folders (read-only) …"

    local paths1 paths2 all_paths
    paths1="$(collect_paths "$dir1")"
    paths2="$(collect_paths "$dir2")"

    # Union of both path lists, sorted and de-duplicated
    all_paths="$(printf '%s\n%s\n' "$paths1" "$paths2" | sort -u)"

    if [[ -z "$all_paths" ]]; then
        echo "Both folders are empty – no files to compare."
        return 0
    fi

    local -a rows=()
    local count=0

    while IFS= read -r relpath; do
        [[ -z "$relpath" ]] && continue

        local full1="${dir1}/${relpath}"
        local full2="${dir2}/${relpath}"
        local fname; fname="$(basename "$relpath")"
        local diff_type="" folder_info=""

        local exists1=false exists2=false
        [[ -e "$full1" || -L "$full1" ]] && exists1=true
        [[ -e "$full2" || -L "$full2" ]] && exists2=true

        if $exists1 && ! $exists2; then
            diff_type="Only in Folder 1"
            folder_info="Folder 1"

        elif ! $exists1 && $exists2; then
            diff_type="Only in Folder 2"
            folder_info="Folder 2"

        elif $exists1 && $exists2; then
            # Both exist – check type first
            local type1="" type2=""
            [[ -d "$full1" ]] && type1="dir"  || type1="file"
            [[ -d "$full2" ]] && type2="dir"  || type2="file"
            [[ -L "$full1" ]] && type1="link"
            [[ -L "$full2" ]] && type2="link"

            if [[ "$type1" != "$type2" ]]; then
                diff_type="Type differs"
                folder_info="Both"

            elif [[ "$type1" == "dir" ]]; then
                # Directories themselves: no content diff needed; children handled separately
                continue

            else
                # Regular files: compare size then content
                local size1 size2
                if [[ -r "$full1" && -r "$full2" ]]; then
                    size1="$(human_size "$full1")"
                    size2="$(human_size "$full2")"
                    if [[ "$size1" != "$size2" ]]; then
                        diff_type="Size differs (${size1} vs ${size2} bytes)"
                        folder_info="Both"
                    else
                        # Same size – compare content (read-only)
                        if ! cmp -s "$full1" "$full2" 2>/dev/null; then
                            diff_type="Content differs"
                            folder_info="Both"
                        fi
                        # else identical – skip
                    fi
                else
                    diff_type="Permission error"
                    folder_info="Both"
                fi
            fi
        fi

        if [[ -n "$diff_type" ]]; then
            rows+=("${fname}|${relpath}|${diff_type}|${folder_info}")
            (( count++ )) || true
        fi

    done <<< "$all_paths"

    print_table "${rows[@]+"${rows[@]}"}"

    if [[ $count -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✔  Folders are identical.${RESET}"
    else
        echo -e "${YELLOW}${BOLD}!  ${count} difference(s) found.${RESET}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    detect_os

    # Require at least 'start' as the first argument
    if [[ $# -lt 1 ]]; then
        echo -e "${RED}ERROR: Missing argument. Use 'start' to begin.${RESET}" >&2
        usage
        exit 1
    fi

    local cmd="$1"; shift

    case "$cmd" in
        start)
            ;;
        --help|-h|help)
            usage; exit 0 ;;
        *)
            echo -e "${RED}ERROR: Unknown command '${cmd}'. Use 'start'.${RESET}" >&2
            usage; exit 1 ;;
    esac

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║         SyncUtility – Folder Diff    ║${RESET}"
    echo -e "${BOLD}║         (read-only comparison)       ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "OS detected: ${CYAN}${OS}${RESET}"

    local dir1="" dir2=""

    # Accept optional folder arguments: ./sh start FOLDER1 FOLDER2
    if [[ $# -ge 1 ]]; then
        dir1="$1"; shift
        dir1="${dir1/#\~/$HOME}"
        validate_dir "Folder 1" "$dir1" || exit 1
    else
        dir1="$(prompt_dir "Folder 1")"
    fi

    if [[ $# -ge 1 ]]; then
        dir2="$1"; shift
        dir2="${dir2/#\~/$HOME}"
        validate_dir "Folder 2" "$dir2" || exit 1
    else
        dir2="$(prompt_dir "Folder 2")"
    fi

    compare_folders "$dir1" "$dir2"
}

main "$@"
