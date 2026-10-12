# ArgoCD PostSync hook: timing and failure handling

A small local experiment that answers two questions about ArgoCD `PostSync` hooks on a plain Kubernetes `Deployment`:

1. Does the hook start only **after** all pods of the new version are rolled out?
2. If the hook **fails**, how does ArgoCD report it?

The motivation is a hook that runs a schema publish after a deploy, for example a GraphQL Federation subgraph `publish`. That publish must not happen while the old version is still serving traffic, and a failed publish must be noticed.

Argo Rollouts and canary deployments are out of scope; this test covers only the simplest case.

## Environment

- kind cluster with node image `kindest/node:v1.37.0`.
- ArgoCD `v3.5.4`, installed from the stable manifests with default config.
- An ArgoCD Application with auto-sync (`automated.prune: true`), pointing at the `app/` folder of this repo. The Application has **no** `retry` block.

## What's in the repo

| File | Purpose |
|---|---|
| `app/deployment.yaml` | `http-echo` with 5 replicas. Each pod answers with its version (`v1`, `v2`, …). Rollout uses `maxSurge: 1` and `maxUnavailable: 0`. A 10s readiness delay and a 30s `preStop` keep the rollout slow and keep old pods `Terminating` for a while. |
| `app/service.yaml` | ClusterIP Service in front of the pods. |
| `app/rbac.yaml` | Read-only RBAC for the hook (pods, deployments, replicasets, endpointslices). |
| `app/postsync-job.yaml` | The PostSync hook (see below). |
| `argocd-application.yaml` | The ArgoCD Application. |
| `run.sh` | Helper commands: `setup`, `bump vN`, `watch`, `logs`, `argo`, `teardown`. |

At start, the hook records the following:

- the Deployment status (`generation`, `observedGeneration`, `updated`, `available`) and the ReplicaSets;
- every pod, with its version and `deletionTimestamp`;
- the response from every **ready** endpoint;
- 50 requests through the Service.

It exits non-zero if any response is not the expected new version. Setting `FORCE_FAIL=1` makes it always exit 1.

## How to run

```bash
./run.sh setup        # create kind cluster, install ArgoCD, create the Application
./run.sh watch        # (second terminal) live view of pods
./run.sh bump v2      # change version, commit, push, hard refresh
./run.sh logs         # wait for the latest hook Job and print its report + ArgoCD view
./run.sh argo         # sync operation phase, retries, hook status, history
./run.sh teardown     # delete the cluster
```

## Runs

| Run | Hook | Outcome |
|---|---|---|
| v1 | normal | Initial sync. Hook passed. |
| v2 | normal | Hook started after the rollout completed, but **13/50** requests through the Service still hit `v1`. The Job failed in Kubernetes, yet ArgoCD reported the sync as **Succeeded** (see finding 4). |
| v3 | normal, `generateName` | First hook attempt failed (old pods still serving traffic). ArgoCD retried about 15s later, and that attempt saw **50/50 `v3`** and passed. |
| v4 | `FORCE_FAIL=1` | ArgoCD marked the hook `Failed` and retried 5 times. The operation ended `Failed` after about 4 minutes. App stayed `Synced` / `Healthy` throughout. |

### Evidence: run v2, hook report

```
=== PostSync start 09:31:59 expected=v2
gen=2 observed=2 replicas=5 updated=5 available=5
NAME              DESIRED   CURRENT   READY
echo-7df5cc8c5d   0         0         0        # old ReplicaSet
echo-848dffd4c4   5         5         5        # new ReplicaSet
NAME                    VER   READY   DELETING
echo-7df5cc8c5d-57ts6   v1    true    2026-10-12T09:32:21Z
echo-7df5cc8c5d-mflmn   v1    true    2026-10-12T09:32:43Z
echo-7df5cc8c5d-t6dxt   v1    true    2026-10-12T09:32:32Z
echo-848dffd4c4-...     v2    true    <none>   (x5)
--- ready endpoints
10.244.0.18..22 -> v2                          # all 5 ready endpoints are v2
--- 50 req via Service
     13 v1
     37 v2
=== FAIL: versione vecchia ancora servita
```

The last `v1` pod started terminating at 09:31:58 (its `DELETING` time minus the 45s grace period). The hook started 1s later.

### Evidence: run v4, forced failure

```
# during retries
phase=Running  retryCount=4
message=one or more synchronization tasks completed unsuccessfully. Retrying attempt #4 at 10:03AM.
sync=Synced  health=Healthy

# final
phase=Failed  retryCount=5
message=one or more synchronization tasks completed unsuccessfully (retried 5 times).
sync=Synced  health=Healthy
hook: postsync-check-...  Failed  Job has reached the specified backoff limit
```

## Findings

1. **The hook starts only after the rollout is complete.** On every run, at hook start, all of the following held:
   - `updatedReplicas == availableReplicas == spec.replicas`;
   - the old ReplicaSet was at 0;
   - only new-version pods were in the ready endpoints.

   This matches the gitops-engine Deployment health check ([`getAppsv1DeploymentHealth`](https://github.com/argoproj/gitops-engine/blob/master/pkg/health/health_deployment.go)), which gates PostSync.

2. **"Healthy" does not mean "the old version gets no more traffic".** Old pods that are still `Terminating` are removed from the ready endpoints immediately. kube-proxy, however, keeps routing some traffic to them for a few seconds. Locally the window was about 1–15s. A publish step that runs immediately could therefore be seen by clients while old pods still answer.

3. **A failed hook fails the sync, but late and quietly.** Even without an explicit `retry` block, ArgoCD v3.5.4 retried the sync 5 times with increasing backoff, re-creating the hook Job on each attempt. The operation became `Failed` only after the retries were exhausted, about 4 minutes later. During and after that time:
   - app `sync=Synced` and `health=Healthy`;
   - the failure is visible only in `status.operationState`;
   - failed syncs do not appear in `status.history`.

4. **Use `generateName` rather than a fixed Job name with `hook-delete-policy: BeforeHookCreation`.** In run v2, with a fixed name and that delete policy, the Job failed in Kubernetes (`BackoffLimitExceeded`). ArgoCD nevertheless recorded the hook as `Succeeded` ("Reached expected number of succeeded pods") and the sync as `Succeeded`. The likely cause, not fully confirmed, is that ArgoCD read the status of the previous, successful Job with the same name. After switching to `generateName`, failures were tracked correctly.

## Implications for a "publish after deploy" hook

- **Wait or retry before publishing.** The hook should not publish the moment it starts. It should first confirm that the old version no longer serves traffic, for example by polling the Service or the router until every response comes from the new version, with a timeout.
- **Make the publish idempotent.** ArgoCD re-runs the hook on sync retries.
- **Base alerting on the sync operation phase, not on app health.** For example, use ArgoCD Notifications `on-sync-failed`. Expect the alert only after the retries, which means a delay of minutes.
- **Use `generateName`** for the hook Job (see finding 4).

## Not covered here (to check on a real cluster)

1. **The real Application config:**
   - `spec.syncPolicy.retry` (limit and backoff);
   - the deployed ArgoCD version;
   - custom health checks in `argocd-cm`;
   - sync waves and other resources in the same Application.
2. **The traffic window behind a real load balancer.** With an AWS ALB, for instance, the target deregistration delay plus `preStop` and grace periods can make the window where old pods still serve traffic much longer than with kube-proxy alone.
3. **Notifications.** Whether `on-sync-failed` actually fires when a PostSync hook fails, and how long after.
4. **Argo Rollouts / canary.**
