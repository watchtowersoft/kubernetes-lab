#!/bin/bash
set -e

# Usage: ./graceful_shutdown.sh           (apply — safe to re-run)
#        ./graceful_shutdown.sh --check   (report drift only, exit 1 if any)
#
# Makes a node terminate its pods cleanly on reboot instead of leaving them
# behind, which matters most on a single-node cluster where nothing else can
# take the workload over.
#
# Run it on every node. On a control plane node it also writes the settings
# into the kubelet-config and kubeadm-config ConfigMaps in kube-system. Those
# are what kubeadm regenerates /var/lib/kubelet/config.yaml and the static pod
# manifests from, so without them the next `kubeadm upgrade` silently undoes
# the node-local edits.

# Total time the kubelet may delay a shutdown, and the slice of it reserved
# for critical pods (so regular pods get the difference).
SHUTDOWN_GRACE_SECONDS=120
SHUTDOWN_GRACE_CRITICAL_SECONDS=30
# Shutdown leaves pods behind in a terminated state; have the controller
# manager garbage-collect them almost immediately instead of at the 12500 default.
TERMINATED_POD_GC_THRESHOLD=1

KUBELET_CONFIG=/var/lib/kubelet/config.yaml
KCM_MANIFEST=/etc/kubernetes/manifests/kube-controller-manager.yaml
# Must keep this exact filename. The unattended-upgrades package ships a drop-in
# of the same name under /usr/lib/systemd/logind.conf.d forcing 30s, and drop-ins
# are merged in filename order across both directories — it sorts after the
# kubelet's own 99-kubelet.conf and wins. A same-named file in /etc masks it.
LOGIND_DROPIN=/etc/systemd/logind.conf.d/unattended-upgrades-logind-maxdelay.conf
HELD_PACKAGES="kubelet kubeadm kubectl containerd"
APT_TIMERS="apt-daily.timer apt-daily-upgrade.timer"

case "${1:-}" in
  "") MODE="apply" ;;
  --check) MODE="check" ;;
  *) echo "Usage: $0 [--check]"; exit 1 ;;
esac

# Detect node role by presence of static pod manifests
if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
  NODE_ROLE="controlplane"
else
  NODE_ROLE="worker"
fi

KUBECTL="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf"
DRIFT=0
RESTART_LOGIND=0
RESTART_KUBELET=0

ok()    { echo "  ok     $*"; }
fixed() { echo "  fixed  $*"; }
drift() { echo "  DRIFT  $*"; DRIFT=1; }

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "Error: python3 with PyYAML is required: sudo apt-get install -y python3-yaml"
  exit 1
fi

# Edits a YAML document read from stdin. Prints the new document and exits 0
# when something had to change, exits 3 when it already matched.
read -r -d '' YAML_EDIT_PY <<'PY' || true
import copy, re, sys, yaml

mode, args = sys.argv[1], sys.argv[2:]
doc = yaml.safe_load(sys.stdin)
if not isinstance(doc, dict):
    sys.exit("expected a YAML mapping on stdin")
before = copy.deepcopy(doc)

def seconds(duration):
    m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?", str(duration or ""))
    if not duration or not m:
        return None
    return sum(int(v or 0) * f for v, f in zip(m.groups(), (3600, 60, 1)))

# kubeadm re-serialises durations the way Go prints them (120s becomes 2m0s),
# so write that form and compare by value rather than by string.
def go_duration(total):
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return (f"{h}h" if h else "") + (f"{m}m" if h or m else "") + f"{s}s"

if mode == "kubelet":
    for key, want in zip(("shutdownGracePeriod", "shutdownGracePeriodCriticalPods"), args):
        if seconds(doc.get(key)) != int(want):
            doc[key] = go_duration(int(want))
elif mode == "cluster":
    name, value = args
    component = doc.get("controllerManager") or {}
    # extraArgs is a map in v1beta3 and a list of name/value pairs from v1beta4
    if str(doc.get("apiVersion", "")).endswith("/v1beta3"):
        extra = component.get("extraArgs") or {}
        extra[name] = value
    else:
        extra = component.get("extraArgs") or []
        for arg in extra:
            if arg.get("name") == name:
                arg["value"] = value
                break
        else:
            extra.append({"name": name, "value": value})
    component["extraArgs"] = extra
    doc["controllerManager"] = component
else:
    sys.exit(f"unknown mode: {mode}")

if doc == before:
    sys.exit(3)
yaml.safe_dump(doc, sys.stdout, default_flow_style=False, sort_keys=False)
PY
yaml_edit() { python3 -c "$YAML_EDIT_PY" "$@"; }

# --- Host: nothing may upgrade or restart the runtime behind the cluster's back

