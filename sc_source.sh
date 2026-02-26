#!/bin/bash

# Configuration
if [[ -d "$1" ]]; then
    SEARCH_DIR="$1"
else
    SEARCH_DIR="."
fi
INDEX_FILE="${SEARCH_DIR}/.scviewer_index.db"
INDEX_TAB_FILE="${SEARCH_DIR}/.scviewer_index_tab.db"
TEMP_FIND_LIST="${SEARCH_DIR}/.scviewer_files.txt"
TEMP_RAW_DB="${SEARCH_DIR}/.scviewer_raw.db"
TEMP_RAW_TAB_DB="${SEARCH_DIR}/.scviewer_raw_tab.db"

#TODO
# ownership/permissions of files
# fix search dir from being included in index
# add check if called by source. "Scanning for supportconfig files in: is"

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: source sc_viewer.sh [directory]"
    echo "  (You must source this script to enable autocomplete)"
    echo
    echo "  1. Go to your extracted supportconfig directory."
    echo "  2. Run: source ./sc_viewer.sh ."
    echo
    echo "  Commands:"
    echo "    scview <entry>                    : Print entry to stdout (Default)"
    echo "    scview -d <dir> <entry>           : Search in specific supportconfig directory"
    echo "    scview less <entry>               : Pipe entry to 'less'"
    echo "    scview cat <entry>                : Print entry to stdout (Explicit)"
    echo "    scview diff <dir1> <dir2> <entry> : Diff entry between two supportconfigs"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    usage
    exit 1
fi

if [[ ! -f "${SEARCH_DIR}/supportconfig.txt" ]]; then
    echo -e "${RED}Error${NC}: supportconfig.txt file not found in ${SEARCH_DIR}"
    return 1
fi

generate_index() {
    echo -e "${GREEN}Scanning for supportconfig files in: ${SEARCH_DIR}${NC}"
    # Truncate $TEMP_RAW_DB to prevent issues if script is run multiple times
    : > "$TEMP_RAW_DB"
    find "$SEARCH_DIR" -type f -name "*.txt" > "$TEMP_FIND_LIST"
    
    # Ensure there were .txt files found
    local file_count=$(wc -l < "$TEMP_FIND_LIST")
    if [[ "$file_count" -eq 0 ]]; then
        echo -e "${RED}No .txt files found in $SEARCH_DIR${NC}"
        return 1
    fi

    # Parse files into a raw DB
    awk -v out_file2="$TEMP_RAW_TAB_DB" -v out_file="$TEMP_RAW_DB" '
    /^#==\[/ {
        # Check if this is a section we want to index
        # We look for "Command" or "File" (covers Config File, Text File, Log File)
        if ($0 ~ /Command/) {
            is_command = 1
            valid_header = 1
        } else if ($0 ~ /File/) {
            is_command = 0
            valid_header = 1
        } else {
            valid_header = 0
        }

        if (valid_header) {
            header_found = 1
            start_line = FNR
            next
        }
    }

    header_found == 1 {
        raw_cmd = $0

        # Remove "cat" when exists (Common to all)
        sub(/cat /, "", raw_cmd)
        # Remove leading # and whitespace (Common to all)
        sub(/^#[[:space:]]*/, "", raw_cmd)

        # LOGIC BRANCH:
        # If it is a COMMAND, strip the binary path (/sbin/foo -> foo)
        # If it is a FILE, leave the path alone (/etc/foo -> /etc/foo)
        if (is_command == 1) {
            sub(/^(\/[^ \/]+)+\//, "", raw_cmd)
        }

        # Sanitization (Common to all):
        # 1. Remove all quotes (single quote is \047 to avoid shell conflict)
        gsub(/[\047"]/, "", raw_cmd)
        # 2. Trim trailing whitespace
        sub(/[[:space:]]+$/, "", raw_cmd)
        # 3. Collapse multiple internal spaces
        gsub(/[[:space:]]+/, " ", raw_cmd)

        if (length(raw_cmd) > 0) {
            # Format: CLEAN_CMD;FULL_FILE_PATH;LINE_NUMBER
            printf "%s;%s;%d\n", raw_cmd, FILENAME, start_line >> out_file
        }

        # prepend all special bash characters with \ for bash completion (Common to all)
        gsub(/\|/, "\\|", raw_cmd)
        gsub(/\@/, "\\@", raw_cmd)
        gsub(/\?/, "\\?", raw_cmd)
        gsub(/\$/, "\\$", raw_cmd)
        gsub(/\!/, "\\!", raw_cmd)
        gsub(/`/, "\\`", raw_cmd)
        gsub(/\*/, "\\*", raw_cmd)
        gsub(/</, "\\<", raw_cmd)
        gsub(/>/, "\\>", raw_cmd)
        gsub(/\&/, "\\\\&", raw_cmd)
        gsub(/\(/, "\\(", raw_cmd)
        gsub(/\)/, "\\)", raw_cmd)

        if (length(raw_cmd) > 0) {
            printf "%s;%s;%d\n", raw_cmd, FILENAME, start_line >> out_file2
        }

        header_found=0
    }' $(cat "$TEMP_FIND_LIST")

    # Sort and Deduplicate
    sort -t';' -k1,1 -u "$TEMP_RAW_DB" > "$INDEX_FILE"
    sort -t';' -k1,1 -u "$TEMP_RAW_TAB_DB" > "$INDEX_TAB_FILE"

    # Cleanup temp
    rm -f "$TEMP_RAW_DB" "$TEMP_FIND_LIST" "$TEMP_RAW_TAB_DB"

    local count=$(wc -l < "$INDEX_FILE")
    echo -e "${GREEN}Index built. Found ${count} unique entries.${NC}"
    echo -e "Type ${CYAN}scview <tab>${NC} to see available commands."
}

scview() {
    local use_pager=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -d)
          SEARCH_DIR="$2"
          shift 2
          ;;
        -d*)
          SEARCH_DIR="${1#-d}"
          shift
          ;;
        less)
          use_pager=1
          shift
          ;;
        cat)
          use_pager=0
          shift
          ;;
        --)
          shift
          break
          ;;
        *)
          break
          ;;
      esac
    done


