# DSO202 Assignment 3: Task Tracker with Kustomize and Helm

| | |
|---|---|
| Name | Tandin Zangmo |
| Student no. | 02230305 |
| Module | DSO202: Scaling, Orchestration, Monitoring & Observability (Unit IV) |
| Builds on | Assignment 1 ([DSO202_A1_02230305](https://github.com/TandinZangmo456/DSO202_A1_02230305)) |
| Images | `sarojsanyasi/dso202-frontend:1.0`, `sarojsanyasi/dso202-backend:1.0`, `sarojsanyasi/dso202-db:1.0` |
| Tools | kubectl (built-in Kustomize), Helm 4, kind |

## Contents

1. What this assignment does
2. Repository layout
3. Part A: Kustomize
4. Part B: Helm
5. Kustomize and Helm compared
6. Secrets
7. Resource governance for two environments
8. How to run it
9. Evidence
10. Issues and limitations

---

## 1. What this assignment does

In Assignment 1 the three-tier Task Tracker was deployed with plain YAML files applied one by one with `kubectl apply -f`. That works for one environment, but a second environment would mean copying every file and editing replicas, resources, the NodePort and the namespace by hand. The copies would then drift apart.

This assignment deploys the same application to two environments, **dev** and **prod**, in two ways:

* **Kustomize** keeps the shared manifests once in a base, and each environment is a thin overlay that lists only what is different.
* **Helm** packages the application as a versioned chart. Each environment is a values file, and each installation is a release with a revision history that can be upgraded and rolled back.

Every rule from Assignment 1 still holds in both versions: the issued image tag only (never `latest`), no plaintext credentials in Git, a `tier` label on every Pod, Deployment and Service, a headless database Service, a ClusterIP backend, a NodePort frontend, a PVC for the database, and a ResourceQuota and LimitRange.

| | dev | prod |
|---|---|---|
| Namespace | `dso202-a3-dev` | `dso202-a3-prod` |
| Backend replicas | 1 | 2 |
| Frontend replicas | 1 | 2 |
| Database replicas | 1 | 1 (one ReadWriteOnce volume serves one Pod) |
| Backend resources (req / limit) | 50m, 64Mi / 250m, 128Mi | 100m, 128Mi / 500m, 256Mi |
| Database resources (req / limit) | 100m, 256Mi / 500m, 512Mi | 250m, 512Mi / 1, 1Gi |
| Database volume | 1Gi | 2Gi |
| CORS_ORIGIN | `*` | `http://localhost:30081` |
| Frontend NodePort | 30080 | 30081 |

## 2. Repository layout

```
kind-config.yaml                 kind cluster with ports 30080 (dev) and 30081 (prod) mapped
kustomize/
  base/                          shared by every environment
    kustomization.yaml
    app-config.env               non-sensitive settings -> configMapGenerator
    app-secret.env.example       copy to app-secret.env (gitignored) -> secretGenerator
    database/  pvc.yaml  deployment.yaml  service.yaml
    backend/   deployment.yaml  service.yaml
    frontend/  deployment.yaml  service.yaml
  overlays/
    dev/   kustomization.yaml  namespace.yaml  governance.yaml
    prod/  kustomization.yaml  namespace.yaml  governance.yaml
           patch-backend-resources.yaml   patch-db-resources.yaml   (strategic merge)
           patch-frontend-service.yaml                               (JSON 6902)
helm/
  task-tracker/                  the chart
    Chart.yaml  values.yaml  values.schema.json  .helmignore
    templates/
      _helpers.tpl  configmap.yaml  secret.yaml  governance.yaml  NOTES.txt
      db-pvc.yaml  db-deployment.yaml  db-service.yaml
      backend-deployment.yaml  backend-service.yaml
      frontend-deployment.yaml  frontend-service.yaml
      tests/test-backend.yaml
  environments/
    dev.yaml  prod.yaml
    secrets.yaml.example         copy to secrets.yaml (gitignored)
evidence/  kustomize/  helm/
```

## 3. Part A: Kustomize

### 3.1 Base and overlays

The base holds what is shared: the seven tier manifests from Assignment 1, without a namespace and without per-environment values. The overlays import the base with `resources: - ../../base` and add only their own namespace, governance, labels, replica counts and patches. Neither overlay contains a copy of a Deployment.

The base on its own renders a complete deployment (`kubectl kustomize kustomize/base`), so it can be checked separately from any environment.

### 3.2 Features used and why

**Compose.** `resources:` collects the tier manifests in the base, and each overlay adds `namespace.yaml` and `governance.yaml` on top of `../../base`.

**namespace transformer.** `namespace: dso202-a3-dev` puts every object in the dev namespace without writing the namespace in any manifest.

**labels transformer.** The base adds `app.kubernetes.io/part-of: task-tracker` and `app.kubernetes.io/managed-by: kustomize` to every object, and each overlay adds `app.kubernetes.io/environment`. `includeSelectors: false` is set on purpose. Deployment selectors are immutable, and the Service selectors decide which Pods get traffic. Changing them through a broad label rule could break routing or block a later apply. The `tier` labels and selectors stay in the manifests themselves.

**images transformer.** The manifests name each image without a tag, and the base sets `newTag: "1.0"` for all three in one place. The rendered output always has the issued tag. Moving to a new issued tag means editing one field.

**replicas transformer.** dev sets backend and frontend to 1, prod sets them to 2. The database is not listed in either, so it stays at 1.

**configMapGenerator and secretGenerator.** In Assignment 1 the ConfigMap and Secret were written by hand. Here they are generated from env files:

* `app-config.env` holds the non-sensitive keys (DB_HOST, DB_PORT, DB_NAME, APP_PORT, CORS_ORIGIN, POSTGRES_DB, BACKEND_URL).
* `app-secret.env` holds DB_USER, DB_PASSWORD, POSTGRES_USER and POSTGRES_PASSWORD. It is in `.gitignore`, and only `app-secret.env.example` is committed.

Each generated object gets a hash of its content added to its name, for example `app-config-t6cd8tcbf7`. Kustomize also rewrites every `configMapKeyRef` and `secretKeyRef` in the Deployments to that hashed name. Nobody calculates or types the hash.

**Generator merge in prod.** The prod overlay merges one key into the base ConfigMap with `behavior: merge`, setting `CORS_ORIGIN=http://localhost:30081`. The image build guide notes that `*` is a classroom simplification and that a real deployment should restrict it to known origins, so prod restricts it to the prod frontend address.

**Patches.** prod uses both patch styles through the single `patches:` field. The older `patchesStrategicMerge` and `patchesJson6902` fields are not used.

| Patch | Style | Why this style |
|---|---|---|
| `patch-backend-resources.yaml` | strategic merge | Changing a named container's resources reads naturally as a piece of a Deployment. The container is matched by its name `backend`. |
| `patch-db-resources.yaml` | strategic merge | Same reason, for the `postgres` container. |
| `patch-frontend-service.yaml` | JSON 6902, from a file, target `Service/frontend-svc` | The nodePort is inside a list, so the exact path `/spec/ports/0/nodePort` is the most precise way to change it. The file also adds the annotation `dso202.cst.edu.bt/exposure`, whose `/` has to be written as `~1` in the path. |
| inline patch on `PersistentVolumeClaim/db-pvc` | JSON 6902, inline | A single `replace` of `/spec/resources/requests/storage` to 2Gi is small enough to keep inside `kustomization.yaml`. |

Every patch has a narrow target (kind and name), so it cannot affect other objects by accident. There are four patches, none of which write the same field, so the result does not depend on their order.

### 3.3 Config change causes a rollout

Changing a value in `app-config.env` changes the ConfigMap content, so its hash and generated name change. Because Kustomize rewrites the references, the Pod template of every Deployment that reads the ConfigMap changes too, and Kubernetes rolls those Deployments out:

content changes -> hash changes -> reference changes -> Pod template changes -> rollout

With the hand-written ConfigMap in Assignment 1, an edited value was not picked up until the Pods were restarted manually. Section 9 shows this rollout with evidence.

### 3.4 Why there is no namePrefix

`namePrefix` was considered and left out. Kustomize renames the Services and updates the references it knows about (selectors, configMapKeyRef). But the values `DB_HOST=db-svc` and `BACKEND_URL=http://backend-svc:8080` are plain strings inside the ConfigMap, and Kustomize does not rewrite strings. A prefix would have broken the backend to database connection. Separate namespaces already keep the two environments apart, so the Service names stay the same in both.

## 4. Part B: Helm

### 4.1 Chart

`helm/task-tracker` is an `apiVersion: v2` application chart.

* `version: 0.1.0` is the version of the chart (the package). It goes up whenever any chart file changes.
* `appVersion: "1.0"` is the issued image tag. It is quoted so YAML keeps it a string. The templates use it as the default tag, so the image tag lives in one field.
* `kubeVersion: ">=1.30.0-0"` stops installation on clusters older than 1.30.

### 4.2 Templates

**`_helpers.tpl`** holds named templates, all prefixed with `task-tracker.` because named templates are global:

* `fullname` gives the base name of every object, cut to 63 characters. A release called `task-tracker` gives `task-tracker`, not `task-tracker-task-tracker`.
* `dbName`, `backendName` and `frontendName` give the object names per tier.
* `selectorLabels` is the small, fixed set used by selectors (name, instance, tier).
* `labels` is the full recommended set: `helm.sh/chart`, `app.kubernetes.io/*`, `tier` and environment. Labels that change between versions, such as `helm.sh/chart` and `app.kubernetes.io/version`, are kept out of selectors, because a Deployment selector cannot be changed after install.
* `environment` uses `required`, so the chart refuses to render until dev or prod is chosen.
* `secretName` returns either the chart's own Secret or an existing Secret given in values.
* `image` builds `repository:tag`, using the per-tier tag, then `image.tag`, then `appVersion`.

**Values the chart works out.** In Assignment 1 and in the Kustomize version, DB_HOST and BACKEND_URL are typed by hand and have to match the Service names. In the chart, the ConfigMap template builds them from the same helpers that name the Services:

```yaml
DB_HOST: {{ include "task-tracker.dbName" . | quote }}
BACKEND_URL: {{ printf "http://%s:%v" (include "task-tracker.backendName" .) .Values.backend.service.port | quote }}
```

They cannot point at the wrong Service, whatever the release is called. This is something Kustomize cannot do (section 3.4).

**One credential, two names.** `secret.yaml` takes `credentials.user` and `credentials.password` once and writes them under both DB_* and POSTGRES_*. The backend and database values cannot drift apart, which was a manual check in Assignment 1.

**Fixed exposure.** The Service types are written in the templates, not taken from values. The backend is always ClusterIP and the database is always headless. No values file can expose them, so the Assignment 1 rule is enforced by the chart.

**checksum annotations.** The database and backend Pod templates carry `checksum/config` and `checksum/secret`, a sha256 of the rendered ConfigMap and Secret. The frontend carries `checksum/config`. A changed value changes the hash, which changes the Pod template, which causes a rolling update. This is the Helm version of the Kustomize hash suffix.

**governance.yaml** renders the ResourceQuota and LimitRange from values and can be switched off with `governance.enabled: false`. Helm orders objects by kind when it installs, so these exist before the Deployments.

**NOTES.txt** prints the frontend URL, the port-forward command for the backend and the `helm test` command after every install and upgrade.

**tests/test-backend.yaml** is a `helm test` hook Pod. It calls the backend Service by name from inside the namespace and passes only if `/api/status` reports `"db":"connected"`. One test therefore checks cluster DNS, the backend and the backend to database connection.

### 4.3 Values and validation

* **`values.yaml`** documents every setting, and its defaults are the dev sizing. `environment` and the credentials have no defaults on purpose.
* **`environments/dev.yaml` and `environments/prod.yaml`** sit outside the chart because they belong to a deployment of the chart, not to the chart. prod sets every key it depends on. Values files are deep-merged and each environment is installed with its own file only, never with both, so nothing leaks from one environment into the other.
* **`values.schema.json`** is checked against the merged values on every lint, template, install and upgrade. It rejects:
  * the tag `latest`;
  * a port given as a string or a number outside 1 to 65535;
  * replicas below 1 or above 5;
  * a NodePort outside 30000 to 32767;
  * a disk size not written as Mi or Gi;
  * an attempt to add a `type` to the backend Service.

  `required` checks that a value is present, and the schema checks its type and allowed values.

## 5. Kustomize and Helm compared

| | Kustomize | Helm |
|---|---|---|
| Input | Plain, valid Kubernetes YAML plus patches | Go templates that are not valid YAML until rendered |
| Per-environment config | An overlay directory | A values file |
| Values derived from others | Not possible (strings are not rewritten) | Templates compute them (DB_HOST, BACKEND_URL) |
| Config change causes a rollout | Hash suffix on generated names | `checksum/*` annotations |
| What was installed | Not recorded; the Git commit is the record | Release record per revision (`helm history`) |
| Rollback | Revert the commit and apply again | `helm rollback <release> <revision>` |
| Removal | `kubectl delete -k`, needs the same files | `helm uninstall`, Helm knows every object |
| Validation | Render and `kubectl diff -k` | `values.schema.json`, `required`, `helm lint`, `helm test` |
| Built into kubectl | Yes (`-k`) | No, separate binary |

Kustomize fits this application better when the same team writes and deploys it, because the base stays readable Kubernetes YAML and an overlay shows exactly what an environment changes. Helm fits better when the application has to be versioned, handed to someone else, or rolled back as one unit. The two can also be combined: a third-party chart installed with Helm and organisation-specific patches added with Kustomize.

## 6. Secrets

No credential is committed. Kustomize reads `kustomize/base/app-secret.env` and Helm reads `helm/environments/secrets.yaml`. Both are in `.gitignore`, and only `.example` copies with placeholder values are in the repository.

Three things still need to be said plainly:

* **Base64 is not encryption.** Kubernetes Secrets are only base64-encoded and are not encrypted at rest by default. Anyone who can read the Secret object can decode it with `base64 -d`.
* **Helm keeps the values.** Every value passed to a release, including the password, is stored in the release record Secret `sh.helm.release.v1.task-tracker.v<n>` in the namespace. It can be read back with `helm get values task-tracker -n <ns>`. The chart's `credentials.existingSecret` option avoids this: the Secret is created separately with `kubectl create secret generic`, and the chart only references it by name.
* **The build depends on an untracked file.** Kustomize renders deterministically only when everyone has the same `app-secret.env`. This trade-off is accepted so that no password is committed. A production setup would use an external secret store or Sealed Secrets instead, which is outside the scope of this assignment.

## 7. Resource governance for two environments

**dev** keeps the Assignment 1 values. With one replica per tier, the steady state is requests 175m CPU / 352Mi and limits 850m CPU / 704Mi. The quota (500m / 1Gi requests, 2 CPU / 1536Mi limits, 10 Pods) leaves about two to three times that, so a replacement Pod during self-healing or a rolling update is not blocked. `services.nodeports: 1` and `services.loadbalancers: 0` mean the quota itself enforces that only the frontend is exposed.

**prod** runs 2 backend and 2 frontend Pods and gives the database and backend more resources:

| | Requests | Limits |
|---|---|---|
| database x1 | 250m / 512Mi | 1 / 1Gi |
| backend x2 | 200m / 256Mi | 1000m / 512Mi |
| frontend x2 | 50m / 64Mi | 200m / 128Mi |
| Steady state | 500m / 832Mi | 2200m / 1664Mi |
| Peak in a rolling update (+1 backend, +1 frontend) | 625m / 992Mi | 2800m / 1984Mi |

The prod quota is requests 1 CPU / 2Gi, limits 4 CPU / 3Gi, 12 Pods and 4Gi of storage. That covers the rolling-update peak, a `helm test` Pod and a replacement Pod, with some room left. The database is not counted in the surge because it uses the Recreate strategy. The LimitRange maximum is raised to 1 CPU / 1Gi because the prod database limit is the largest container. The minimum and the defaults are the same as dev. All values are estimates sized from the Assignment 1 Pods, not from load testing.

## 8. How to run it

Create the cluster once, with both NodePorts mapped:

```bash
kind create cluster --config kind-config.yaml
```

Set up the credentials (both files are gitignored):

```bash
cp kustomize/base/app-secret.env.example kustomize/base/app-secret.env
cp helm/environments/secrets.yaml.example helm/environments/secrets.yaml
# then edit both files and set your own password
```

Kustomize and Helm deploy into the same two namespaces and would both claim NodePorts 30080 and 30081, so run Part A, delete it, then run Part B.

### Part A: Kustomize

```bash
kubectl kustomize kustomize/overlays/dev            # 1. render, nothing touches the cluster
kubectl diff -k kustomize/overlays/dev              # 2. what would change
kubectl apply -k kustomize/overlays/dev             # 3. apply
kubectl get all,pvc,cm,secret,quota,limitrange -n dso202-a3-dev --show-labels   # 4. verify

kubectl apply -k kustomize/overlays/prod
kubectl get deploy,svc,pvc -n dso202-a3-prod

# config change -> new hash -> rollout
#   edit one value in kustomize/base/app-config.env (for example CORS_ORIGIN), then:
kubectl diff -k kustomize/overlays/dev
kubectl apply -k kustomize/overlays/dev
kubectl rollout status deploy/backend -n dso202-a3-dev

kubectl delete -k kustomize/overlays/dev            # 5. clean up
kubectl delete -k kustomize/overlays/prod
```

### Part B: Helm

```bash
cd helm
helm lint task-tracker -f environments/dev.yaml -f environments/secrets.yaml
helm lint task-tracker -f environments/prod.yaml -f environments/secrets.yaml
helm template task-tracker task-tracker -n dso202-a3-dev --skip-tests \
  -f environments/dev.yaml -f environments/secrets.yaml > /tmp/dev.yaml
kubectl create namespace dso202-a3-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --dry-run=server -n dso202-a3-dev -f /tmp/dev.yaml   # API server checks every field

helm install task-tracker ./task-tracker -n dso202-a3-dev --create-namespace \
  -f environments/dev.yaml -f environments/secrets.yaml --wait --timeout 5m
helm test task-tracker -n dso202-a3-dev

helm install task-tracker ./task-tracker -n dso202-a3-prod --create-namespace \
  -f environments/prod.yaml -f environments/secrets.yaml --wait --timeout 5m
helm list -A

# upgrade: always pass every values file again
helm upgrade task-tracker ./task-tracker -n dso202-a3-dev \
  -f environments/dev.yaml -f environments/secrets.yaml --set backend.replicaCount=2 --wait
helm history task-tracker -n dso202-a3-dev
helm rollback task-tracker 1 -n dso202-a3-dev --wait
helm history task-tracker -n dso202-a3-dev

helm uninstall task-tracker -n dso202-a3-dev
helm uninstall task-tracker -n dso202-a3-prod
```

The Assignment 1 checks still apply to each environment: the CRUD cycle through `kubectl port-forward svc/<backend> 8080:8080`, DNS from inside the frontend Pod, and deleting the backend Pod while watching it come back with the data still present.

## 9. Evidence

Evidence goes in `evidence/kustomize/` and `evidence/helm/`.

### Kustomize

| # | What it shows | File |
|---|---|---|
| K1 | `kubectl kustomize` for dev and prod; generated names with hash suffix; references rewritten | _to add_ |
| K2 | `diff` of dev and prod renders: only namespace, replicas, resources, nodePort, PVC size, CORS and labels differ | _to add_ |
| K3 | `kubectl diff -k` then `apply -k` on dev; all objects in `dso202-a3-dev` with `tier` and environment labels | _to add_ |
| K4 | prod running: 2 backend, 2 frontend, 1 db; frontend on 30081; PVC 2Gi | _to add_ |
| K5 | Config change: new ConfigMap hash, Deployments roll out, old ReplicaSet scaled to 0 | _to add_ |
| K6 | CRUD through the backend port-forward in one environment | _to add_ |
| K7 | `kubectl delete -k` removes everything | _to add_ |

### Helm

| # | What it shows | File |
|---|---|---|
| H1 | `helm lint` for dev and prod | _to add_ |
| H2 | Failures caught before install: no environment (`required`), no credentials (`required`), `--set image.tag=latest` and `--set backend.replicaCount=0` (schema) | _to add_ |
| H3 | `helm install` dev and prod, NOTES output, `helm list -A` | _to add_ |
| H4 | `helm test` passes | _to add_ |
| H5 | `helm upgrade` (revision 2), Pods roll out, `helm history` | _to add_ |
| H6 | `helm rollback` to 1 creates revision 3 | _to add_ |
| H7 | Release record Secret and `helm get values` showing the stored password (section 6) | _to add_ |
| H8 | `helm uninstall` and the remaining namespace | _to add_ |

## 10. Issues and limitations

**The frontend cannot reach the backend from a browser.** This is unchanged from Assignment 1. BACKEND_URL is the cluster-internal address `http://<backend service>:8080` as the brief requires, but the frontend's `app.js` calls that address from the browser, where the name does not resolve, and the image's nginx has no `/api` proxy. Neither Kustomize nor Helm can fix this, because it is in the image. The backend stays ClusterIP, and CRUD is shown through `kubectl port-forward`. The prod `CORS_ORIGIN` value is set for correctness, but the browser path still fails for the same reason.

**Images.** In Assignment 1 the published images were linux/arm64 only, and they were built locally and loaded with `kind load docker-image`. If that is still needed, `imagePullPolicy: IfNotPresent` is set in both versions, so the loaded images are used.

**NodePort sharing.** The Kustomize and Helm deployments cannot run at the same time because they use the same NodePorts, which is why section 8 removes one before installing the other.
