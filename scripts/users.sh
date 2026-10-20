#!/usr/bin/env bash
# Manage participant access to the shared cluster. Each person gets a
# ServiceAccount + revocable token, read-only access cluster-wide, and a
# personal sandbox namespace they can write to (see rbac/ and the README
# section "Give teammates access (RBAC)").
#
# Run this as the cluster admin -- the person who ran setup.sh, whose kubectl
# already points at the cluster.
#
# Usage:
#   users.sh add <name>... [-y]                 create/refresh users, write kubeconfigs/<name>.kubeconfig
#   users.sh add <name> --readonly [-y]         ONE shared read-only file for a whole class (no sandbox)
#   users.sh remove <name>... [-y] [--keep-sandbox]   revoke access (and delete the sandbox, if any)
#   users.sh list                               show users, sandboxes and their quota usage
#
# For 50+ people, don't create one user each: run `add class --readonly` once
# and give everyone the same file (see README "Give teammates access (RBAC)").
#
# Names are lowercase letters, digits and '-' (max 40): they become part of
# Kubernetes object names.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${KUBECONFIG_OUT_DIR:-$REPO_ROOT/kubeconfigs}"
CLUSTER_ALIAS="dev-cluster"

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

for tool in kubectl envsubst base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done

validate_name() {
  if ! [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]]; then
    echo "Invalid name '$1': use lowercase letters, digits and '-' (max 40, start/end with a letter or digit)." >&2
    exit 1
  fi
}

# Everything below acts on whatever cluster kubectl is currently pointed at.
# A stale context (e.g. a torn-down lab, or another AWS account) is the classic
# way to apply RBAC to the wrong place, so show the target and ask first.
CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"

confirm_target() {
  local action="$1"
  if [ -z "$CONTEXT" ] || [ -z "$SERVER" ]; then
    echo "kubectl has no current context. Run:  aws eks update-kubeconfig --name dev-cluster --region us-east-1" >&2
    exit 1
  fi
  echo "Target cluster:"
  echo "  context: ${CONTEXT}"
  echo "  server:  ${SERVER}"
  if [ "$ASSUME_YES" = "true" ]; then return; fi
  local reply=""
  read -r -p "${action} on this cluster? [y/N] " reply || reply=""
  case "$reply" in
    [Yy]*) ;;
    *) echo "Aborted." >&2; exit 1 ;;
  esac
}

require_admin() {
  local ok
  ok="$(kubectl auth can-i create clusterrolebindings 2>/dev/null || true)"
  if [ "$ok" != "yes" ]; then
    echo "This needs cluster-admin (the identity that ran setup.sh), and the cluster must be reachable." >&2
    echo "Check with:  kubectl get nodes" >&2
    exit 1
  fi
}

# Wraps `kubectl auth can-i` against a generated kubeconfig; true when the
# answer matches. Used to prove the permission model end to end after `add`.
expect() {
  local want="$1" file="$2" got
  shift 2
  got="$(kubectl --kubeconfig "$file" auth can-i "$@" 2>/dev/null || true)"
  [ "$got" = "$want" ]
}

write_kubeconfig() {
  local name="$1" ca="$2" token="$3" file="$OUT_DIR/$1.kubeconfig"
  # Default namespace: a personal sandbox, or `default` for the shared read-only identity.
  local ns="sandbox-${name}"
  [ "$READONLY" = "true" ] && ns="default"
  mkdir -p "$OUT_DIR"
  chmod 700 "$OUT_DIR" 2>/dev/null || true
  # The file holds a credential: owner-only from the moment it exists.
  ( umask 077
    cat > "$file" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_ALIAS}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${ca}
users:
  - name: ${name}
    user:
      token: "${token}"
contexts:
  - name: ${CLUSTER_ALIAS}
    context:
      cluster: ${CLUSTER_ALIAS}
      user: ${name}
      namespace: ${ns}
current-context: ${CLUSTER_ALIAS}
EOF
  )
  chmod 600 "$file" 2>/dev/null || true
}