ensure_packages() {
  local pkg timer
  if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "install ok installed"; then
    if [[ "$MODE" == "check" ]]; then
      drift "unattended-upgrades is installed"
    else
      sudo apt-get purge -y unattended-upgrades
      fixed "purged unattended-upgrades"
    fi
  else
    ok "unattended-upgrades not installed"
  fi

  for timer in $APT_TIMERS; do
    if systemctl is-enabled --quiet "$timer" 2>/dev/null || systemctl is-active --quiet "$timer"; then
      if [[ "$MODE" == "check" ]]; then
        drift "$timer is enabled"
      else
        sudo systemctl disable --now "$timer"
        fixed "disabled $timer"
      fi
    else
      ok "$timer disabled"
    fi
  done

  for pkg in $HELD_PACKAGES; do
    if apt-mark showhold | grep -qx "$pkg"; then
      ok "$pkg held"
    elif [[ "$MODE" == "check" ]]; then
      drift "$pkg is not held"
    else
      sudo apt-mark hold "$pkg" >/dev/null
      fixed "held $pkg"
    fi
  done
}

# --- Host: logind must allow the kubelet to delay shutdown for the full grace period

logind_delay_seconds() {
  local usec
  usec=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager InhibitDelayMaxUSec 2>/dev/null | awk '{print $2}')
  echo $(( ${usec:-0} / 1000000 ))
}

ensure_logind() {
  local content
  content="# Managed by kubernetes-lab bare-metal-ubuntu/graceful_shutdown.sh
# Lets the kubelet hold shutdown for its full shutdownGracePeriod. The filename
# is deliberate: it masks the 30s drop-in of the same name that the
# unattended-upgrades package ships in /usr/lib/systemd/logind.conf.d, which
# would otherwise sort after the kubelet's 99-kubelet.conf and override it.
[Login]
InhibitDelayMaxSec=${SHUTDOWN_GRACE_SECONDS}"

  if [[ -f "$LOGIND_DROPIN" ]] && [[ "$(cat "$LOGIND_DROPIN")" == "$content" ]]; then
    ok "logind drop-in sets InhibitDelayMaxSec=${SHUTDOWN_GRACE_SECONDS}"
  elif [[ "$MODE" == "check" ]]; then
    drift "$LOGIND_DROPIN is missing or differs"
  else
    sudo mkdir -p "$(dirname "$LOGIND_DROPIN")"
    echo "$content" | sudo tee "$LOGIND_DROPIN" >/dev/null
    RESTART_LOGIND=1
    fixed "wrote $LOGIND_DROPIN"
  fi

  if [[ "$MODE" == "apply" ]] && (( $(logind_delay_seconds) < SHUTDOWN_GRACE_SECONDS )); then
    RESTART_LOGIND=1
  fi
}

# --- Node: the kubelet's own config

ensure_kubelet_config() {
  local new rc=0
  if ! sudo test -f "$KUBELET_CONFIG"; then
    echo "  skip   $KUBELET_CONFIG not found — node has not joined yet; it gets the settings from the kubelet-config ConfigMap on join"
    return
  fi

  new=$(sudo cat "$KUBELET_CONFIG" \
    | yaml_edit kubelet "$SHUTDOWN_GRACE_SECONDS" "$SHUTDOWN_GRACE_CRITICAL_SECONDS") || rc=$?
  case "$rc" in
    3) ok "kubelet config has shutdownGracePeriod ${SHUTDOWN_GRACE_SECONDS}s / critical ${SHUTDOWN_GRACE_CRITICAL_SECONDS}s" ;;
    0)
      if [[ "$MODE" == "check" ]]; then
        drift "$KUBELET_CONFIG is missing the shutdown grace periods"
      else
        sudo cp -p "$KUBELET_CONFIG" "${KUBELET_CONFIG}.bak"
        echo "$new" | sudo tee "$KUBELET_CONFIG" >/dev/null
        RESTART_KUBELET=1
        fixed "set shutdown grace periods in $KUBELET_CONFIG (previous copy at ${KUBELET_CONFIG}.bak)"
      fi
      ;;
    *) echo "Error: could not parse $KUBELET_CONFIG"; exit 1 ;;
  esac
}

# --- Control plane: the ConfigMaps kubeadm regenerates everything from

