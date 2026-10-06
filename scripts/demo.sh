#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() { printf 'Usage: %s {service|scale|self-heal|drain|rollout}\n' "$0" >&2; }
[[ $# == 1 ]] || { usage; exit 2; }
experiment=$1
case $experiment in service|scale|self-heal|drain|rollout) ;; *) usage; exit 2 ;; esac

mutation_pid=
started=$SECONDS
finish() {
    local code=$?
    trap - EXIT INT TERM
    if [[ -n $mutation_pid ]]; then
        kill -TERM "$mutation_pid" 2>/dev/null || true
        wait "$mutation_pid" 2>/dev/null || true
    fi
    if (( code != 0 )); then
        log "Experiment failed (exit $code); preserving cluster state for inspection."
        diagnostics
    fi
    log "$(stamp) END $experiment: exit=$code elapsed=$((SECONDS - started))s"
    exit "$code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
log "$(stamp) BEGIN $experiment"
log 'Collect traffic in a separate terminal. State checks alone do not prove response distribution or continuity.'

snapshot() {
    log "$(stamp) Kubernetes state"
    run k get deployment/demo-api
    run k get replicasets -l app=demo-api -o wide
    run k get pods -l app=demo-api -o wide
    run k get service/demo-api
    run k get pdb/demo-api
    run k get endpointslices -l kubernetes.io/service-name=demo-api \
        -o 'jsonpath={range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[*]}{"\tready="}{.conditions.ready}{"\tterminating="}{.conditions.terminating}{"\n"}{end}'
}

service_identity() { k get service demo-api -o 'jsonpath={.metadata.uid}{"|"}{.spec.clusterIP}'; }
replicaset_identities() {
    k get replicasets -l app=demo-api \
        -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.metadata.uid}{"|"}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}{end}' | sort
}
active_replicaset() {
    local rows name uid node owner image deletion ready owners=
    rows=$(pod_rows) || return
    while IFS='|' read -r name uid node owner image deletion ready; do
        [[ -n $name && -z $deletion && $ready == True ]] || continue
        [[ -n $owner ]] || die "Pod $name has no ReplicaSet owner."
        if [[ -n $owners && $owners != "$owner" ]]; then
            die 'Expected one active application ReplicaSet before the experiment.'
        fi
        owners=$owner
    done <<<"$rows"
    [[ -n $owners ]] || die 'No active application ReplicaSet found.'
    printf '%s\n' "$owners"
}
assert_service_identity() {
    [[ $(service_identity) == "$original_service" ]] || die 'Service UID or ClusterIP changed.'
}
assert_scale_identity() {
    assert_service_identity
    [[ $(replicaset_identities) == "$original_replicasets" ]] || die 'Scaling changed ReplicaSet identity or revision.'
}

# Record the first observation of each replacement separately from readiness.
remember_pods() {
    local rows name uid rest
    rows=$(pod_rows) || return
    seen_uids='|'
    while IFS='|' read -r name uid rest; do
        [[ -n $uid ]] && seen_uids+="$uid|"
    done <<<"$rows"
}
observe_new_pods() {
    local rows name uid node owner image deletion ready
    rows=$(pod_rows) || return
    while IFS='|' read -r name uid node owner image deletion ready; do
        [[ -n $uid ]] || continue
        if [[ $seen_uids != *"|$uid|"* ]]; then
            seen_uids+="$uid|"
            log "$(stamp) New Pod first observed after $((SECONDS - mutation_started))s: $name UID=$uid node=${node:--} owner=$owner Ready=${ready:--}"
        fi
    done <<<"$rows"
}
observe_mutation() {
    while kill -0 "$mutation_pid" 2>/dev/null; do
        observe_new_pods
        snapshot
        sleep 2
    done
    local code=0
    wait "$mutation_pid" || code=$?
    mutation_pid=
    (( code == 0 )) || return "$code"
}

