#!/usr/bin/env bash
# Turn a street address into the `coordinates` string a restaurant note needs,
# and optionally the neighbourhood and city OSM has on file for it.
#
#   geocode.sh "2101 Sutter St, San Francisco, CA"
#   37.7858, -122.435
#
#   geocode.sh --details "2101 Sutter St, San Francisco, CA"
#   coordinates: 37.7858, -122.435
#   neighbourhood: Japantown
#   city: San Francisco
#
# Prints nothing and exits 1 when the address cannot be resolved. Callers must
# treat that as "flag the note", never as "invent a coordinate".
#
# This exists instead of a WebFetch because:
#   - Nominatim returns JSON. WebFetch renders a page and runs a small model
#     over it, which is a lossy way to read a few fields.
#   - Nominatim's usage policy requires a real User-Agent and at most one
#     request per second. Both are enforced here.
set -uo pipefail

DETAILS=0
if [ "${1:-}" = "--details" ]; then
    DETAILS=1
    shift
fi

ADDRESS="${1:-}"
[ -z "${ADDRESS}" ] && { echo "usage: geocode.sh [--details] <address>" >&2; exit 2; }

CACHE="${GEOCODE_CACHE:-/data/geocode-cache.json}"
STAMP="${GEOCODE_STAMP:-/data/.geocode-last}"
UA="obsidian-claude-assistant/0.1 (Home Assistant add-on; +https://github.com/cmerrill/obsidian-claude-assistant)"

[ -f "${CACHE}" ] || echo '{}' > "${CACHE}" 2>/dev/null || CACHE=""

# Emit a cached or freshly-fetched record in whichever form was asked for.
emit() {
    local record="$1"
    if [ "${DETAILS}" -eq 0 ]; then
        jq -r '.coordinates' <<<"${record}"
        return
    fi
    jq -r '
        "coordinates: \(.coordinates)",
        (if .neighbourhood != null and .neighbourhood != "" then "neighbourhood: \(.neighbourhood)" else empty end),
        (if .city != null and .city != "" then "city: \(.city)" else empty end)
    ' <<<"${record}"
}

# Same address twice costs one request, not two — in either output mode.
if [ -n "${CACHE}" ]; then
    hit="$(jq -c --arg a "${ADDRESS}" '.[$a] // empty' "${CACHE}" 2>/dev/null)"
    if [ -n "${hit}" ]; then
        emit "${hit}"
        exit 0
    fi
fi

# Nominatim allows one request per second. Wait out the remainder if the last
# call was recent.
if [ -f "${STAMP}" ]; then
    last="$(cat "${STAMP}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ $(( now - last )) -lt 2 ]; then
        sleep 2
    fi
fi
date +%s > "${STAMP}" 2>/dev/null || true

response="$(curl -sS --get --max-time 20 \
    --user-agent "${UA}" \
    --data-urlencode "q=${ADDRESS}" \
    --data-urlencode "format=json" \
    --data-urlencode "addressdetails=1" \
    --data-urlencode "limit=1" \
    "https://nominatim.openstreetmap.org/search" 2>/dev/null)" || {
        echo "geocode: request failed" >&2
        exit 1
    }

# OSM files the same idea under several keys depending on the area, so take the
# first that is populated rather than assuming one.
record="$(jq -c '
    if type == "array" and length > 0 then
        .[0] as $r
        | ($r.lat | tonumber | .*10000 | round / 10000) as $lat
        | ($r.lon | tonumber | .*10000 | round / 10000) as $lon
        | {
            coordinates: "\($lat), \($lon)",
            neighbourhood: ($r.address.neighbourhood // $r.address.suburb
                            // $r.address.quarter // $r.address.city_district // ""),
            city: ($r.address.city // $r.address.town // $r.address.village
                   // $r.address.municipality // ""),
            display_name: ($r.display_name // "")
          }
    else empty end
' <<<"${response}" 2>/dev/null)"

if [ -z "${record}" ]; then
    echo "geocode: no match for ${ADDRESS}" >&2
    exit 1
fi

if [ -n "${CACHE}" ]; then
    tmp="$(mktemp)"
    jq --arg a "${ADDRESS}" --argjson r "${record}" '.[$a] = $r' "${CACHE}" > "${tmp}" \
        && mv "${tmp}" "${CACHE}"
fi

emit "${record}"
