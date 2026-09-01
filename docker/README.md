# Container image — Tasks 1 & 2

## Why this shape

| Choice | Reason |
|---|---|
| **Multi-stage build** | The Go toolchain (~1 GB) is a build-time dependency, not a runtime one. Only the compiled binary crosses into the final stage. |
| **`gcr.io/distroless/static-debian12:nonroot`** | No shell, no package manager, no busybox — just CA certificates, tzdata and `/etc/passwd`. An attacker who achieves RCE finds no tools to pivot with, and there is almost no package surface for a scanner to flag. This is the "hardened image" requirement. |
| **Pinned by digest** | `:nonroot` is a moving tag. "Pin every version" is meaningless if the base image can change underneath a rebuild, so the runtime stage pins `sha256:afa5c87…` explicitly. |
| **`CGO_ENABLED=0`** | Produces a statically linked binary. `distroless/static` has no libc, so a dynamically linked binary would build cleanly and then fail at startup with a misleading "no such file or directory". A `ldd` assertion in the build stage turns that into a build-time failure instead. |
| **`-trimpath`** | Strips build-host filesystem paths from the binary: reproducible builds, and no local directory layout leaking through stack traces. |
| **`-ldflags="-s -w"`** | Drops the symbol table and DWARF debug info (~30% smaller). Nothing is lost in practice — you cannot attach a debugger inside a distroless container anyway. |
| **`go mod download` in its own layer** | `go.mod`/`go.sum` are copied before the source, so editing application code reuses the cached module layer. Only a dependency change re-downloads. |
| **`USER 65532:65532`** | Non-root by default, matching `runAsUser` in `k8s/base/deployment.yaml`. Set here as well so `docker run` is non-root without depending on the orchestrator to impose it. |
| **No `HEALTHCHECK`** | Every form of it shells out, and there is no shell. Health is Kubernetes' concern — see the startup/liveness/readiness probes in the Deployment. |

## `.dockerignore` lives at the repository root — not here

The build context is the repo root (`docker buildx build -f docker/Dockerfile .`), and Docker only
reads `.dockerignore` from the **context root**. A file at `docker/.dockerignore` is silently
ignored: the build still succeeds while shipping the entire repository into the daemon. BuildKit
does additionally honour a `docker/Dockerfile.dockerignore` sibling, but that file is inert under
the classic builder — so the root file is the safe choice.

## Build and push (Task 2)

Release tag:

```bash
export TAG=v1.0.0
export DOCKERHUB_USER=<dockerhub-user>

docker buildx build \
  --platform linux/amd64 \
  -f docker/Dockerfile \
  --build-arg VERSION=${TAG} \
  --build-arg REVISION=$(git rev-parse HEAD) \
  -t ${DOCKERHUB_USER}/go-sample-app:${TAG} \
  --push .
```

CI build (see `.github/workflows/ci.yaml`) uses the same command with `TAG=sha-$(git rev-parse --short HEAD)`.

**`latest` is never built and never pushed.** Every deployment pins one immutable tag, so
"what is running in prod?" always has an exact answer, and a rollback is a tag change rather than a
race against whatever `latest` points to right now.

### Two registries, one tag

The image is **pushed** to Docker Hub (assignment requirement) but **pulled** through an Artifact
Registry remote repository, because every private GKE node egresses via a single Cloud NAT IP and
would collectively hit Docker Hub's per-IP pull limit. See `infra/terraform/README.md`.

```
push:  docker.io/<user>/go-sample-app:v1.0.0                                    ← CI writes here
pull:  <region>-docker.pkg.dev/<project>/dockerhub-remote/<user>/go-sample-app:v1.0.0   ← manifests reference this
```

A remote repository is a read-through cache: **it cannot be pushed to.** Do not point the build
command at the Artifact Registry URL.

### The published image

**https://hub.docker.com/r/dockerpeace/go-sample-app**

| | |
|---|---|
| Tag | `v1.0.0` |
| Digest | `sha256:8357fe65123debb9f2f85017d56d75f7ce62bc19ad448f08dd56d51cc94f719c` |
| Platform | `linux/amd64` |
| Source | `https://github.com/peacedwk55/go-gke-demo` |
| Revision | `2909d3b30c1ae7dda76aa781caa4b25b736a8960` |

A tag is a mutable pointer; the digest is the artefact. Read it back from the registry rather than
from a local image, so what is recorded is what was actually published:

```bash
docker buildx imagetools inspect dockerpeace/go-sample-app:v1.0.0
```

`image.source` and `image.revision` are build args rather than hardcoded values. An earlier version
of the Dockerfile baked `https://github.com/<gh-owner>/<gh-repo>` — a literal placeholder — into the
label. That is worse than omitting the label: it looks like supply-chain traceability and points
nowhere. Caught before the first push, which mattered because re-pushing to fix it would have left
the digest recorded above pointing at a superseded image.

## Local verification

```bash
# build
docker buildx build --platform linux/amd64 -f docker/Dockerfile \
  --build-arg VERSION=v1.0.0 -t go-sample-app:v1.0.0 --load .

# run
docker run --rm -p 8080:8080 go-sample-app:v1.0.0

curl -i localhost:8080/healthz          # 200
curl -i localhost:8080/readyz           # 200
curl    "localhost:8080/?name=world"    # Hello world
curl -s  localhost:8080/metrics | head  # Prometheus exposition

# there is no shell — this must fail
docker run --rm --entrypoint /bin/sh go-sample-app:v1.0.0 -c 'echo pwned'

# graceful drain: /readyz turns 503 immediately, the listener stays open ~5s
docker run -d --name drain-test -p 8080:8080 go-sample-app:v1.0.0
docker kill --signal=SIGTERM drain-test
while curl -s -o /dev/null -m 2 -w "%{http_code}\n" localhost:8080/readyz; do sleep 0.5; done

# scan
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.74.0 \
  image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 go-sample-app:v1.0.0
```

## Measured results (local, linux/amd64)

| Check | Result |
|---|---|
| Image size | **29 MB** (16.7 MB binary + ~2 MB distroless base + attestation) |
| Runs as | `65532:65532` — non-root |
| Shell present | No — `exec /bin/sh` fails with `stat /bin/sh: no such file or directory` |
| Statically linked | Yes — asserted at build time via `ldd` |
| Trivy HIGH/CRITICAL | **0** |
| Graceful drain | `/readyz` → 503 at t+141 ms; listener closed at ~t+5 s; exit code 0 |

> The binary is larger than a bare hello-world because the §1.1 contract pulls in the Prometheus
> client and the OpenTelemetry SDK. Still comfortably under the 30 MB budget, and the alternative —
> an app you cannot observe — is not a saving.
