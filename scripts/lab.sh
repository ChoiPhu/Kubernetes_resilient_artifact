#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() { log 'Usage: scripts/lab.sh {doctor|up|build|deploy|reset|status|down}'; }
on_error() {
    local code=$?
    trap - ERR
    log "lab.sh ${1:-unknown} failed (exit $code). No automatic reset was performed."
    diagnostics
    exit "$code"
}

doctor() {
    local failed=0 tool clusters contexts server client minor
    log 'Checking WSL host tools (read-only). Expected Go 1.27.0; Kubernetes client minor 1.36.'
    for tool in go kubectl kind docker bash timeout awk sort date mktemp; do
        if command -v "$tool"; then :; else log "Missing prerequisite: $tool"; failed=1; fi
    done
    if command -v go >/dev/null; then
        if GOTOOLCHAIN=local go version; then
            [[ $(GOTOOLCHAIN=local go version) == 'go version go1.27.0 '* ]] || {
                log 'Base Go is not 1.27.0. Run go test ./... to verify automatic selection of the pinned toolchain; its first download needs network access. Doctor does not download it.'
            }
        else failed=1; fi
    fi
    if command -v kubectl >/dev/null; then
        kubectl --context "$CONTEXT" --namespace "$NAMESPACE" version --client || failed=1
        contexts=$(k config get-contexts -o name) || failed=1
        if [[ $'\n'${contexts:-}$'\n' == *$'\n'"$CONTEXT"$'\n'* ]]; then
            log "Context $CONTEXT is configured."
        else log "Context $CONTEXT is absent (normal before up)."; fi
    fi
    if command -v kind >/dev/null; then kind version || failed=1; fi
    if ! command -v docker >/dev/null || ! timeout --foreground 20s docker info; then
        log 'BLOCKER: Docker daemon is unavailable inside WSL. Start Docker Desktop, enable its WSL2 engine and integration for this distribution, and confirm docker version shows Client and Server. Do not install a second daemon as a workaround.'
        return 1
    fi
    if ! command -v kind >/dev/null || ! command -v kubectl >/dev/null; then return 1; fi
    clusters=$(kind get clusters) || return 1
    log "Existing kind clusters: ${clusters:-none}"
    if [[ $'\n'$clusters$'\n' == *$'\n'"$CLUSTER"$'\n'* ]]; then
        require_cluster || failed=1
        k get nodes -o wide || failed=1
        k get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"\tReady="}{.status.conditions[?(@.type=="Ready")].status}{"\tversion="}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' || failed=1
        local ready_nodes
        ready_nodes=$(k get nodes -o 'jsonpath={range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}') || failed=1
        if [[ $ready_nodes != $'True\nTrue\nTrue' ]]; then log 'Expected exactly three Ready nodes.'; failed=1; fi
        server=$(k get --raw /version) || failed=1
        client=$(kubectl --context "$CONTEXT" --namespace "$NAMESPACE" version --client -o json) || failed=1
        # Kubernetes permits kubectl within one minor of the API server (1.36 here).
        minor=$(printf '%s\n' "${client:-}" | sed -n 's/.*"minor": *"\([0-9]*\).*".*/\1/p' | head -1)
        if [[ $minor =~ ^[0-9]+$ ]] && (( minor >= 35 && minor <= 37 )); then
            log "kubectl minor $minor is compatible with server minor 36. Server: ${server//$'\n'/ }"
        else log "kubectl minor ${minor:-unknown} is outside the supported 1.35..1.37 range for server 1.36."; failed=1; fi
    else log "$CLUSTER is absent. Run scripts/lab.sh up after prerequisites pass."; fi
    return "$failed"
}

create_cluster() {
    # kind normally selects its new context. Use a private config and then merge
    # its entries while preserving the user's existing current-context.
    local temp original config_paths target result=0
    temp=$(mktemp -d)
    original=$(k config current-context 2>/dev/null || true)
    config_paths=${KUBECONFIG:-$HOME/.kube/config}
    target=${config_paths%%:*}
    [[ -n $target ]] || { rm -rf -- "$temp"; log 'KUBECONFIG must start with a nonempty writable path.'; return 1; }
    if run timeout --foreground 240s kind create cluster --name "$CLUSTER" --config "$ROOT_DIR/kind/cluster.yaml" --wait 240s --retain --kubeconfig "$temp/kubeconfig"; then :; else result=$?; fi
    if [[ -s $temp/kubeconfig ]]; then
        if ! KUBECONFIG="$temp/kubeconfig:$config_paths" k config view --raw --flatten > "$temp/merged"; then
            rm -rf -- "$temp"; return 1
        fi
        chmod 600 "$temp/merged"
        if [[ -n $original ]]; then
            k --kubeconfig "$temp/merged" config set current-context "$original" >/dev/null || { rm -rf -- "$temp"; return 1; }
        else
            k --kubeconfig "$temp/merged" config unset current-context >/dev/null || { rm -rf -- "$temp"; return 1; }
        fi
        mkdir -p -- "$(dirname -- "$target")" || { rm -rf -- "$temp"; return 1; }
        # Copy under a restrictive umask so credentials are never world-readable.
        (umask 077; cat "$temp/merged" > "$target") || { rm -rf -- "$temp"; return 1; }
        chmod 600 "$target"
        log "Added $CONTEXT to $target; existing current-context preserved."
    fi
    rm -rf -- "$temp"
    return "$result"
}

