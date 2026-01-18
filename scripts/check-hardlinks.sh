#!/bin/bash
# check-hardlinks.sh - Main verification script for Sonarr/Radarr hard links

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source helper scripts
source "${SCRIPT_DIR}/api-helper.sh"
source "${SCRIPT_DIR}/report.sh"

# Load configuration
load_config() {
    local config_file="${PROJECT_DIR}/config.env"

    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
    else
        print_error "Configuration file not found: $config_file"
        print_info "Copy config.env.example to config.env and configure it"
        exit 1
    fi

    # Validate required variables
    local missing=()
    [[ -z "${SONARR_URL:-}" ]] && missing+=("SONARR_URL")
    [[ -z "${SONARR_API_KEY:-}" ]] && missing+=("SONARR_API_KEY")
    [[ -z "${RADARR_URL:-}" ]] && missing+=("RADARR_URL")
    [[ -z "${RADARR_API_KEY:-}" ]] && missing+=("RADARR_API_KEY")
    [[ -z "${DOWNLOADS_PATH:-}" ]] && missing+=("DOWNLOADS_PATH")
    [[ -z "${MEDIA_PATH:-}" ]] && missing+=("MEDIA_PATH")

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required configuration: ${missing[*]}"
        exit 1
    fi

    # Set defaults for optional variables
    MOVIES_DOWNLOAD_SUBDIR="${MOVIES_DOWNLOAD_SUBDIR:-movies}"
    TV_DOWNLOAD_SUBDIR="${TV_DOWNLOAD_SUBDIR:-tv}"
    MOVIES_MEDIA_SUBDIR="${MOVIES_MEDIA_SUBDIR:-movies}"
    TV_MEDIA_SUBDIR="${TV_MEDIA_SUBDIR:-tv}"
    REPORT_DIR="${REPORT_DIR:-${PROJECT_DIR}/reports}"
    VERBOSE="${VERBOSE:-false}"

    # Docker path mappings (optional)
    DOCKER_PATH_MAP_MOVIES="${DOCKER_PATH_MAP_MOVIES:-}"
    DOCKER_PATH_MAP_TV="${DOCKER_PATH_MAP_TV:-}"
    DOCKER_PATH_MAP_DOWNLOADS="${DOCKER_PATH_MAP_DOWNLOADS:-}"

    export REPORT_DIR VERBOSE
}

# Translate Docker container path to host path
# Usage: translate_path <container_path>
# Applies all configured path mappings in order (most specific first)
translate_path() {
    local path="$1"
    local result="$path"

    # Apply movies path mapping (most specific, check first)
    if [[ -n "${DOCKER_PATH_MAP_MOVIES:-}" ]]; then
        local container_path="${DOCKER_PATH_MAP_MOVIES%%:*}"
        local host_path="${DOCKER_PATH_MAP_MOVIES#*:}"
        if [[ "$result" == "$container_path"* ]]; then
            result="${result/#$container_path/$host_path}"
            echo "$result"
            return
        fi
    fi

    # Apply TV path mapping
    if [[ -n "${DOCKER_PATH_MAP_TV:-}" ]]; then
        local container_path="${DOCKER_PATH_MAP_TV%%:*}"
        local host_path="${DOCKER_PATH_MAP_TV#*:}"
        if [[ "$result" == "$container_path"* ]]; then
            result="${result/#$container_path/$host_path}"
            echo "$result"
            return
        fi
    fi

    # Apply downloads path mapping
    if [[ -n "${DOCKER_PATH_MAP_DOWNLOADS:-}" ]]; then
        local container_path="${DOCKER_PATH_MAP_DOWNLOADS%%:*}"
        local host_path="${DOCKER_PATH_MAP_DOWNLOADS#*:}"
        if [[ "$result" == "$container_path"* ]]; then
            result="${result/#$container_path/$host_path}"
            echo "$result"
            return
        fi
    fi

    echo "$result"
}

