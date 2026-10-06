#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() { printf 'Usage: %s traffic [SECONDS: 1..3600, default 600]\n' "$0" >&2; }
if [[ $# -lt 1 || $# -gt 2 || $1 != traffic ]]; then
    usage
    exit 2
fi
duration=${2:-600}
if [[ ! $duration =~ ^[0-9]{1,4}$ ]] || (( 10#$duration < 1 || 10#$duration > 3600 )); then
    usage
    exit 2
fi
duration=$((10#$duration))
command -v timeout >/dev/null || die 'The Ubuntu timeout command is required.'
command -v kubectl >/dev/null || die 'kubectl is required.'

sample_file=$(mktemp)
request_pid=
stop_code=0
successes=0
failures=0
finish() {
    local code=$?
    trap - EXIT INT TERM
    if [[ -n $request_pid ]]; then
        kill -TERM "$request_pid" 2>/dev/null || true
        wait "$request_pid" 2>/dev/null || true
    fi
    rm -f -- "$sample_file"
    log "Traffic finished: $successes successful requests, $failures failed requests."
    exit "$code"
}
interrupt() {
    stop_code=$1
    if [[ -n $request_pid ]]; then
        kill -TERM "$request_pid" 2>/dev/null || true
    fi
}
trap finish EXIT
trap 'interrupt 130' INT
trap 'interrupt 143' TERM

log "Sampling Service traffic for ${duration}s; curl time excludes kubectl exec overhead."
printf 'timestamp_utc,exec_exit,http_code,seconds,pod,node,version\n'
deadline=$((SECONDS + duration))
while (( SECONDS < deadline && stop_code == 0 )); do
    timestamp=$(stamp)
    # One exec and one fresh curl process per attempt. stderr stays visible.
    timeout --kill-after=1s 8s kubectl --context "$CONTEXT" --namespace "$NAMESPACE" \
        --request-timeout=7s exec lab-client -- \
        curl --silent --show-error --http1.1 --header 'Connection: close' \
        --connect-timeout 1 --max-time 2 \
        --write-out '\n__LAB_CURL__%{http_code},%{time_total}\n' \
        'http://demo-api.resilience-lab.svc.cluster.local/' >"$sample_file" &
    request_pid=$!
    if wait "$request_pid"; then
        exec_exit=0
    else
        exec_exit=$?
    fi
    if (( stop_code != 0 )); then
        wait "$request_pid" 2>/dev/null || true
        exec_exit=$stop_code
    fi
    request_pid=

    http_code=000
    seconds=-
    pod=-
    node=-
    version=-
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            pod:\ *) value=${line#pod: }; [[ $value =~ ^[A-Za-z0-9_.-]+$ ]] && pod=$value ;;
            node:\ *) value=${line#node: }; [[ $value =~ ^[A-Za-z0-9_.-]+$ ]] && node=$value ;;
            version:\ *) value=${line#version: }; [[ $value =~ ^[A-Za-z0-9_.-]+$ ]] && version=$value ;;
            __LAB_CURL__*)
                values=${line#__LAB_CURL__}
                status=${values%%,*}
                timing=${values#*,}
                [[ $status =~ ^[0-9]{3}$ ]] && http_code=$status
                [[ $timing =~ ^[0-9]+([.][0-9]+)?$ ]] && seconds=$timing
                ;;
        esac
    done <"$sample_file"
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$timestamp" "$exec_exit" "$http_code" "$seconds" "$pod" "$node" "$version"
    if (( exec_exit == 0 )) && [[ $http_code == 200 ]]; then
        successes=$((successes + 1))
    else
        failures=$((failures + 1))
        log "Request failed at $timestamp: exec_exit=$exec_exit HTTP=$http_code"
    fi
    (( stop_code == 0 )) || break
    sleep 0.2 || true
done
exit "$stop_code"