cmd_add() {
  [ "${#NAMES[@]}" -gt 0 ] || { echo "usage: users.sh add <name>... [-y]" >&2; exit 1; }
  for n in "${NAMES[@]}"; do validate_name "$n"; done

  confirm_target "Create ${#NAMES[@]} user(s) (${NAMES[*]})"
  require_admin

  local ca
  ca="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  if [ -z "$ca" ]; then
    echo "The current kubeconfig has no embedded certificate-authority-data, so a portable" >&2
    echo "kubeconfig can't be generated. Re-create yours with:" >&2
    echo "  aws eks update-kubeconfig --name dev-cluster --region us-east-1" >&2
    exit 1
  fi

  kubectl apply -f "$REPO_ROOT/rbac/cluster-access.yaml" >/dev/null

  for name in "${NAMES[@]}"; do
    echo "==> ${name}"
    local tpl="$REPO_ROOT/rbac/user-sandbox.yaml.tpl"
    [ "$READONLY" = "true" ] && tpl="$REPO_ROOT/rbac/user-readonly.yaml.tpl"
    USER_NAME="$name" envsubst '${USER_NAME}' < "$tpl" | kubectl apply -f - >/dev/null

    # The token controller fills the Secret in asynchronously, a moment after it's created.
    local token=""
    for _ in $(seq 1 30); do
      token="$(kubectl -n lab-users get secret "${name}-token" -o jsonpath='{.data.token}' 2>/dev/null \
        | base64 --decode 2>/dev/null || true)"
      [ -n "$token" ] && break
      sleep 1
    done
    if [ -z "$token" ]; then
      echo "    token for ${name} never appeared -- check: kubectl -n lab-users describe secret ${name}-token" >&2
      exit 1
    fi

    write_kubeconfig "$name" "$ca" "$token"
    local f="$OUT_DIR/${name}.kubeconfig"

    if [ "$READONLY" = "true" ]; then
      echo "    wrote ${OUT_DIR}/${name}.kubeconfig  (read-only, no sandbox)"
      if expect yes "$f" list pods --all-namespaces \
        && expect yes "$f" list services --all-namespaces \
        && expect yes "$f" list nodes \
        && expect no  "$f" get secrets -n banking \
        && expect no  "$f" create pods -n default \
        && expect no  "$f" create deployments -n ecommerce; then
        echo "    verified: can read everything except Secrets, cannot create or change anything"
      else
        echo "    WARNING: permission check did not match expectations -- inspect with:" >&2
        echo "      kubectl --kubeconfig ${f} auth can-i --list" >&2
      fi
    else
      echo "    wrote ${OUT_DIR}/${name}.kubeconfig  (sandbox: sandbox-${name})"
      if expect yes "$f" create deployments -n "sandbox-${name}" \
        && expect yes "$f" list pods --all-namespaces \
        && expect no  "$f" get secrets -n banking \
        && expect no  "$f" create deployments -n ecommerce; then
        echo "    verified: can write own sandbox, read all pods, cannot read secrets or change shared apps"
      else
        echo "    WARNING: permission check did not match expectations -- inspect with:" >&2
        echo "      kubectl --kubeconfig ${f} auth can-i --list -n sandbox-${name}" >&2
      fi
    fi
  done

  local rel_out="${OUT_DIR#"$REPO_ROOT"/}"
  if [ "$READONLY" = "true" ]; then
    cat <<EOF

Done. This is ONE shared read-only file: give the same file to everyone in the
class, through your class channel (email, LMS, chat) -- NOT through Git or a
public README. It can read everything except Secrets and can change nothing.
Because it is shared it can't be revoked per person; to cut off access (e.g.
after the class), run:  ./scripts/users.sh remove <name>
EOF
    return
  fi
  cat <<EOF

Done. Send each person ONLY their own file, over a private channel. It contains
their credential: anyone holding it has that person's access, so it must never
go in Git, a README, or a shared chat channel. (${rel_out}/ is gitignored.)
Revoke with:  ./scripts/users.sh remove <name>
EOF
}

cmd_remove() {
  [ "${#NAMES[@]}" -gt 0 ] || { echo "usage: users.sh remove <name>... [-y] [--keep-sandbox]" >&2; exit 1; }
  for n in "${NAMES[@]}"; do validate_name "$n"; done

  local what="Revoke access for ${NAMES[*]}"
  [ "$KEEP_SANDBOX" = "true" ] || what="${what} and DELETE their sandbox namespace(s), if any, and everything in them"
  confirm_target "$what"
  require_admin

  for name in "${NAMES[@]}"; do
    echo "==> ${name}"
    # Deleting the token Secret and the ServiceAccount invalidates the token at once.
    kubectl -n lab-users delete "secret/${name}-token" "serviceaccount/${name}" --ignore-not-found
    if [ "$KEEP_SANDBOX" != "true" ]; then
      kubectl delete namespace "sandbox-${name}" --ignore-not-found --wait=false
    fi
    rm -f "$OUT_DIR/${name}.kubeconfig"
  done
}

cmd_list() {
  echo "Target: ${CONTEXT:-<none>}  ${SERVER}"
  echo ""
  echo "Identities (mode=readonly is a shared class identity; blank = personal user with a sandbox):"
  kubectl -n lab-users get serviceaccounts -l lab/user -L lab/mode
  echo ""
  kubectl get namespaces -l lab/user -L lab/user
  echo ""
  kubectl get resourcequota --all-namespaces -l lab/user
}

CMD="${1:-help}"
shift || true

ASSUME_YES=false
KEEP_SANDBOX=false
READONLY=false
NAMES=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    --keep-sandbox) KEEP_SANDBOX=true ;;
    --readonly) READONLY=true ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) NAMES+=("$arg") ;;
  esac
done

case "$CMD" in
  add) cmd_add ;;
  remove) cmd_remove ;;
  list) cmd_list ;;
  help|-h|--help) usage ;;
  *) echo "Unknown command: $CMD" >&2; usage >&2; exit 1 ;;
esac
