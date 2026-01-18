#!/bin/bash
# report.sh - Report generation functions for hard link checker

set -euo pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Disable colors if not a terminal
if [[ ! -t 1 ]]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
    BOLD=''
fi

# Report state variables
declare -g MOVIES_CHECKED=0
declare -g TV_CHECKED=0
declare -g PROBLEMS_FOUND=0
declare -g PROBLEMS_FILE=""
declare -g SUGGESTIONS_FILE=""

# Initialize report files
init_report() {
    local report_dir="${REPORT_DIR:-./reports}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    mkdir -p "$report_dir"

    PROBLEMS_FILE="${report_dir}/problems_${timestamp}.txt"
    SUGGESTIONS_FILE="${report_dir}/suggestions_${timestamp}.txt"

    : > "$PROBLEMS_FILE"
    : > "$SUGGESTIONS_FILE"

    echo "Report initialized: $PROBLEMS_FILE"
}

# Print section header
print_header() {
    local title="$1"
    echo ""
    echo -e "${BOLD}=== $title ===${NC}"
    echo ""
}

# Print progress (inline update)
print_progress() {
    local current="$1"
    local total="$2"
    local type="$3"

    if [[ -t 1 ]]; then
        printf "\r  Checking %s: %d/%d" "$type" "$current" "$total"
    fi
}

# Clear progress line
clear_progress() {
    if [[ -t 1 ]]; then
        printf "\r%-60s\r" ""
    fi
}

# Log a problem file
# Usage: log_problem <type> <file_path> <inode> <links> [source_hint]
log_problem() {
    local type="$1"
    local file_path="$2"
    local inode="$3"
    local links="$4"
    local source_hint="${5:-}"

    ((PROBLEMS_FOUND++))

    # Write to problems file
    {
        echo "[${type}] ${file_path}"
        echo "  - Inode: ${inode}"
        echo "  - Links: ${links} (pas de hard link)"
        if [[ -n "$source_hint" ]]; then
            echo "  - Origine probable: ${source_hint}"
        fi
        echo ""
    } >> "$PROBLEMS_FILE"

    # If verbose, print immediately
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo -e "${RED}[${type}]${NC} ${file_path}"
        echo "  - Inode: ${inode}, Links: ${links}"
    fi
}

# Log a fix suggestion
# Usage: log_suggestion <source_path> <dest_path>
log_suggestion() {
    local source_path="$1"
    local dest_path="$2"

    echo "ln \"${source_path}\" \"${dest_path}\"" >> "$SUGGESTIONS_FILE"
}

# Log a general suggestion/comment
log_suggestion_comment() {
    local comment="$1"
    echo "# ${comment}" >> "$SUGGESTIONS_FILE"
}

# Increment movie counter
inc_movies() {
    ((MOVIES_CHECKED++))
}

# Increment TV counter
inc_tv() {
    ((TV_CHECKED++))
}

# Generate final summary
generate_summary() {
    local report_dir="${REPORT_DIR:-./reports}"

    print_header "Rapport Hard Links - $(date '+%Y-%m-%d %H:%M')"

    echo -e "${GREEN}✓${NC} Films vérifiés: ${MOVIES_CHECKED}"
    echo -e "${GREEN}✓${NC} Séries vérifiées: ${TV_CHECKED}"

    if [[ $PROBLEMS_FOUND -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} Aucun problème détecté!"
    else
        echo -e "${RED}✗${NC} Fichiers sans hard link: ${PROBLEMS_FOUND}"
    fi

    if [[ $PROBLEMS_FOUND -gt 0 ]]; then
        print_header "Fichiers problématiques"
        cat "$PROBLEMS_FILE"

        if [[ -s "$SUGGESTIONS_FILE" ]]; then
            print_header "Suggestions de correction"
            echo "# Pour recréer les hard links, relancer l'import dans Sonarr/Radarr"
            echo "# ou utiliser les commandes suivantes si les fichiers sources existent :"
            echo ""
            cat "$SUGGESTIONS_FILE"
        fi
    fi

    # Summary file location
    echo ""
    echo -e "${BLUE}Rapports sauvegardés dans:${NC}"
    echo "  - Problèmes: ${PROBLEMS_FILE}"
    echo "  - Suggestions: ${SUGGESTIONS_FILE}"
}

# Generate JSON report
generate_json_report() {
    local report_dir="${REPORT_DIR:-./reports}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local json_file="${report_dir}/report_${timestamp}.json"

    jq -n \
        --arg date "$(date -Iseconds)" \
        --argjson movies "$MOVIES_CHECKED" \
        --argjson tv "$TV_CHECKED" \
        --argjson problems "$PROBLEMS_FOUND" \
        --arg problems_file "$PROBLEMS_FILE" \
        --arg suggestions_file "$SUGGESTIONS_FILE" \
        '{
            date: $date,
            summary: {
                movies_checked: $movies,
                tv_checked: $tv,
                problems_found: $problems
            },
            files: {
                problems: $problems_file,
                suggestions: $suggestions_file
            }
        }' > "$json_file"

    echo "$json_file"
}

# Print a success message for a file
print_ok() {
    local file_path="$1"
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo -e "${GREEN}✓${NC} ${file_path}"
    fi
}

# Print an info message
print_info() {
    local message="$1"
    echo -e "${BLUE}ℹ${NC} ${message}"
}

# Print a warning message
print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠${NC} ${message}"
}

# Print an error message
print_error() {
    local message="$1"
    echo -e "${RED}✗${NC} ${message}" >&2
}

# Show only fix suggestions (for make fix-suggestions)
show_suggestions_only() {
    if [[ -f "$SUGGESTIONS_FILE" && -s "$SUGGESTIONS_FILE" ]]; then
        echo "#!/bin/bash"
        echo "# Hard link fix suggestions - $(date '+%Y-%m-%d %H:%M')"
        echo "# Review each command before executing!"
        echo ""
        cat "$SUGGESTIONS_FILE"
    else
        echo "# No fix suggestions available"
        echo "# Run 'make check' first to generate suggestions"
    fi
}