# Check if a file has hard links
# Returns 0 if file has hard links (links > 1), 1 otherwise
# Usage: has_hardlinks <file_path>
has_hardlinks() {
    local file_path="$1"

    if [[ ! -f "$file_path" ]]; then
        return 1
    fi

    local links
    links=$(stat -c '%h' "$file_path" 2>/dev/null || stat -f '%l' "$file_path" 2>/dev/null)

    [[ "$links" -gt 1 ]]
}

# Get inode of a file
# Usage: get_inode <file_path>
get_inode() {
    local file_path="$1"

    stat -c '%i' "$file_path" 2>/dev/null || stat -f '%i' "$file_path" 2>/dev/null || echo "0"
}

# Get link count of a file
# Usage: get_link_count <file_path>
get_link_count() {
    local file_path="$1"

    stat -c '%h' "$file_path" 2>/dev/null || stat -f '%l' "$file_path" 2>/dev/null || echo "0"
}

# Find files with same inode in a directory
# Usage: find_hardlinks_in_dir <inode> <search_dir>
find_hardlinks_in_dir() {
    local inode="$1"
    local search_dir="$2"

    if [[ ! -d "$search_dir" ]]; then
        return 0
    fi

    find "$search_dir" -inum "$inode" -type f 2>/dev/null || true
}

# Check a single media file
# Usage: check_media_file <type> <file_path> <downloads_dir> [source_hint]
check_media_file() {
    local type="$1"
    local file_path="$2"
    local downloads_dir="$3"
    local source_hint="${4:-}"

    if [[ ! -f "$file_path" ]]; then
        print_warning "File not found: $file_path"
        return 0
    fi

    local inode links
    inode=$(get_inode "$file_path")
    links=$(get_link_count "$file_path")

    # Quick check: if links > 1, the file has hard links somewhere
    if [[ "$links" -gt 1 ]]; then
        print_ok "$file_path (links: $links)"
        return 0
    fi

    # Links = 1 means no hard link exists
    log_problem "$type" "$file_path" "$inode" "$links" "$source_hint"

    # Try to suggest a fix
    if [[ -n "$source_hint" && -f "$source_hint" ]]; then
        log_suggestion "$source_hint" "$file_path"
    else
        log_suggestion_comment "Source unknown for: $file_path"
    fi
}

# Check movies via Radarr API
check_movies_api() {
    print_info "Fetching movies from Radarr..."

    local movies_json
    if ! movies_json=$(get_radarr_movies); then
        print_error "Failed to fetch movies from Radarr"
        return 1
    fi

    local total
    total=$(echo "$movies_json" | jq '[.[] | select(.hasFile == true)] | length')
    print_info "Found $total movies with files"

    local downloads_dir="${DOWNLOADS_PATH}/${MOVIES_DOWNLOAD_SUBDIR}"
    local count=0

    # Process each movie
    while IFS=$'\t' read -r movie_id title file_path; do
        [[ -z "$file_path" ]] && continue
        ((count++)) || true
        print_progress "$count" "$total" "movies"
        inc_movies

        # Translate Docker path to host path
        local host_path
        host_path=$(translate_path "$file_path")

        if [[ "${VERBOSE:-false}" == "true" && "$host_path" != "$file_path" ]]; then
            print_info "Path translated: $file_path -> $host_path"
        fi

        check_media_file "FILM" "$host_path" "$downloads_dir" ""
    done < <(echo "$movies_json" | parse_radarr_movies)

    clear_progress
    print_info "Checked $count movies"
}

# Check TV shows via Sonarr API
check_tv_api() {
    print_info "Fetching series from Sonarr..."

    local series_json
    if ! series_json=$(get_sonarr_series); then
        print_error "Failed to fetch series from Sonarr"
        return 1
    fi

    local series_count
    series_count=$(echo "$series_json" | jq 'length')
    print_info "Found $series_count series"

    local downloads_dir="${DOWNLOADS_PATH}/${TV_DOWNLOAD_SUBDIR}"
    local total_episodes=0
    local count=0

    # Process each series
    while IFS=$'\t' read -r series_id series_title; do
        print_info "Checking: $series_title"

        local episode_files
        if ! episode_files=$(get_sonarr_episode_files "$series_id"); then
            print_warning "Failed to fetch episodes for $series_title"
            continue
        fi

        local episode_count
        episode_count=$(echo "$episode_files" | jq 'length')
        ((total_episodes += episode_count)) || true

        # Process each episode file
        while IFS=$'\t' read -r ep_path; do
            [[ -z "$ep_path" ]] && continue
            ((count++)) || true
            inc_tv

            # Translate Docker path to host path
            local host_path
            host_path=$(translate_path "$ep_path")

            check_media_file "SÉRIE" "$host_path" "$downloads_dir" ""
        done < <(echo "$episode_files" | jq -r '.[].path // empty')

    done < <(echo "$series_json" | jq -r '.[] | [.id, .title] | @tsv')

    print_info "Checked $count episodes across $series_count series"
}

