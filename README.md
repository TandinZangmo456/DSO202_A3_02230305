# DSO202 Assignment 3: Task Tracker with Kustomize and Helm

## 1. Overview

Assignment 1 deployed the Task Tracker with plain YAML for one environment. Here the same app is deployed to **dev** and **prod** in two ways:

* **Kustomize**: the shared manifests sit once in a base, and each environment is a small overlay that only lists what differs.
* **Helm**: the app is a versioned chart, each environment is a values file, and each install is a release that can be upgraded and rolled back.

All Assignment 1 rules still hold. The rules are: tag `1.0` only, no plaintext credentials in Git, `tier` labels, a headless database, a ClusterIP backend, a NodePort frontend, a PVC, and a quota and LimitRange.

| | dev | prod |
|---|---|---|
| Namespace | `dso202-a3-dev` | `dso202-a3-prod` |
| Backend / frontend / db replicas | 1 / 1 / 1 | 2 / 2 / 1 |
| Backend requests / limits | 50m, 64Mi / 250m, 128Mi | 100m, 128Mi / 500m, 256Mi |
| Database requests / limits | 100m, 256Mi / 500m, 512Mi | 250m, 512Mi / 1, 1Gi |
| Database volume | 1Gi | 2Gi |
| CORS_ORIGIN | `*` | `http://localhost:30081` |
| Frontend NodePort | 30080 | 30081 |

## 2. Repository layout

```
kind-config.yaml            maps NodePorts 30080 and 30081
kustomize/
  base/                     7 tier manifests, kustomization.yaml, app-config.env,
                            app-secret.env.example
  overlays/dev/             kustomization.yaml, namespace.yaml, governance.yaml
  overlays/prod/            same, plus 3 patch files
helm/
  task-tracker/             Chart.yaml, values.yaml, values.schema.json, templates/
  environments/             dev.yaml, prod.yaml, secrets.yaml.example
evidence/                   screenshots (section 8)
```

## 3. Kustomize

**Base and overlays.** The base holds the Assignment 1 manifests with no namespace. Each overlay imports it with `resources: - ../../base` and adds only its namespace, quota, labels, replica counts and patches. No Deployment is copied into an overlay.

| Feature | Used for |
|---|---|
| `namespace` | puts every object in the overlay's namespace |
| `labels` | adds `part-of`, `managed-by` and `environment` labels. `includeSelectors: false` keeps the immutable selectors unchanged |
| `images` | sets tag `1.0` for all three images in one place |
| `replicas` | backend and frontend 1 in dev, 2 in prod; the database stays at 1 |
| `configMapGenerator` / `secretGenerator` | builds the ConfigMap and Secret from env files, adding a content hash to each name |
| `behavior: merge` | prod overrides only `CORS_ORIGIN` |
| Strategic merge patch | prod backend and database resources (matched by container name) |
| JSON 6902 patch (file) | prod frontend `/spec/ports/0/nodePort` to 30081, plus an annotation whose `/` is written as `~1` |
| JSON 6902 patch (inline) | prod PVC size to 2Gi |

**A config change causes a rollout.** When the content of the ConfigMap changes, its hash changes, and Kustomize writes the new name into every Deployment that uses it. Because the Pod template changed, Kubernetes rolls the Deployment out. In Assignment 1 the Pods had to be restarted by hand.

**No namePrefix.** A prefix would rename the Services, but Kustomize does not rewrite the plain strings `DB_HOST=db-svc` and `BACKEND_URL` inside the ConfigMap, so the app would break. The two separate namespaces already keep the environments apart.

## 4. Helm

The `task-tracker` chart is `apiVersion: v2`, with chart `version: 0.1.0` and `appVersion: "1.0"`, which is also the default image tag.

