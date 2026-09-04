#!/usr/bin/env bash
#
# Open every UI in the cluster at once, and print the credentials for each.
#
#   ./scripts/port-forward-all.sh
#
# Ctrl-C stops all of them.
#
# ─────────────────────────────────────────────────────────────────────────────
# Why port-forward and not an Ingress
# ─────────────────────────────────────────────────────────────────────────────
#
# Every one of these is either cluster-admin-equivalent (ArgoCD) or an unauthenticated
# read of everything the cluster knows (Prometheus, Alertmanager, Alloy). None of
# them belongs on the public internet without SSO in front, and a demo is exactly
# where that shortcut gets taken and then forgotten.
#
# port-forward is also honest about what it is: a tunnel that exists while you are
# looking, authenticated by the same kubeconfig that authorises everything else,
# and gone when you close the terminal.

set -euo pipefail

GREEN=$'\033[0;32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RED=$'\033[0;31m'; RESET=$'\033[0m'

PIDS=()

cleanup() {
    printf '\n%sหยุด port-forward ทั้งหมด...%s\n' "$DIM" "$RESET"
    for pid in "${PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

die() { printf '%sERROR%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl reaches no cluster. Run: gcloud container clusters get-credentials ..."

# forward <name> <namespace> <service> <local:remote>
forward() {
    local name="$1" ns="$2" svc="$3" ports="$4"
    if ! kubectl -n "$ns" get "svc/$svc" >/dev/null 2>&1; then
        printf '  %sSKIP%s  %-14s svc/%s ไม่มีใน namespace %s\n' "$RED" "$RESET" "$name" "$svc" "$ns"
        return
    fi
    kubectl -n "$ns" port-forward "svc/$svc" "$ports" >/dev/null 2>&1 &
    PIDS+=("$!")
    printf '  %s✓%s  %-14s http://localhost:%s\n' "$GREEN" "$RESET" "$name" "${ports%%:*}"
}

printf '\n%sเปิด UI ทั้งหมด%s\n\n' "$BOLD" "$RESET"

forward "ArgoCD"       argocd        argocd-server                      8080:443
forward "Grafana"      observability kube-prometheus-stack-grafana      3000:80
forward "Prometheus"   observability kube-prometheus-stack-prometheus   9090:9090
forward "Alertmanager" observability kube-prometheus-stack-alertmanager 9093:9093
forward "Alloy"        observability alloy                              12345:12345

printf '\n%sรหัสผ่าน%s\n\n' "$BOLD" "$RESET"

# ArgoCD writes a one-time admin password into a Secret at install time. It is
# meant to be rotated and the Secret deleted; on a disposable demo cluster that
# ceremony buys nothing, so it is simply read out here.
if argocd_pw="$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"; then
    printf '  ArgoCD    admin / %s\n' "$argocd_pw"
else
    printf '  ArgoCD    %s(อ่าน secret ไม่ได้ — อาจถูกลบหลัง rotate แล้ว)%s\n' "$DIM" "$RESET"
fi

# Created by scripts/bootstrap-cluster.sh, not by the chart, so that the password
# never sits in Git.
if grafana_pw="$(kubectl -n observability get secret grafana-admin \
        -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)"; then
    printf '  Grafana   admin / %s\n' "$grafana_pw"
else
    printf '  Grafana   %s(ไม่พบ secret grafana-admin)%s\n' "$DIM" "$RESET"
fi

cat <<'GUIDE'

────────────────────────────────────────────────────────────────────────
สิ่งที่ควรดู

  ArgoCD  https://localhost:8080   (เบราว์เซอร์จะเตือน cert — กด proceed)
     ผังต้นไม้ Application 6 ตัว กด app แล้วดูหน้า DIFF: ซ้ายคือ Git
     ขวาคือคลัสเตอร์ นี่คือหน้าที่อธิบาย GitOps ได้ดีที่สุด

  Grafana  http://localhost:3000
     Dashboards → 3 ตัว (app-red, cluster-health, logs-traces)
     ในกราฟ latency ของ app-red มองหาจุดเล็ก ๆ ใต้เส้น = exemplar
     คลิกจุดนั้น → เด้งเข้า trace ใน Tempo → กด "Logs for this span"
     → ได้ log บรรทัดจริงจาก Loki ที่มี trace_id เดียวกัน

  Prometheus  http://localhost:9090
     Status → Targets  ควรเห็น job go-sample-app เป็น UP 2 ตัว

  Alloy  http://localhost:12345
     กราฟ component ของ log pipeline ต่อกันเป็นเส้น
     discovery.kubernetes → relabel → file → process → loki.write
     ถ้าเส้นไหนไม่ต่อหรือไม่เขียว แปลว่า log ไม่ไหล — หน้านี้ทำให้
     บั๊ก glob ที่ใช้เวลาไล่หลายขั้นเห็นได้ในไม่กี่วินาที

Ctrl-C เพื่อปิดทั้งหมด
────────────────────────────────────────────────────────────────────────
GUIDE

wait
