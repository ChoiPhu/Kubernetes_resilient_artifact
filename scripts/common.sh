#!/usr/bin/env bash
# Shared, read-only checks and bounded waits. Sourced by the three entry points.
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR CLUSTER=resilience-lab CONTEXT=kind-resilience-lab NAMESPACE=resilience-lab
readonly WORKER1=resilience-lab-worker WORKER2=resilience-lab-worker2
readonly NODE_IMAGE='kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed'
readonly CLIENT_IMAGE=curlimages/curl:8.18.0

log() { printf '%s\n' "$*" >&2; }
stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
die() { log "ERROR: $*"; exit 1; }
run() { printf '+ ' >&2; printf '%q ' "$@" >&2; printf '\n' >&2; "$@"; }
need() { command -v "$1" >/dev/null || die "Required command missing: $1"; }

k() {
    # A condition can make several API calls; none can outlive its enclosing wait.
    if [[ -n ${LAB_DEADLINE:-} ]]; then
        local remaining=$((LAB_DEADLINE - SECONDS))
        (( remaining > 0 )) || return 124
        timeout --foreground "${remaining}s" kubectl --context "$CONTEXT" --namespace "$NAMESPACE" --request-timeout=10s "$@"
    else
        kubectl --context "$CONTEXT" --namespace "$NAMESPACE" --request-timeout=10s "$@"
    fi
}

wait_until() {
    local limit=$1 description=$2
    shift 2
    local LAB_DEADLINE=$((SECONDS + limit)) remaining
    log "Waiting up to ${limit}s: $description"
    while (( SECONDS < LAB_DEADLINE )); do
        if "$@"; then return 0; fi
        remaining=$((LAB_DEADLINE - SECONDS))
        (( remaining > 0 )) || break
        if (( remaining < 2 )); then sleep "$remaining"; else sleep 2; fi
    done
    log "Timed out after ${limit}s: $description"
    return 1
}

diagnostics() {
    log "Diagnostic snapshot at $(stamp); state is preserved for inspection."
    k get nodes -o wide || true
    k get deployment,replicaset,pdb,service -o wide || true
    k get pods -o wide || true
    k get endpointslices -l kubernetes.io/service-name=demo-api -o yaml || true
    k get events --sort-by=.lastTimestamp || true
    k describe deployment demo-api || true
    k describe pods -l app=demo-api || true
}

cluster_exists() {
    local clusters
    clusters=$(kind get clusters) || return 2
    [[ $'\n'$clusters$'\n' == *$'\n'"$CLUSTER"$'\n'* ]]
}