service() {
    require_baseline
    snapshot
    run k get replicasets -l app=demo-api \
        -o 'jsonpath={range .items[*]}{.metadata.name}{" owns Pods; owner="}{range .metadata.ownerReferences[*]}{.kind}{"/"}{.name}{" "}{end}{"\n"}{end}'
    run k get pods -l app=demo-api \
        -o 'jsonpath={range .items[*]}{.metadata.name}{"\tIP="}{.status.podIP}{"\towner="}{range .metadata.ownerReferences[*]}{.kind}{"/"}{.name}{" "}{end}{"\n"}{end}'
    log 'PASS state checks: three Ready v1 Pods across both workers and three ready Service backends; client Ready; no HPA.'
    log 'Traffic acceptance: collect at least 100 attempts; require all three Pod names, v1 responses, and zero baseline failures. Extend one sample if a Pod is missing.'
}

scale() {
    require_baseline
    log 'Precondition for the presenter: service experiment traffic acceptance has passed.'
    original_service=$(service_identity)
    original_replicasets=$(replicaset_identities)
    snapshot
    log "$(stamp) Scaling to six"
    run k scale deployment demo-api --replicas=6
    wait_app 6 v1
    assert_scale_identity
    snapshot
    log "$(stamp) PASS six desired/updated/ready/available replicas and six ready backends. Holding for 20s."
    sleep 20
    log "$(stamp) Scaling to three"
    run k scale deployment demo-api --replicas=3
    wait_app 3 v1
    assert_scale_identity
    snapshot
    log 'PASS state checks: six replicas/backends returned to three; Service UID/ClusterIP and ReplicaSet identities/revisions unchanged.'
    log 'Traffic acceptance: identify at least one new responding Pod during the six-replica interval, and record every request failure.'
}

self_heal_complete() {
    local rows name uid node owner image deletion ready old_present=false
    rows=$(pod_rows) || return
    while IFS='|' read -r name uid node owner image deletion ready; do
        [[ -n $uid ]] || continue
        [[ $uid != "$deleted_uid" ]] || old_present=true
        if [[ $before_uids != *"|$uid|"* && -z $deletion && $owner == "$original_rs" ]]; then
            if [[ -z $replacement_uid ]]; then
                replacement_uid=$uid
                replacement_name=$name
                log "$(stamp) Replacement first observed after $((SECONDS - mutation_started))s: $name UID=$uid node=${node:--} owner=$owner Ready=${ready:--}"
            fi
        fi
    done <<<"$rows"
    [[ -n $replacement_uid && $old_present == false ]] || return 1
    app_ready 3 v1 || return
    # Verify the recorded new identity is itself Ready, not another replacement.
    while IFS='|' read -r name uid node owner image deletion ready; do
        [[ $uid == "$replacement_uid" && -z $deletion && $ready == True && $owner == "$original_rs" ]] && return 0
    done <<<"$rows"
    return 1
}
self_heal() {
    require_cluster
    app_ready 3 v1 || die 'Expected three Ready v1 replicas and backends; run lab.sh reset.'
    no_hpa || die 'Remove the HPA before manual experiments.'
    client_ready || die 'The traffic client must be Ready on worker 1.'
    original_rs=$(active_replicaset)
    snapshot
    local rows name uid node owner image deletion ready
    rows=$(pod_rows)
    deleted_name= deleted_uid= deleted_node=
    before_uids='|'
    while IFS='|' read -r name uid node owner image deletion ready; do
        [[ -n $uid ]] && before_uids+="$uid|"
        if [[ -z $deleted_uid && -n $uid && -z $deletion && $ready == True ]]; then
            deleted_name=$name deleted_uid=$uid deleted_node=$node
        fi
    done <<<"$rows"
    [[ -n $deleted_uid ]] || die 'No non-terminating Ready Pod can be selected.'
    log "Selected Pod: $deleted_name UID=$deleted_uid node=$deleted_node owner=ReplicaSet/$original_rs"
    replacement_uid= replacement_name=
    mutation_started=$SECONDS
    log "$(stamp) Deleting selected Pod"
    run k delete pod "$deleted_name" --wait=false
    local remaining=$((120 - (SECONDS - mutation_started)))
    (( remaining > 0 )) || die 'The 120s replacement deadline expired during deletion.'
    wait_until "$remaining" 'a replacement in the same ReplicaSet and three ready backends' self_heal_complete
    snapshot
    log "PASS state checks: $replacement_name UID=$replacement_uid belongs to $original_rs; deleted UID is absent; three replicas/backends restored after $((SECONDS - mutation_started))s."
    log 'Traffic acceptance: record successful and failed requests over the replacement interval. Direct Pod deletion bypasses PDB eviction protection.'
}

