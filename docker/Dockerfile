# syntax=docker/dockerfile:1.9

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — build
#
# Build context is the REPOSITORY ROOT (see docker/README.md), so every COPY is
# prefixed with app/. Building from the root is what lets .dockerignore exclude
# the infra directories in one place.
# ─────────────────────────────────────────────────────────────────────────────
FROM golang:1.26-bookworm AS build

WORKDIR /src

# Dependency manifests are copied on their own so that `go mod download` lands in
# its own layer. Editing application source then reuses that layer; only a change
# to go.mod/go.sum re-downloads modules.
COPY app/go.mod app/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download && go mod verify

COPY app/ ./

# Build metadata, supplied by CI (see .github/workflows/ci.yaml). Declared after
# the dependency layer so a new commit SHA never invalidates the module cache.
ARG VERSION=dev
ARG REVISION=unknown

# CGO_ENABLED=0 produces a statically linked binary, which is what makes the
# distroless *static* base viable — there is no libc in the runtime image.
#   -trimpath  strips local filesystem paths from the binary (reproducibility +
#              no build-host paths leaking into stack traces)
#   -s -w      drops the symbol table and DWARF data (~30% smaller; debuggers
#              are useless against a distroless container anyway)
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/app .

# Fail the build if cgo crept back in. A dynamically linked binary compiles fine
# here and then crashes at runtime on distroless/static with a confusing
# "no such file or directory" from the missing loader — so catch it now, where
# the error message can say what actually happened.
#
# Deliberately written without a pipe, for two independent reasons:
#
#   1. `ldd … | grep -q` trips hadolint DL4006. Under plain /bin/sh only the last
#      command's status counts, so a failure in ldd itself would be masked by a
#      matching grep and the assertion would quietly stop asserting.
#   2. Adding `-o pipefail` to fix that BREAKS the check, which is the
#      counter-intuitive part: `ldd` exits non-zero when the file is not a
#      dynamic executable — i.e. in the success case. pipefail then propagates
#      that as a build failure on a perfectly good static binary.
#
# Capturing the output and matching it with `case` sidesteps both.
RUN LDD_OUT="$(ldd /out/app 2>&1 || true)"; \
    case "${LDD_OUT}" in \
      *"not a dynamic executable"*) \
        echo "OK: statically linked" ;; \
      *) \
        echo "FATAL: binary is dynamically linked; distroless/static has no loader." >&2; \
        echo "       ldd said: ${LDD_OUT}" >&2; \
        echo "       Check that CGO_ENABLED=0 survived into the go build above." >&2; \
        exit 1 ;; \
    esac

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — runtime
#
# distroless/static: no shell, no package manager, no busybox — only CA
# certificates, tzdata and /etc/passwd. Nothing for an attacker who achieves RCE
# to pivot with, and nothing for a CVE scanner to flag either.
#
# Pinned by digest, not just by tag: `:nonroot` is a moving tag, and "pin every
# version" (CLAUDE.md §11) is meaningless if the base can change under us.
# ─────────────────────────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="go-sample-app" \
      org.opencontainers.image.description="Sample Go HTTP service delivered to GKE via ArgoCD" \
      org.opencontainers.image.source="https://github.com/<gh-owner>/<gh-repo>" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="gcr.io/distroless/static-debian12:nonroot"

COPY --from=build /out/app /app

# uid:gid 65532:65532, matching runAsUser/runAsGroup in k8s/base/deployment.yaml.
# Declared here as well so `docker run` is non-root too, without relying on the
# orchestrator to impose it.
USER 65532:65532

# Documentation only — it publishes nothing by itself, but it is what tooling and
# reviewers read to learn the contract. Matches PORT's default in app/config.go.
EXPOSE 8080

# No HEALTHCHECK: every form of it shells out, and there is no shell in this
# image. Health is Kubernetes' job here — see the startup/liveness/readiness
# probes in k8s/base/deployment.yaml, which hit /healthz and /readyz.

ENTRYPOINT ["/app"]