* **Helpers** (`_helpers.tpl`) build the object names, the full label set and a small selector label set. Labels that change between versions, such as `helm.sh/chart`, stay out of the selectors.
* **Derived values.** The chart builds `DB_HOST` and `BACKEND_URL` from the same helpers that name the Services, so they always match. Kustomize cannot do this.
* **One credential, two names.** `credentials.user` and `credentials.password` are written once and appear in the Secret under both the DB_* and POSTGRES_* keys.
* **Fixed exposure.** The Service types are hard-coded, so no values file can expose the backend or database.
* **`checksum/config` and `checksum/secret`** annotations make a value change roll out the Pods.
* **Validation.** `required` stops rendering when the environment or credentials are missing. `values.schema.json` rejects:
  * the tag `latest`;
  * replicas outside 1 to 5;
  * ports given as strings;
  * NodePorts outside 30000 to 32767.
* **`helm test`** runs a Pod that calls the backend Service by name and passes only if it reports `"db":"connected"`.
* **NOTES.txt** prints the URL and the port-forward command after each install.

`environments/prod.yaml` sets every key prod depends on. Each environment is installed with its own file only, so values never leak between them.

## 5. Kustomize and Helm compared

| | Kustomize | Helm |
|---|---|---|
| Input | plain YAML plus patches | Go templates |
| Per environment | overlay folder | values file |
| Config change causes a rollout | hash suffix | checksum annotation |
| History and rollback | Git commit, then apply again | `helm history`, `helm rollback` |
| Removal | `kubectl delete -k` (also deletes the namespace) | `helm uninstall` (namespace stays) |
| Validation | render and `kubectl diff -k` | schema, `required`, `helm lint`, `helm test` |

Kustomize suits a team deploying its own app, because the YAML stays readable and an overlay shows exactly what changes. Helm suits versioning, sharing and rolling back the whole app as one unit.

## 6. Secrets and quota

**Secrets.** No credential is in Git. `app-secret.env` and `secrets.yaml` are gitignored, and only `.example` copies are committed. There are two caveats:

* Kubernetes Secrets are only base64-encoded, not encrypted at rest by default.
* Helm also stores every value, including the password, in its release record Secret, where `helm get values` shows it in plain text (H7). The chart's `credentials.existingSecret` option avoids this.

**Quota.** dev keeps the Assignment 1 sizing: steady state 175m / 352Mi requests and 850m / 704Mi limits, under a quota of 500m / 1Gi and 2 / 1536Mi.

For prod:

* Steady state is 500m / 832Mi requests and 2200m / 1664Mi limits.
* A rolling update adds one extra backend and frontend Pod, peaking at 625m / 992Mi requests and 2800m / 1984Mi limits.
* The quota of 1 CPU / 2Gi requests, 4 CPU / 3Gi limits and 12 Pods covers that peak plus a test Pod.
* The LimitRange maximum is 1 CPU / 1Gi, the size of the prod database.
* In both environments, `services.nodeports: 1` and `services.loadbalancers: 0` let only the frontend be exposed.

## 7. How to run

```bash
kind create cluster --config kind-config.yaml
kind load docker-image sarojsanyasi/dso202-frontend:1.0 sarojsanyasi/dso202-backend:1.0 sarojsanyasi/dso202-db:1.0 --name dso202
cp kustomize/base/app-secret.env.example kustomize/base/app-secret.env      # set a password
cp helm/environments/secrets.yaml.example helm/environments/secrets.yaml    # same password

# Kustomize
kubectl kustomize kustomize/overlays/dev
kubectl apply -f kustomize/overlays/dev/namespace.yaml
kubectl diff -k kustomize/overlays/dev
kubectl apply -k kustomize/overlays/dev        # same for prod
kubectl delete -k kustomize/overlays/dev

# Helm (run from helm/)
helm lint task-tracker -f environments/dev.yaml -f environments/secrets.yaml
helm install task-tracker ./task-tracker -n dso202-a3-dev --create-namespace \
  -f environments/dev.yaml -f environments/secrets.yaml --wait
helm test task-tracker -n dso202-a3-dev
helm upgrade task-tracker ./task-tracker -n dso202-a3-dev \
  -f environments/dev.yaml -f environments/secrets.yaml --set backend.replicaCount=2 --wait
helm rollback task-tracker 1 -n dso202-a3-dev
helm uninstall task-tracker -n dso202-a3-dev
```