# Fallback: Check movies by scanning filesystem
check_movies_filesystem() {
    local media_dir="${MEDIA_PATH}/${MOVIES_MEDIA_SUBDIR}"
    local downloads_dir="${DOWNLOADS_PATH}/${MOVIES_DOWNLOAD_SUBDIR}"

    if [[ ! -d "$media_dir" ]]; then
        print_error "Movies media directory not found: $media_dir"
        return 1
    fi

    print_info "Scanning movies directory: $media_dir"

    local count=0
    while IFS= read -r -d '' file_path; do
        ((count++))
        inc_movies
        check_media_file "FILM" "$file_path" "$downloads_dir" ""

        if ((count % 10 == 0)); then
            print_progress "$count" "?" "movies"
        fi
    done < <(find "$media_dir" -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" \) -print0)

    clear_progress
    print_info "Checked $count movie files"
}

# Fallback: Check TV shows by scanning filesystem
check_tv_filesystem() {
    local media_dir="${MEDIA_PATH}/${TV_MEDIA_SUBDIR}"
    local downloads_dir="${DOWNLOADS_PATH}/${TV_DOWNLOAD_SUBDIR}"

    if [[ ! -d "$media_dir" ]]; then
        print_error "TV media directory not found: $media_dir"
        return 1
    fi

    print_info "Scanning TV directory: $media_dir"

    local count=0
    while IFS= read -r -d '' file_path; do
        ((count++))
        inc_tv
        check_media_file "SÉRIE" "$file_path" "$downloads_dir" ""

        if ((count % 10 == 0)); then
            print_progress "$count" "?" "episodes"
        fi
    done < <(find "$media_dir" -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" \) -print0)

    clear_progress
    print_info "Checked $count TV files"
}

# Main check function for movies
check_movies() {
    local use_api="${1:-true}"

    if [[ "$use_api" == "true" ]]; then
        if test_api_connection radarr >/dev/null 2>&1; then
            check_movies_api
        else
            print_warning "Radarr API not available, falling back to filesystem scan"
            check_movies_filesystem
        fi
    else
        check_movies_filesystem
    fi
}

# Main check function for TV
check_tv() {
    local use_api="${1:-true}"

    if [[ "$use_api" == "true" ]]; then
        if test_api_connection sonarr >/dev/null 2>&1; then
            check_tv_api
        else
            print_warning "Sonarr API not available, falling back to filesystem scan"
            check_tv_filesystem
        fi
    else
        check_tv_filesystem
    fi
}

# Main entry point
main() {
    local mode="${1:-all}"

    check_dependencies
    load_config
    init_report

    print_header "Vérification des Hard Links"
    print_info "Downloads: ${DOWNLOADS_PATH}"
    print_info "Media: ${MEDIA_PATH}"

    case "$mode" in
        all)
            check_movies
            check_tv
            ;;
        movies)
            check_movies
            ;;
        tv)
            check_tv
            ;;
        movies-fs)
            check_movies false
            ;;
        tv-fs)
            check_tv false
            ;;
        test-api)
            echo "Testing API connections..."
            test_api_connection radarr || true
            test_api_connection sonarr || true
            exit 0
            ;;
        *)
            echo "Usage: $0 [all|movies|tv|movies-fs|tv-fs|test-api]"
            exit 1
            ;;
    esac

    generate_summary

    # Exit with error code if problems found
    [[ $PROBLEMS_FOUND -eq 0 ]]
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