up() {
    need docker; need kind; need kubectl; need timeout
    timeout --foreground 20s docker info >/dev/null || die 'Docker is unavailable inside WSL. Run scripts/lab.sh doctor.'
    local exists=0
    cluster_exists || exists=$?
    case $exists in
        0) log "Inspecting existing cluster $CLUSTER; no cluster will be deleted." ;;
        1) create_cluster ;;
        *) die 'Could not inspect kind clusters.' ;;
    esac
    require_cluster
    run k wait --for=condition=Ready nodes --all --timeout=120s --request-timeout=125s
    run k label node "$WORKER1" "$WORKER2" lab.example.com/role=worker --overwrite
    # The default control-plane NoSchedule taint must be intact.
    local taints
    taints=$(k get node "$CLUSTER-control-plane" -o 'jsonpath={range .spec.taints[*]}{.key}{":"}{.effect}{"\n"}{end}')
    [[ $'\n'$taints$'\n' == *$'\nnode-role.kubernetes.io/control-plane:NoSchedule\n'* ]] || die 'Expected default control-plane NoSchedule taint; inspect the existing cluster.'
    k get nodes -o wide
}

build() {
    require_cluster
    run docker build -f "$ROOT_DIR/app/Dockerfile" --build-arg VERSION=v1 -t demo-api:v1 "$ROOT_DIR"
    run docker build -f "$ROOT_DIR/app/Dockerfile" --build-arg VERSION=v2 -t demo-api:v2 "$ROOT_DIR"
    run docker pull "$CLIENT_IMAGE"
    run kind load docker-image --name "$CLUSTER" demo-api:v1 demo-api:v2 "$CLIENT_IMAGE"
    log 'Both app versions and the curl image loaded into every node of resilience-lab. If source changed, run reset to recreate app Pods.'
}

deploy() {
    require_cluster
    no_hpa
    apply_baseline
    run k rollout status deployment/demo-api --timeout=120s --request-timeout=125s
    wait_app 3 v1
    wait_until 120 'Ready lab-client on worker 1' client_ready
    workers_schedulable || {
        log 'Baseline check failed: both workers must be Ready, schedulable, and labelled lab.example.com/role=worker.'
        return 1
    }
    both_workers_used || {
        log 'Baseline check failed: at least one active Ready app Pod must be running on each worker.'
        return 1
    }
    log 'PASS: three active Ready v1 Pods across both workers, three matching ready backends, Ready client.'
    show_status
}

reset() {
    require_cluster
    log 'Restoring baseline; no images rebuilt, no namespace deletion, optional storage left in place.'
    run k delete hpa demo-api --ignore-not-found --wait=true --timeout=120s --request-timeout=125s
    run k delete pod lab-load scheduling-demo --ignore-not-found --wait=true --timeout=120s --request-timeout=125s
    run k uncordon "$WORKER2"
    local label
    label=$(k get node "$WORKER1" -o 'jsonpath={.metadata.labels.lab\.example\.com/demo-pool}')
    if [[ -n $label ]]; then run k label node "$WORKER1" lab.example.com/demo-pool-; fi
    apply_baseline
    run k rollout restart deployment/demo-api
    run k rollout status deployment/demo-api --timeout=120s --request-timeout=125s
    wait_app 3 v1
    wait_until 120 'Ready lab-client on worker 1' client_ready
    workers_schedulable || {
        log 'Baseline check failed: both workers must be Ready, schedulable, and labelled lab.example.com/role=worker.'
        return 1
    }
    both_workers_used || {
        log 'Baseline check failed: at least one active Ready app Pod must be running on each worker.'
        return 1
    }
    log 'PASS: reset restored three Ready v1 replicas, three ready backends, both schedulable workers in use, and a Ready client.'
    show_status
}

[[ $# == 1 ]] || { usage; exit 2; }
lab_command=$1
case $1 in
    doctor) doctor ;;
    up|build|deploy|reset)
        trap 'on_error "$lab_command"' ERR
        "$1"
        ;;
    status) need kubectl; show_status ;;
    down)
        need kind
        log 'Deleting only kind cluster resilience-lab. All data inside its node containers will be lost.'
        run kind delete cluster --name "$CLUSTER"
        ;;
    *) usage; exit 2 ;;
esac