check_worker_capacity() {
    local description allocated capacity rows name uid node owner image deletion ready extra=0
    description=$(run k describe node "$WORKER1")
    printf '%s\n' "$description"
    allocated=$(awk '/^Allocated resources:/ {section=1} section && $1 == "cpu" {cpu=$2} section && $1 == "memory" {print cpu "|" $2; exit}' <<<"$description")
    capacity=$(k get node "$WORKER1" -o 'jsonpath={.status.allocatable.cpu}{"|"}{.status.allocatable.memory}')
    rows=$(pod_rows)
    while IFS='|' read -r name uid node owner image deletion ready; do
        [[ -z $deletion && $node == "$WORKER2" ]] && extra=$((extra + 1))
    done <<<"$rows"
    # kubectl describe already accounts for Pod/init-container request rules.
    awk -v alloc="$allocated" -v capacity="$capacity" -v extra="$extra" '
        function cpu(s) { if (s ~ /^[0-9]+m$/) return substr(s,1,length(s)-1); if (s ~ /^[0-9]+([.][0-9]+)?$/) return s*1000; return -1 }
        function mem(s, n,u) {
            n=s; sub(/[a-zA-Z]+$/, "", n); u=substr(s,length(n)+1)
            if (n !~ /^[0-9]+([.][0-9]+)?$/) return -1
            if (u=="") return n; if(u=="Ki") return n*1024; if(u=="Mi") return n*1024^2; if(u=="Gi") return n*1024^3; if(u=="Ti") return n*1024^4
            if(u=="k" || u=="K") return n*1000; if(u=="M") return n*1000^2; if(u=="G") return n*1000^3; return -1
        }
        BEGIN { split(alloc,a,"|"); split(capacity,c,"|"); ac=cpu(a[1]); am=mem(a[2]); cc=cpu(c[1]); cm=mem(c[2]); if(ac<0 || am<0 || cc<0 || cm<0) exit 2; if(cc-ac < extra*100 || cm-am < extra*32*1024^2) exit 1 }
    ' || die 'Cannot confirm worker 1 has enough unallocated CPU/memory requests for replacement Pods; inspect its allocated resources above.'
}
drained_state() {
    app_ready 3 v1 || return
    [[ $(k get node "$WORKER2" -o 'jsonpath={.spec.unschedulable}') == true ]] || return 1
    local rows name uid node owner image deletion ready
    rows=$(pod_rows) || return
    while IFS='|' read -r name uid node owner image deletion ready; do
        [[ -n $name && -z $deletion ]] || continue
        [[ $node == "$WORKER1" ]] || return 1
    done <<<"$rows"
}
drain() {
    require_baseline
    local pdb uid min desired allowed
    pdb=$(k get pdb demo-api -o 'jsonpath={.metadata.uid}{"|"}{.spec.minAvailable}{"|"}{.status.desiredHealthy}{"|"}{.status.disruptionsAllowed}')
    IFS='|' read -r uid min desired allowed <<<"$pdb"
    [[ -n $uid && $min == 2 && $desired == 2 && $allowed =~ ^[1-9][0-9]*$ ]] || die 'PDB must require two healthy replicas and currently allow a disruption.'
    original_pdb="$uid|$min"
    check_worker_capacity
    snapshot
    remember_pods
    mutation_started=$SECONDS
    log "$(stamp) Draining worker 2"
    log "+ kubectl --context $CONTEXT drain $WORKER2 --ignore-daemonsets --delete-emptydir-data --timeout=180s"
    timeout --kill-after=2s 180s kubectl --context "$CONTEXT" --request-timeout=10s drain "$WORKER2" \
        --ignore-daemonsets --delete-emptydir-data --timeout=180s &
    mutation_pid=$!
    observe_mutation
    wait_until 120 'three Ready Pods on worker 1 and worker 2 SchedulingDisabled' drained_state
    [[ $(k get pdb demo-api -o 'jsonpath={.metadata.uid}{"|"}{.spec.minAvailable}') == "$original_pdb" ]] || die 'PDB identity or availability floor changed during drain.'
    snapshot
    run k get nodes -o wide
    log "$(stamp) PASS drained state: worker 2 unschedulable, three Ready v1 Pods on worker 1, three ready backends, original PDB intact; elapsed=$((SECONDS - mutation_started))s."
    run kubectl --context "$CONTEXT" --request-timeout=10s uncordon "$WORKER2"
    wait_until 120 'both workers Ready and schedulable' workers_schedulable
    log 'PASS restoration: worker 2 is Ready and schedulable. Existing Pods stay on worker 1; run lab.sh reset explicitly to restore placement.'
    log 'Traffic acceptance: review the whole drain interval and record HTTP/exec errors.'
}