require_cluster() {
    need kind; need kubectl; need docker; need timeout
    cluster_exists || { log "Named cluster $CLUSTER unavailable. Run scripts/lab.sh doctor and up."; return 1; }
    local nodes expected node image control_planes versions
    nodes=$(kind get nodes --name "$CLUSTER" | sort) || return 1
    expected=$(printf '%s\n' "$CLUSTER-control-plane" "$WORKER1" "$WORKER2" | sort)
    [[ $nodes == "$expected" ]] || { log "Existing cluster has incompatible nodes: $nodes. It has not been deleted."; return 1; }
    for node in "$CLUSTER-control-plane" "$WORKER1" "$WORKER2"; do
        image=$(docker inspect --format '{{.Config.Image}}' "$node") || return 1
        [[ $image == "$NODE_IMAGE" ]] || { log "$node uses $image; required $NODE_IMAGE. Existing cluster preserved."; return 1; }
    done
    nodes=$(k get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' | sort) || return 1
    [[ $nodes == "$expected" ]] || { log "Context $CONTEXT does not expose exactly the expected three nodes."; return 1; }
    control_planes=$(k get nodes -l node-role.kubernetes.io/control-plane -o name) || return 1
    [[ $control_planes == "node/$CLUSTER-control-plane" ]] || { log "Expected exactly one control-plane node."; return 1; }
    versions=$(k get nodes -o 'jsonpath={range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u) || return 1
    [[ $versions == v1.36.4 ]] || { log "Incompatible kubelet version(s): $versions; expected v1.36.4."; return 1; }
}

pod_rows() {
    k get pods -l app=demo-api -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.metadata.uid}{"|"}{.spec.nodeName}{"|"}{.metadata.ownerReferences[?(@.controller==true)].name}{"|"}{.spec.containers[?(@.name=="demo-api")].image}{"|"}{.metadata.deletionTimestamp}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
}

ready_backend_names() {
    local rows
    rows=$(k get endpointslices -l kubernetes.io/service-name=demo-api -o 'jsonpath={range .items[*].endpoints[*]}{.targetRef.name}{"|"}{.conditions.ready}{"|"}{.conditions.terminating}{"\n"}{end}') || return 1
    printf '%s\n' "$rows" | awk -F '|' '$1 != "" && $2 == "true" && $3 != "true" {print $1}' | sort -u
}

app_ready() {
    local count=$1 version=${2:-} rows deployment names backends
    deployment=$(k get deployment demo-api -o 'jsonpath={.spec.replicas}|{.status.replicas}|{.status.updatedReplicas}|{.status.readyReplicas}|{.status.availableReplicas}|{.metadata.generation}|{.status.observedGeneration}|{.spec.template.spec.containers[?(@.name=="demo-api")].image}') || return 1
    local desired actual updated ready available generation observed image
    IFS='|' read -r desired actual updated ready available generation observed image <<< "$deployment"
    [[ $desired == "$count" && $actual == "$count" && $updated == "$count" && $ready == "$count" && $available == "$count" && $generation == "$observed" ]] || return 1
    [[ -z $version || $image == "demo-api:$version" ]] || return 1
    rows=$(pod_rows) || return 1
    # Every active Pod must be Ready; terminating objects do not count.
    printf '%s\n' "$rows" | awk -F '|' -v count="$count" -v version="$version" '
        $1 != "" && $6 == "" {n++; if ($7 != "True" || (version != "" && $5 != "demo-api:" version)) bad=1}
        END {exit !(n == count && !bad)}' || return 1
    names=$(printf '%s\n' "$rows" | awk -F '|' '$1 != "" && $6 == "" && $7 == "True" {print $1}' | sort)
    backends=$(ready_backend_names) || return 1
    [[ $names == "$backends" ]]
}

wait_app() { wait_until 120 "$1 active Ready app Pods, available replicas, and matching ready Service backends (${2:-any version})" app_ready "$@"; }

client_ready() {
    local state
    state=$(k get pod lab-client -o 'jsonpath={.spec.nodeName}|{.metadata.deletionTimestamp}|{.status.conditions[?(@.type=="Ready")].status}') || return 1
    [[ $state == "$WORKER1||True" ]]
}

workers_schedulable() {
    local rows
    rows=$(k get nodes "$WORKER1" "$WORKER2" -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.spec.unschedulable}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.metadata.labels.lab\.example\.com/role}{"\n"}{end}') || return 1
    printf '%s\n' "$rows" | awk -F '|' '$2 == "true" || $3 != "True" || $4 != "worker" {bad=1} END {exit !(NR == 2 && !bad)}'
}

both_workers_used() {
    local rows nodes expected
    rows=$(pod_rows) || return 1
    nodes=$(printf '%s\n' "$rows" | awk -F '|' '$6 == "" && $7 == "True" {print $3}' | sort -u)
    expected=$(printf '%s\n' "$WORKER1" "$WORKER2" | sort)
    [[ $nodes == "$expected" ]]
}

no_hpa() {
    local names
    names=$(k get hpa -o name) || return 1
    [[ -z $names ]] || { log "Precondition failed: remove the lab HPA before manual experiments ($names)."; return 1; }
}

require_baseline() {
    require_cluster || return 1
    no_hpa && app_ready 3 v1 && client_ready && workers_schedulable && both_workers_used || {
        log "Need three available v1 Pods across both schedulable workers, three matching ready backends, and a Ready client on worker 1. Inspect status; run lab.sh reset to restore the baseline."
        return 1
    }
}

apply_baseline() {
    run k apply -f "$ROOT_DIR/k8s/namespace.yaml" || return 1
    local files=(-f "$ROOT_DIR/k8s/deployment.yaml" -f "$ROOT_DIR/k8s/service.yaml" -f "$ROOT_DIR/k8s/pdb.yaml" -f "$ROOT_DIR/k8s/client.yaml")
    run k apply --dry-run=server "${files[@]}" || return 1
    run k apply "${files[@]}"
}

show_status() {
    k get nodes -o wide || return 1
    k get deployment,replicaset -o wide || return 1
    k get pods -o wide || return 1
    k get service,pdb -o wide || return 1
    k get endpointslices -l kubernetes.io/service-name=demo-api -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{range .endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\tready="}{.conditions.ready}{"\tterminating="}{.conditions.terminating}{"\n"}{end}{end}'
}