# ensure_configmap <configmap> <data key> <yaml_edit args...>
ensure_configmap() {
  local name="$1" key="$2" current new patch rc=0
  shift 2

  current=$($KUBECTL -n kube-system get configmap "$name" -o jsonpath="{.data.${key}}")
  new=$(echo "$current" | yaml_edit "$@") || rc=$?
  case "$rc" in
    3) ok "ConfigMap $name is up to date" ;;
    0)
      if [[ "$MODE" == "check" ]]; then
        drift "ConfigMap $name is missing the settings — the next kubeadm upgrade would drop them"
      else
        patch=$(echo "$new" | python3 -c \
          'import json, sys; print(json.dumps({"data": {sys.argv[1]: sys.stdin.read()}}))' "$key")
        $KUBECTL -n kube-system patch configmap "$name" --type merge -p "$patch" >/dev/null
        fixed "updated ConfigMap $name"
      fi
      ;;
    *) echo "Error: could not parse .data.${key} of ConfigMap $name"; exit 1 ;;
  esac
}

ensure_controller_manager_manifest() {
  local flag="--terminated-pod-gc-threshold"
  if sudo grep -q -- "- ${flag}=${TERMINATED_POD_GC_THRESHOLD}\$" "$KCM_MANIFEST"; then
    ok "kube-controller-manager runs with ${flag}=${TERMINATED_POD_GC_THRESHOLD}"
    return
  fi
  if [[ "$MODE" == "check" ]]; then
    drift "$KCM_MANIFEST is missing ${flag}=${TERMINATED_POD_GC_THRESHOLD}"
    return
  fi

  # No backup copy here: the kubelet would run a second file in this
  # directory as another static pod.
  if sudo grep -q -- "- ${flag}=" "$KCM_MANIFEST"; then
    sudo sed -i -E "s/(- ${flag}=).*/\1${TERMINATED_POD_GC_THRESHOLD}/" "$KCM_MANIFEST"
  else
    sudo sed -i -E "s/^(\s*)- kube-controller-manager\$/&\n\1- ${flag}=${TERMINATED_POD_GC_THRESHOLD}/" "$KCM_MANIFEST"
  fi
  if ! sudo grep -q -- "- ${flag}=${TERMINATED_POD_GC_THRESHOLD}\$" "$KCM_MANIFEST"; then
    echo "Error: could not add ${flag} to $KCM_MANIFEST"
    exit 1
  fi
  fixed "added ${flag}=${TERMINATED_POD_GC_THRESHOLD} to $KCM_MANIFEST (the kubelet restarts the pod)"
}

# --- Live state: what actually decides whether the next reboot is graceful

check_runtime() {
  local delay
  delay=$(logind_delay_seconds)
  if (( delay >= SHUTDOWN_GRACE_SECONDS )); then
    ok "logind InhibitDelayMaxSec is ${delay}s"
  else
    drift "logind InhibitDelayMaxSec is ${delay}s, expected ${SHUTDOWN_GRACE_SECONDS}s — check for another drop-in: systemd-analyze cat-config systemd/logind.conf"
  fi

  sudo test -f "$KUBELET_CONFIG" || return 0
  # The kubelet takes its lock a few seconds after starting
  for _ in $(seq 1 15); do
    if systemd-inhibit --list --no-legend | grep -q kubelet; then
      ok "kubelet holds a shutdown inhibitor lock"
      return 0
    fi
    [[ "$MODE" == "check" ]] && break
    sleep 2
  done
  drift "kubelet holds no shutdown inhibitor lock — pods will not be terminated gracefully on reboot"
}

echo "=== Graceful shutdown (${MODE}) — node role: ${NODE_ROLE} ==="

echo "Host packages:"
ensure_packages

echo "logind:"
ensure_logind

echo "kubelet:"
ensure_kubelet_config

if [[ "$NODE_ROLE" == "controlplane" ]]; then
  echo "Cluster configuration:"
  ensure_configmap kubelet-config kubelet \
    kubelet "$SHUTDOWN_GRACE_SECONDS" "$SHUTDOWN_GRACE_CRITICAL_SECONDS"
  ensure_configmap kubeadm-config ClusterConfiguration \
    cluster terminated-pod-gc-threshold "$TERMINATED_POD_GC_THRESHOLD"
  ensure_controller_manager_manifest
fi

# Restarting logind drops the kubelet's inhibitor lock, so the kubelet has to
# be restarted after it to take a new one.
if (( RESTART_LOGIND )); then
  sudo systemctl restart systemd-logind
  RESTART_KUBELET=1
  fixed "restarted systemd-logind"
fi
if (( RESTART_KUBELET )) && sudo test -f "$KUBELET_CONFIG"; then
  sudo systemctl restart kubelet
  fixed "restarted kubelet"
fi

echo "Live state:"
check_runtime

echo ""
if (( DRIFT )); then
  if [[ "$MODE" == "check" ]]; then
    echo "Drift found — run $0 to fix it. Do not reboot this node until it is clean."
  else
    echo "Settings were applied but the live state is still wrong — see DRIFT lines above."
  fi
  exit 1
fi
echo "Node is set up for graceful shutdown."