# Diff section. First check for diff and "directories" parameters. 
    if [[ "$1" == "diff" && -n "$2" && -n "$3" ]]; then
        SC1="$2"
        SC2="$3"
        SC1_INDEX_FILE="$2/.scviewer_index.db"
        SC2_INDEX_FILE="$3/.scviewer_index.db"

        if [[ ! -f "$SC1_INDEX_FILE" ]]; then
            echo -e "${RED}Error: Index file not found in $2. Run 'sc_viewer.sh $2' first.${NC}"
            return 1
        fi
        if [[ ! -f "$SC2_INDEX_FILE" ]]; then
            echo -e "${RED}Error: Index file not found in $3. Run 'sc_viewer.sh $3' first.${NC}"
            return 1
        fi

        #Select the last parameter when running scview for the command or file to run.
        local selection="${@: -1}"
        # Exact match lookup in the DB
        local entry1 entry2
        entry=$(awk -F';' -v search="$selection" '$1 == search {print $0; exit}' "$SC1_INDEX_FILE")
        entry1=$(scview -d "$SC1" "$selection")
        entry2=$(scview -d "$SC2" "$selection")

        if [[ -z "$entry1" && -z "$entry2" ]]; then
            echo -e "${RED}Error: Command '${selection}' not found in either index.${NC}"
            return 1
        fi
        
        # Safe parsing
        local cmd_name file_path start_line
        IFS=';' read -r cmd_name file_path start_line <<< "$entry"

        print_content() {
            echo -e "${CYAN}Diffing: ${cmd_name}${NC} [File: ${file_path}]"
            echo -e "--- ${SC1}/${file_path} ---"
            echo -e "+++ ${SC2}/${file_path} ---"
            echo "--------------------------------------------------------"
            git diff --no-index --color=always <(echo "$entry1") <(echo "$entry2")
            }

    else

        local selection="$*"

        if [[ -z "$selection" ]]; then
            echo "Usage: scview [less|cat] <command_or_file>"
            return 1
        fi

        # Exact match lookup in the DB
        local entry
        entry=$(awk -F';' -v search="$selection" '$1 == search {print $0; exit}' "$SEARCH_DIR"/"$INDEX_FILE")

        if [[ -z "$entry" ]]; then
            echo -e "${RED}Error: Command '${selection}' not found in index "$SEARCH_DIR"/"$INDEX_FILE"${NC}"
            return 1
        fi

        # Safe parsing
        local cmd_name file_path start_line
        IFS=';' read -r cmd_name file_path start_line <<< "$entry"

        print_content() {
            echo -e "${CYAN}Viewing: ${cmd_name}${NC} [File: ${SEARCH_DIR}/${file_path}]"
            echo "--------------------------------------------------------"
            sed -n "${start_line},\$p" "$SEARCH_DIR"/"$file_path" | awk 'NR > 1 && /^#==\[/ { exit } { print }'
            }


    fi

    if [[ "$use_pager" -eq 1 ]]; then
        print_content | less
    else
        print_content
    fi
}

# --- AUTOCOMPLETE ---
_scview_completions() {
    # Disable default Bash completion (like file/dir lookups) if our script 
    # doesn't find a match. This keeps the UI clean.
    compopt +o default 2>/dev/null

    # The word currently being typed by the user
    cur="${COMP_WORDS[COMP_CWORD]}"

    if [[ ! -f "$INDEX_TAB_FILE" ]]; then
        return
    fi

    # Determine where the actual search term starts. If the user typed 'scview cat ...' or 'scview less ...', the search term 
    # starts at index 2. Otherwise, it starts at index 1.
    # TODO - consider moving this functionality to the #CASE like diff
    local start_index=1
    if [[ "${COMP_WORDS[1]}" == "cat" || "${COMP_WORDS[1]}" == "less" ]]; then
        if [[ $COMP_CWORD -ge 2 ]]; then
             start_index=2
        fi
    fi

    # Reconstruct the string typed so far before the current cursor position.
    local prefix=""
    for (( i=start_index; i<COMP_CWORD; i++ )); do
        prefix+="${COMP_WORDS[i]} "
    done
    # The full string we are looking for in the index
    local full_search="${prefix}${cur}"

    # Search DB and extract only the command name
    local matches
    matches=$(grep "^${full_search}" "$INDEX_TAB_FILE" | cut -d';' -f1)

    local IFS=$'\n'
    COMPREPLY=()

    # Populate the completion reply list.
    for cmd in $matches; do
        # Remove "prefix" for bash completion
        local prefix_len=${#prefix}
        local suggestion="${cmd:$prefix_len}"

        if [[ -n "$suggestion" ]]; then
            COMPREPLY+=("$suggestion")
        fi
    done
}

# Run the indexer
generate_index "$1"

# Register the autocomplete
complete -F _scview_completions scview