rollout() {
    require_baseline
    command -v docker >/dev/null || die 'docker is required to verify v2 is loaded on every node.'
    command -v timeout >/dev/null || die 'timeout is required to bound image checks.'
    local node
    for node in "${CLUSTER}-control-plane" "$WORKER1" "$WORKER2"; do
        run timeout 10s docker exec "$node" crictl inspecti docker.io/library/demo-api:v2 >/dev/null \
            || die "demo-api:v2 could not be verified in $node; run lab.sh build."
    done
    original_service=$(service_identity)
    original_rs=$(active_replicaset)
    snapshot
    remember_pods
    mutation_started=$SECONDS
    log "$(stamp) Updating Pod template to v2"
    run k set image deployment/demo-api demo-api=demo-api:v2
    # Override the ordinary API timeout for kubectl's explicitly bounded watch.
    log "+ kubectl --context $CONTEXT --namespace $NAMESPACE rollout status deployment/demo-api --timeout=120s"
    timeout --kill-after=2s 120s kubectl --context "$CONTEXT" --namespace "$NAMESPACE" \
        --request-timeout=125s rollout status deployment/demo-api --timeout=120s &
    mutation_pid=$!
    observe_mutation
    wait_app 3 v2
    local new_rs old_count
    new_rs=$(active_replicaset)
    [[ $new_rs != "$original_rs" ]] || die 'Rollout did not produce a new active ReplicaSet.'
    old_count=$(k get replicaset "$original_rs" -o 'jsonpath={.spec.replicas}{"|"}{.status.replicas}')
    [[ $old_count == '0|0' ]] || die "Old ReplicaSet $original_rs has not scaled to zero: $old_count"
    assert_service_identity
    snapshot
    log "PASS state checks: new ReplicaSet $new_rs, old ReplicaSet $original_rs scaled to zero, three desired/updated/ready/available v2 replicas and ready backends, unchanged Service; elapsed=$((SECONDS - mutation_started))s."
    log 'Traffic acceptance: match v1-to-v2 responses and request failures to this interval. The experiment ends at v2; reset explicitly when needed.'
}

case $experiment in
    service) service ;;
    scale) scale ;;
    self-heal) self_heal ;;
    drain) drain ;;
    rollout) rollout ;;
esac
