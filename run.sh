#!/usr/bin/env bash
# Uso: ./run.sh setup | bump vN | watch | logs | argo | teardown
set -euo pipefail
NS=hooktest
case "${1:-}" in
  setup)
    kind create cluster --name argo-hook
    kubectl create ns argocd
    kubectl apply -n argocd --server-side --force-conflicts \
      -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
    kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
    kubectl apply -f argocd-application.yaml ;;
  bump)   # da eseguire dentro il clone del repo git
    V=$2
    sed -i.bak -E "s/version: v[0-9]+/version: $V/; s/-text=v[0-9]+/-text=$V/" app/deployment.yaml && rm app/deployment.yaml.bak
    git commit -am "bump $V" && git push
    kubectl -n argocd annotate app hooktest argocd.argoproj.io/refresh=hard --overwrite ;;
  watch)  # in un altro terminale durante il bump
    kubectl -n $NS get pods -w --output-watch-events -L version ;;   # include anche il pod del Job PostSync
  logs)
    echo "attendo che ArgoCD crei il Job PostSync (parte solo a rollout finito)..."
    until [ -n "$(kubectl -n $NS get jobs -l app=postsync-check -o name 2>/dev/null)" ]; do sleep 3; done
    JOB=$(kubectl -n $NS get jobs -l app=postsync-check --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)
    echo "ultimo Job: $JOB - attendo che finisca..."
    until kubectl -n $NS get job $JOB -o jsonpath='{.status.conditions[*].type}' 2>/dev/null | grep -qE 'Complete|Failed'; do sleep 3; done
    kubectl -n $NS logs job/$JOB
    echo "--- stato Job (k8s): $(kubectl -n $NS get job $JOB -o jsonpath='{.status.conditions[-1:].type}')"
    echo "--- hook visto da ArgoCD:"
    kubectl -n argocd get app hooktest -o jsonpath='{range .status.operationState.syncResult.resources[?(@.kind=="Job")]}{.name} {.hookPhase} {.message}{"\n"}{end}'
    echo "--- esito sync ArgoCD:"
    kubectl -n argocd get app hooktest -o jsonpath='{.status.operationState.phase}{" "}{.status.operationState.message}{"\n"}' ;;
  argo)   # cosa ha registrato ArgoCD sull'ultimo sync + storico
    kubectl -n argocd get app hooktest -o jsonpath='{"phase="}{.status.operationState.phase}{"  retryCount="}{.status.operationState.retryCount}{"\nmessage="}{.status.operationState.message}{"\nrevision="}{.status.operationState.syncResult.revision}{"\nsync="}{.status.sync.status}{"  health="}{.status.health.status}{"\n"}'
    echo "--- hook (ArgoCD):"
    kubectl -n argocd get app hooktest -o jsonpath='{range .status.operationState.syncResult.resources[?(@.hookType=="PostSync")]}{.name} {.hookPhase} {.message}{"\n"}{end}'
    echo "--- Job nel cluster:"
    kubectl -n $NS get jobs -l app=postsync-check -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp,STATUS:.status.conditions[-1].type'
    echo "--- storico sync (ultimi 3):"
    kubectl -n argocd get app hooktest -o jsonpath='{range .status.history[-3:]}{.id} {.revision} {.deployedAt}{"\n"}{end}' ;;
  teardown)
    kind delete cluster --name argo-hook ;;
  *) echo "uso: $0 setup|bump vN|watch|logs|argo|teardown"; exit 1 ;;
esac
