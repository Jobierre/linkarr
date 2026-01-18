#!/bin/bash
# api-helper.sh - Functions for Sonarr/Radarr API interactions

set -euo pipefail

# Check required dependencies
check_dependencies() {
    local missing=()
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required dependencies: ${missing[*]}" >&2
        echo "Install them with: apt-get install ${missing[*]}" >&2
        return 1
    fi
}

# Generic API request function
# Usage: api_request <base_url> <api_key> <endpoint>
api_request() {
    local base_url="$1"
    local api_key="$2"
    local endpoint="$3"

    curl -s -f \
        -H "X-Api-Key: ${api_key}" \
        -H "Accept: application/json" \
        "${base_url}/api/v3/${endpoint}"
}

# Get all movies from Radarr
# Returns JSON array of movies with their file paths
get_radarr_movies() {
    local url="${RADARR_URL:-http://localhost:7878}"
    local api_key="${RADARR_API_KEY:-}"

    if [[ -z "$api_key" ]]; then
        echo "ERROR: RADARR_API_KEY not set" >&2
        return 1
    fi

    api_request "$url" "$api_key" "movie"
}

# Get movie file details from Radarr
# Usage: get_radarr_movie_files <movie_id>
get_radarr_movie_files() {
    local movie_id="$1"
    local url="${RADARR_URL:-http://localhost:7878}"
    local api_key="${RADARR_API_KEY:-}"

    api_request "$url" "$api_key" "moviefile?movieId=${movie_id}"
}

# Get all series from Sonarr
get_sonarr_series() {
    local url="${SONARR_URL:-http://localhost:8989}"
    local api_key="${SONARR_API_KEY:-}"

    if [[ -z "$api_key" ]]; then
        echo "ERROR: SONARR_API_KEY not set" >&2
        return 1
    fi

    api_request "$url" "$api_key" "series"
}

# Get episode files for a series from Sonarr
# Usage: get_sonarr_episode_files <series_id>
get_sonarr_episode_files() {
    local series_id="$1"
    local url="${SONARR_URL:-http://localhost:8989}"
    local api_key="${SONARR_API_KEY:-}"

    api_request "$url" "$api_key" "episodefile?seriesId=${series_id}"
}

# Get all episode files from Sonarr (paginated, fetches all)
get_all_sonarr_episode_files() {
    local url="${SONARR_URL:-http://localhost:8989}"
    local api_key="${SONARR_API_KEY:-}"

    # Get all series first
    local series
    series=$(get_sonarr_series)

    # For each series, get episode files
    echo "$series" | jq -r '.[].id' | while read -r series_id; do
        get_sonarr_episode_files "$series_id"
    done | jq -s 'add // []'
}

# Get history for a specific file (to find original download path)
# Usage: get_radarr_history <movie_id>
get_radarr_history() {
    local movie_id="$1"
    local url="${RADARR_URL:-http://localhost:7878}"
    local api_key="${RADARR_API_KEY:-}"

    api_request "$url" "$api_key" "history/movie?movieId=${movie_id}&eventType=grabbed"
}

# Get history for a specific episode
# Usage: get_sonarr_history <episode_id>
get_sonarr_history() {
    local episode_id="$1"
    local url="${SONARR_URL:-http://localhost:8989}"
    local api_key="${SONARR_API_KEY:-}"

    api_request "$url" "$api_key" "history?episodeId=${episode_id}&eventType=grabbed"
}

# Extract file paths from Radarr movies JSON
# Output: tab-separated: movie_id, title, file_path
parse_radarr_movies() {
    jq -r '.[] | select(.hasFile == true) | [.id, .title, .movieFile.path] | @tsv'
}

# Extract file paths from Sonarr episode files JSON
# Output: tab-separated: series_id, series_title, season, episode, file_path
parse_sonarr_episodes() {
    local series_json="$1"

    # Read episode files from stdin and join with series info
    jq -r --argjson series "$series_json" '
        .[] |
        . as $ep |
        ($series | .[] | select(.id == $ep.seriesId)) as $s |
        [$ep.seriesId, $s.title, $ep.seasonNumber, $ep.episodeNumber // 0, $ep.path] | @tsv
    '
}

# Test API connectivity
# Usage: test_api_connection <service> (radarr|sonarr)
test_api_connection() {
    local service="$1"
    local url api_key

    case "$service" in
        radarr)
            url="${RADARR_URL:-http://localhost:7878}"
            api_key="${RADARR_API_KEY:-}"
            ;;
        sonarr)
            url="${SONARR_URL:-http://localhost:8989}"
            api_key="${SONARR_API_KEY:-}"
            ;;
        *)
            echo "Unknown service: $service" >&2
            return 1
            ;;
    esac

    if [[ -z "$api_key" ]]; then
        echo "ERROR: API key not set for $service" >&2
        return 1
    fi

    if api_request "$url" "$api_key" "system/status" >/dev/null 2>&1; then
        echo "OK: $service is reachable at $url"
        return 0
    else
        echo "ERROR: Cannot connect to $service at $url" >&2
        return 1
    fi
}

# Get root folders from Radarr
get_radarr_root_folders() {
    local url="${RADARR_URL:-http://localhost:7878}"
    local api_key="${RADARR_API_KEY:-}"

    api_request "$url" "$api_key" "rootfolder"
}

# Get root folders from Sonarr
get_sonarr_root_folders() {
    local url="${SONARR_URL:-http://localhost:8989}"
    local api_key="${SONARR_API_KEY:-}"

    api_request "$url" "$api_key" "rootfolder"
}