Kustomize and Helm use the same namespaces and NodePorts, so remove one before deploying the other.

## 8. Evidence

![kind cluster created and images loaded](evidence/setup/00-kind-cluster.png)

### Kustomize

**K1.** The dev render has 12 objects. The generated names are `app-config-t6cd8tcbf7` and `app-secret-d7mf5k955h`, every reference points to them, and all images are `:1.0`.

![K1](evidence/kustomize/K1-render-dev.png)

**K2.** dev and prod differ only in nodePort, storage, replicas, resources and the ConfigMap hash. prod's hash differs because of the CORS merge.

![K2](evidence/kustomize/K2-diff-dev-prod.png)

**K3.** Dev applied. All 3 Pods are Running, every object has the `tier` and `environment=dev` labels, and the PVC is Bound at 1Gi. Quota usage is exactly 175m / 352Mi requests and 850m / 704Mi limits.

![K3](evidence/kustomize/K3-apply-dev.png)
![K3b](evidence/kustomize/K3b-dev-objects.png)
![K3c](evidence/kustomize/K3c-dev-pvc-quota.png)

**K6.** Through a port-forward, `/api/status` returned `"db":"connected"`, and task 4 was created and listed. From inside the frontend Pod, `curl http://backend-svc:8080` worked, so cluster DNS resolves the Service.

![K6a](evidence/kustomize/K6a-port-forward.png)
![K6](evidence/kustomize/K6-crud-dns.png)

**K5.** After changing `CORS_ORIGIN`, the new `app-config-2kkb6dbtd6` was created and all three Deployments got new ReplicaSets while the old ones dropped to 0. Task 4 survived the database Pod being replaced, because the data is on the PVC.

![K5](evidence/kustomize/K5-config-rollout.png)
![K5b](evidence/kustomize/K5b-task-survives.png)

**K4.** Prod runs 2 backend, 2 frontend and 1 db Pod, with NodePort 30081, a 2Gi PVC and quota usage of 500m / 832Mi and 2200m / 1664Mi. The JSON 6902 annotation is present.

![K4](evidence/kustomize/K4-prod-apply.png)
![K4b](evidence/kustomize/K4b-prod-objects-quota.png)

**K7.** `kubectl delete -k` removed everything, including both namespaces.

![K7](evidence/kustomize/K7-delete.png)

### Helm

**H1, H2.** Both lints pass. A missing environment, missing credentials, `image.tag=latest` and `replicaCount=0` are each rejected before anything reaches the cluster.

![H1-H2](evidence/helm/H1-H2-lint-failures.png)

**H3, H4.** Dev installed as revision 1. `helm status` lists every object, the NOTES are printed, and `helm test` passed with `{"status":"ok","db":"connected"}`.

![H3](evidence/helm/H3-install-dev.png)
![H3 status](evidence/helm/H3-status-dev.png)
![H3 notes](evidence/helm/H3-status-dev-2.png)
![H4](evidence/helm/H4-test.png)

Prod installed with 2/2/1 replicas, NodePort 30081, a 2Gi PVC and the same quota usage as Kustomize. Its test passed. A repeated install was refused ("cannot reuse a name"), and `helm list -A` shows one release per namespace.

![H3b](evidence/helm/H3b-install-prod.png)
![H3c](evidence/helm/H3c-prod-test-list.png)

**H5, H6.** The upgrade to 2 backend replicas created revision 2. Only the replica count changed, so the Deployment scaled with the same ReplicaSet. The rollback created revision 3, "Rollback to 1", and the old revisions were kept.

![H5](evidence/helm/H5-upgrade.png)
![H6](evidence/helm/H6-rollback.png)

**H7.** One release record Secret per revision. `helm get values` shows the password in plain text, and `--revision 2` shows that revision's values.

![H7](evidence/helm/H7-release-values.png)

**H8.** Both releases were uninstalled. The namespaces stayed Active and the completed test Pod was left behind, because neither is part of the release. They were then removed with `kubectl delete ns`.

![H8](evidence/helm/H8-uninstall.png)

