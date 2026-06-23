# DEPLOY — install Talos + bring up the gt-core platform

Master end-to-end runbook for **hq-talos-migration.8**: provision a Talos
Kubernetes cluster from bare metal, deploy the gt-core platform onto it, migrate
(or seed) state, verify, cut traffic over from the old docker-compose stack, and
roll back if needed.

This document is the **spine** that ties together the three migration pieces
authored in this repo — read each for the detail behind its step:

| Piece | What it is | Detail doc |
| --- | --- | --- |
| **Helm chart** | the whole platform as k8s objects (StatefulSets / Deployments / Ingress / Secret / seed-Job; non-root + fsGroup) | [`chart/gt/README.md`](chart/gt/README.md) |
| **GitOps** | Argo CD Application (primary) / Flux (alt) that reconciles the cluster to the chart and **retires watchtower** | [`gitops/README.md`](gitops/README.md) |
| **Data migration** | one-shot operator scripts moving prod docker volumes → cluster PVCs | [`migrate/README.md`](migrate/README.md) |

> **Honest status.** This runbook is a *true* status of the migration, not
> aspirational fiction. Steps that depend on beads not yet implemented are marked
> **[PENDING]** / **[BLOCKED]** with the bead that unblocks them. **As of
> hq-greenfield-seeds (SHIPPED), a greenfield bring-up comes up FUNCTIONAL** —
> the knowledge/role-skills catalog, IdP/OAuth providers and rig catalog are
> replayed as idempotent **boot seeds** at API boot (see
> [Step 6](#step-6--seeds)). A migration from prod (Step 5) carries the live
> state across instead and the boot seeds skip (empty-table gated).

> **Authoring guardrail.** Nothing in this repo runs `talosctl` / `kubectl` /
> the `migrate/` scripts as part of CI or by merging a branch. Every command
> below is run **by an operator**, against a real cluster, during a planned
> window.

---

## Status at a glance

| Step | What | Status | Blocking bead |
| --- | --- | --- | --- |
| 1 | Provision Talos cluster | authored; **not validated on real hardware** | hq-talos-migration.1 [PENDING] |
| 2 | Install Argo CD + apply Application (or `helm install`) | ready | — |
| 3 | Secrets → k8s Secret | ready | — |
| 4 | Stateful services (StatefulSets) + verify PVCs | ready | — |
| 5 | Data migration (prod → cluster) | ready (operator-run) | — |
| 6 | **Live seeds** (knowledge / IdP / rigs at API boot; quota = operator) | **SHIPPED** (hq-greenfield-seeds) | — |
| 7 | Smoke verify | ready | — |
| 8 | Cutover (DNS + retire watchtower) | ready | — |
| 9 | Rollback | ready | — |
| — | Immutable per-sha image tags (GitOps target) | moving tags only | hq-talos-migration.9 [PENDING] |

---

## Prerequisites (workstation)

You drive Talos and the cluster entirely from your workstation — Talos is an
immutable, API-driven OS with **no shell / no SSH**.

- `talosctl` (matching the Talos version you boot)
- `kubectl`
- `helm` (>= 3.x)
- `git` + access to this repo (`gt-core-labs/gt-app-proxy`)
- For Step 5 only: `docker` CLI with access to the running prod compose stack

Dev does **not** happen on the node: workstation → immutable image tag → deploy
to cluster → `kubectl logs/exec/port-forward` at the pod. Use kind / a local
Talos cluster (`talosctl cluster create`) to iterate before touching real nodes.

---

## Step 1 — Provision the Talos cluster

> **Bare metal:** the hardware-specific walkthrough (image selection, install
> disk, network patches, storage provisioner, day-2 upgrades, pitfalls) lives in
> [`docs/INSTALL-metal-amd64.md`](docs/INSTALL-metal-amd64.md). The flow below
> is the condensed generic form.
>
> **Status (hq-talos-migration.1, closed):** chart + boot seeds + probes were
> validated end-to-end on a local Talos cluster (smoke §6 7/7). The **real
> hardware** pass (installer, disks, CSI, network) remains pending — treat the
> disk device, network, and CSI choices below as placeholders to confirm
> against the actual nodes before a production run.

Talos boots from its ISO/PXE image into maintenance mode; you then push a
machine config to it over its API. There is no OS to log into.

```sh
# 0. Boot each node off the Talos image (ISO / PXE / Nocloud). Note each node's
#    maintenance-mode IP (printed on console / from your DHCP leases).
#    Pick the control-plane endpoint (a VIP or the first CP node's IP).
export CONTROL_PLANE_IP=10.0.0.10        # first control-plane node
export CLUSTER_ENDPOINT="https://${CONTROL_PLANE_IP}:6443"

# 1. Generate the cluster's machine configs + talosconfig.
talosctl gen config gt-core "${CLUSTER_ENDPOINT}" --output-dir _out
#   → _out/controlplane.yaml  _out/worker.yaml  _out/talosconfig

# 2. Bare-metal essentials to set in the machineconfig BEFORE applying:
#    - machine.install.disk: the real install disk (e.g. /dev/sda or /dev/nvme0n1)
#        confirm with: talosctl -n <ip> get disks --insecure
#    - machine.network: hostname / static IPs / VIP if not using DHCP
#    - (optional) machine.kubelet.extraMounts + a CSI for PVCs (see note below)
#   Edit _out/controlplane.yaml / _out/worker.yaml, or layer patches:
#    talosctl machineconfig patch _out/controlplane.yaml --patch @patches/install-disk.yaml -o _out/controlplane.yaml

# 3. Apply config to each node (still in maintenance mode → --insecure).
talosctl apply-config --insecure -n "${CONTROL_PLANE_IP}" --file _out/controlplane.yaml
talosctl apply-config --insecure -n 10.0.0.11 --file _out/worker.yaml     # each worker
#   The node reboots into the configured system and installs to the disk.

# 4. Point talosctl at the cluster, then bootstrap etcd ON ONE control-plane node ONLY.
export TALOSCONFIG="$PWD/_out/talosconfig"
talosctl config endpoint "${CONTROL_PLANE_IP}"
talosctl config node "${CONTROL_PLANE_IP}"
talosctl bootstrap                       # run ONCE, on a single CP node

# 5. Pull the kubeconfig once the API server is up.
talosctl kubeconfig .                     # writes ./kubeconfig
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes                         # all nodes Ready
```

**Storage / CSI (decide before Step 4).** The chart's StatefulSets need a
`storageClass` and the shared eventlog PVC wants **ReadWriteMany**. On a
single-node lab cluster `local-path` is fine if you keep the API at 1 replica
and co-schedule the daemon (see [Step 4](#step-4--stateful-services--verify-pvcs)).
For a real cluster install a CSI that offers RWX (Longhorn, Ceph/Rook, or an NFS
provisioner) and set `--set storageClass=<class>`.

---

## Step 2 — Install the GitOps controller (or `helm install` directly)

Two supported paths. **GitOps (Argo CD) is the steady-state target**; a direct
`helm install` is fine for a first bring-up / lab.

### Path A — GitOps with Argo CD (recommended, retires watchtower)

Full detail: [`gitops/README.md`](gitops/README.md).

```sh
# 1. Install Argo CD into its own namespace.
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Manage platform secrets out-of-band (Step 3 below). The Application installs
#    the chart with secrets.create=false, so an externally-managed Secret named
#    `gt-gt-secrets` in namespace `gt` MUST exist first.

# 3. (private repo) register repo creds, then apply the Application — the ONLY
#    kubectl apply; everything after is git.
kubectl apply -f gitops/argocd/application.yaml

# 4. Watch Argo reconcile namespace `gt` to chart/gt.
kubectl -n argocd get applications gt-platform -w
```

The Application (`gitops/argocd/application.yaml`) pins image tags under
`helm.valuesObject.{mcpServer,daemons,web,docs}.image.tag`; a **deploy is a PR
bumping that tag**, and a rollback is `git revert`. Probes + `maxUnavailable: 0`
gate the rollout, so the `.9` watchtower crash-loop failure mode is structurally
gone.

> **[PENDING] hq-talos-migration.9 — immutable per-sha tags.** The Application
> currently tracks the **moving** tags (`:embeddings`, `:latest`) because the
> gt-core / gt-web `docker-publish` workflows only push those. This is already an
> improvement (the deploy is now a reviewable git change) but is not yet a fully
> immutable target. The follow-up — push `:<sha>` per commit in CI and pin the
> Application to it — lives outside this repo (gt-core + gt-web CI). See
> [`gitops/README.md`](gitops/README.md) §"The immutable-tag flow".

### Flux alternative

Use `gitops/flux/helmrelease.yaml` instead. Apply **EITHER** Argo **OR** Flux,
never both. See [`gitops/README.md`](gitops/README.md) §"Flux alternative".

### Path B — direct `helm install` (first bring-up / lab)

```sh
helm lint chart/gt
helm install gt chart/gt -f values-secret.yaml --set storageClass=<your-csi-class>
```

`-f values-secret.yaml` carries the secrets (Step 3) when `secrets.create=true`.
The post-install hooks create the MinIO bucket + gate on the stores; the API
rolls only once its pods pass `/health` (schema + live seeds run at API boot —
see [Step 6](#step-6--seeds)).

---

## Step 3 — Secrets → k8s Secret

The chart templates its Secret from `.Values.secrets`
(`chart/gt/templates/secret.yaml`). Keys mirror the compose `.env` + `./secrets/*`
files. Start from the example:

```sh
cp chart/gt/values-secret.yaml.example values-secret.yaml   # gitignored — NEVER commit
$EDITOR values-secret.yaml
```

| Key | Env | Required for |
| --- | --- | --- |
| `postgresPassword` | `POSTGRES_PASSWORD` | always |
| `minioRootUser` / `minioRootPassword` | `MINIO_ROOT_USER/PASSWORD` | always |
| `secretKey` | `GT_SECRET_KEY` | oauth-feature image builds (AES-GCM seal) |
| `oidcRedirectUri` / `oauthFeRedirectUrl` | `GT_OIDC_REDIRECT_URI` / `GT_OAUTH_FE_REDIRECT_URL` | oauth builds |
| `oauthSeedSecretGoogle` | `GT_OAUTH_SEED_SECRET_GOOGLE` | boot-seeded google provider (empty ⇒ google login skipped; seeded `enabled=false`) |
| `jwtPrivateKey` / `jwtPublicKey` | RS256 login keys (PEM bodies of `secrets/jwt_*.pem`) | always (login) |
| `adminEmail` / `adminPassword` | `GT_ADMIN_*` | admin seed (both or it skips) |
| `githubAppId` / `githubAppPrivateKey` / `githubAppWebhookSecret` | `GT_GITHUB_APP_*` | GitHub App push webhook + private-rig JIT tokens |
| `rigGitToken` | `GT_RIG_GIT_TOKEN` | orchd singleton clone of a private rig |

Two ways to deliver them:

- **`secrets.create=true`** — the chart renders the Secret from your
  `values-secret.yaml`. Simple; the values live (only) in that gitignored file.
- **`secrets.create=false`** (GitOps default, see the Argo Application) — you
  manage an externally-named Secret `gt-gt-secrets` in namespace `gt` via
  **sealed-secrets / external-secrets / SOPS**. Required for the Argo path so no
  secret material is ever rendered from git.

```sh
# sealed-secrets example: install the controller, then seal each key into
# a Secret named gt-gt-secrets in namespace gt.
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
# ...kubeseal the keys from values-secret.yaml.example into gt-gt-secrets...
```

---

## Step 4 — Stateful services + verify PVCs

The chart's StatefulSets (`chart/gt/templates/{postgres,dolt,minio}.yaml`) +
the shared PVCs (`chart/gt/templates/pvc-shared.yaml`) come up as part of the
`helm install` / Argo sync. Confirm they bind and the stores accept connections
before anything seeds.

```sh
# StatefulSets ready, PVCs Bound.
kubectl -n gt get statefulset,pvc
kubectl -n gt get pods -l app.kubernetes.io/name=gt
# Expect: gt-postgres-0, gt-dolt-0, gt-minio-0 Running; PVCs
#   data-gt-postgres-0 / data-gt-dolt-0 / data-gt-minio-0 + gt-eventlog + gt-graph Bound.
```

**Eventlog access mode.** The eventlog PVC is a **file-based, single-writer**
store the API and the singleton daemon both mount. Default
`eventlog.accessMode: ReadWriteMany`. If your CSI has no RWX, set
`--set eventlog.accessMode=ReadWriteOnce` **and** keep `mcpServer.api.replicas=1`
co-scheduled with the singleton — see
[`chart/gt/README.md`](chart/gt/README.md) §"Stateful topology".

**API/daemon split (bead .4).** The gt-mcp-server binary honours a single
`GT_RUN_DAEMONS` gate (default ON; `=0` disables every singleton daemon loop).
The chart sets `GT_RUN_DAEMONS=0` on the API tier and `=1` on the singleton, so
exactly one pod ticks the reaper / archive / drift-reconcile / account-GC /
convoy→scheduler / quota-rotation loops. **The API may scale to N replicas
safely** — none of them tick a singleton loop, and the boot seeds (not daemons)
are idempotent so racing replicas don't double-seed. Detail in
[`chart/gt/README.md`](chart/gt/README.md) §"API vs daemon split".

---

## Step 5 — Data migration (prod → cluster)  *(migration path only)*

> Skip this entire step for a **greenfield** bring-up with no prior data — go to
> [Step 6](#step-6--seeds) and rely on seeds. Do this step only when
> migrating the **existing prod compose stack** onto the new cluster.

Full detail + per-store verification: [`migrate/README.md`](migrate/README.md).
The scripts default to `DRY_RUN=1` (print only); they **never delete the old
docker volumes** — those are the rollback in [Step 9](#step-9--rollback).

```sh
cd migrate

# 0. REHEARSE (writes nothing).
DRY_RUN=1 ./migrate-all.sh

# 1. QUIESCE — REQUIRED for a clean snapshot (maintenance window):
#    - FE returns 503 / is stopped.
#    - scale the NEW cluster writers to 0 so nothing on the new side writes:
kubectl -n gt scale deploy/gt-api deploy/gt-daemons --replicas=0
#    - stop the OLD compose writers (keep the DB/MinIO/eventlog containers UP so
#      the scripts can read them):
docker compose stop gt-mcp-server gt-orch-server gt-web gt-docs

# 2. Real migration, one store at a time (each self-verifies, fails closed):
DRY_RUN=0 ./migrate-postgres.sh all
DRY_RUN=0 ./migrate-dolt.sh     all
DRY_RUN=0 ./migrate-minio.sh    all     # needs SRC/DST MinIO endpoint wiring — see README
DRY_RUN=0 ./migrate-eventlog.sh all     # scale API/daemon to 0 first to free the mount
#    …or the wrapper (same order): DRY_RUN=0 ./migrate-all.sh
```

What moves: whole-DB `pg_dump` (every `ws_*`/`hq_*` schema + pgvector) + roles;
Dolt working set (or full history via the clone appendix); MinIO bucket via
`mc mirror`; eventlog via tar into a helper pod. Each store verifies source vs
target (counts / rollup hashes) and **prints `keep the old volume` on
mismatch — do NOT cut over if any verify fails.**

---

## Step 6 — Seeds

> **hq-greenfield-seeds — SHIPPED.** The live-curated platform state is now
> reproducible as **boot seeds** that run at **API boot** inside `gt-mcp-server` —
> NOT via the seed Job, NOT manually. Each is idempotent (gated on its
> table/catalog being EMPTY), so a greenfield cluster comes up **functional** and
> a migration (Step 5) leaves the carried-across state untouched (seeds skip).

**Seeds that run at API boot (idempotent — no operator action):**

| Seed | Requires | Notes |
| --- | --- | --- |
| PG migration array + Dolt `ensure_database`/`ensure_schema` | — | always |
| Global admin (`seed_admin`) | `GT_ADMIN_EMAIL` + `GT_ADMIN_PASSWORD` | both or it skips |
| Default workspace + template | — | always |
| Role / skills **catalog** (knowledge: prompts + skill bodies + role→skill scope bindings) | — | empty-catalog gated |
| IdP / OAuth providers (e.g. `google`) | `GT_SECRET_KEY` + `GT_OAUTH_SEED_SECRET_GOOGLE` | empty-table gated; seeded provider `enabled=false` until an admin enables it; unset secret ⇒ that provider skipped |
| Rig catalog (`gt`/`gt_core`/`gtmcp`/`gtproxy`/`gtweb`) | — | empty-table gated |
| RBAC guard hooks + MinIO `gt-documents` bucket | — | always |

**The one NON-boot seed — quota Claude accounts.** Per-account `CLAUDE_CONFIG_DIR`
credential dirs are provisioned by an **operator** under `GT_CLAUDE_ACCOUNTS_ROOT`
(chart `daemons.claudeAccountsRoot`, defaults to `<eventlog>/accounts` on the
shared eventlog PVC) via the onboarding REST surface / `quota.register`. The
rotation daemon (singleton) rebuilds its keychain from that root on (re)start.
See gt-core `docs/ops/greenfield-seeds.md` §4.4.

**The seed Job is only a readiness gate.** `chart/gt/templates/seed-job.yaml`
(post-install/upgrade hook) waits for Dolt + Postgres so the first API pod boots
against ready stores. It deliberately does **not** run the live seeds — those run
at API boot and are empty-table gated, so a Job seed would only fight that gate.

**Canonical detail:** gt-core `docs/ops/greenfield-seeds.md` (secrets matrix §3,
per-seed §4.x) and the bring-up runbook `docs/ops/greenfield-bringup.md`.

---

## Step 7 — Verify (smoke checklist)

> The seed-dependent checks PASS on a greenfield cluster (the boot seeds ran —
> [Step 6](#step-6--seeds)) and on a migration (Step 5 carried the state across).
> The one exception is **Quota**, which needs an operator to provision the Claude
> account dirs (not a boot seed).

Cross-reference the canonical greenfield smoke checklist: **gt-core
`docs/ops/greenfield-seeds.md` §6** and the step-by-step bring-up runbook
`docs/ops/greenfield-bringup.md` (both shipped). Interim cluster-side list:

| Check | How | Source |
| --- | --- | --- |
| API health | `kubectl -n gt port-forward svc/gt-mcp-server 8765:8765`; `curl localhost:8765/health` | always |
| Admin login | log in as `GT_ADMIN_EMAIL` via the FE | admin seed |
| Default workspace | workspace list shows the default ws | boot |
| MCP reachable | full MCP session (`initialize` + SSE), then e.g. `ping` / `issues_list_execute` — NOT a bare `curl tools/call` (422s) | always |
| Tracker | `issues_list_execute` returns beads | migrated/seeded Dolt |
| Roles w/ prompt + scopes | `GET /api/v1/skills` shows the role→skill bindings; a role session loads its prompt + can mutate per its scopes | boot seed (knowledge) |
| IdP / OAuth providers | `/admin/providers` lists the seeded providers (e.g. google, `enabled=false`) | boot seed (needs `GT_OAUTH_SEED_SECRET_GOOGLE`) |
| GitHub App | push webhook marks a rig stale; private-rig JIT clone works | `GT_GITHUB_APP_*` secrets |
| Rigs | `rig_list` shows the seeded rigs | boot seed |
| Quota | `quota_list` shows Claude accounts; rotation can fire | **operator-provisioned** (not a boot seed) |

---

## Step 8 — Cutover (DNS / traffic switch + retire watchtower)

Do this **only after** all relevant verifies pass (and, for a migration, all four
data verifies in Step 5).

```sh
# 1. Scale the new cluster back up (if Step 5 scaled it to 0).
kubectl -n gt scale deploy/gt-api --replicas=2 deploy/gt-daemons --replicas=1

# 2. Point DNS / the Ingress at the cluster. The chart's Ingress
#    (chart/gt/templates/ingress.yaml) replicates the compose Traefik routing:
#      /auth /api /mcp /stream /openapi.json /health /.well-known → mcp-server:8765
#      /docs /share                                                → gt-docs:3000
#      /                                                            → gt-web:3000 (catch-all)
#    TLS via cert-manager (the compose ACME-DNS-01-via-Netlify resolver has no
#    k8s analogue — wire a clusterIssuer in ingress.annotations).
#    Switch the DNS A/AAAA record for gt.codecsrayo.com to the cluster ingress IP
#    (or repoint the shared Traefik plane). Watch for the new cert to issue.

# 3. RETIRE WATCHTOWER + the compose stack (gitops/README.md is explicit: running
#    watchtower AND a GitOps controller at once is undefined). Once GitOps is the
#    deploy path:
docker compose stop watchtower
docker compose stop gt-mcp-server gt-orch-server gt-web gt-docs proxy
#    Leave the DB/MinIO/eventlog containers + their volumes intact as the
#    rollback (Step 9) until the cluster has been trusted for days, not minutes.
```

After cutover, deploys are GitOps: bump the image tag in
`gitops/argocd/application.yaml` via a PR → merge → Argo syncs, probe-gated.

---

## Step 9 — Rollback

The migration **never deletes the old docker volumes**, so the old compose stack
is the rollback. Any verify failure, or a post-cutover regression:

```sh
# 1. Bring the compose stack back up (original volumes untouched).
docker compose up -d
#    (Always pass both files so gt-mcp-server keeps the :embeddings/oauth image:
#     docker compose -f docker-compose.yml -f compose.embeddings.yml up -d)

# 2. Scale the k8s API/daemon back to 0 so nothing on the new side writes.
kubectl -n gt scale deploy/gt-api deploy/gt-daemons --replicas=0

# 3. Revert DNS / the Ingress back to the compose stack.

# 4. Fix the cause, re-run the migration (Step 5) after re-quiescing.
```

**GitOps-level rollback** (if the failure was a bad deploy, not the migration):
`git revert <bump-commit>` the tag bump → Argo syncs back to the old tag; or the
fast operator override `argocd app rollback gt-platform <history-id>` (then
reconcile back to git). See [`gitops/README.md`](gitops/README.md) §"Rollback".

Reclaim the old docker volumes (`docker volume rm gt-app_dolt-data …`) **only**
after the cluster has been the source of truth long enough to trust.

---

## Appendix — what each referenced artifact is

- `chart/gt/` — the Helm chart (StatefulSets, Deployments, Ingress, Secret,
  seed-Job; `runAsNonRoot` + `fsGroup: 1000`, obsoletes hq-vcs-connections.10/.11).
- `gitops/argocd/application.yaml` — the Argo CD Application (primary CD).
- `gitops/flux/helmrelease.yaml` — the Flux GitRepository + HelmRelease (alt).
- `migrate/migrate-*.sh` + `migrate/lib/common.sh` +
  `migrate/manifests/eventlog-migrate-pod.yaml` — the operator data-migration
  scripts (DRY_RUN-default, fail-closed verification, old volumes preserved).
