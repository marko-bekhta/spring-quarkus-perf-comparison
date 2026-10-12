#!/usr/bin/env bash
# Shared Bash checks used by local preflight and its tests.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run-benchmarks.sh"

validate_local_cpus() {
  local allowed_list=$1 topology_dir=$2
  shift 2
  local -a names=(application database OTel 'load generator' monitor 'first request')
  local -a cpus=()
  local -A allowed=() cpu_owner=() core_owner=()
  local expanded cpu cpu_list package core key owner index=0
  expanded=$(normalize_cpus "$allowed_list") || return 1
  IFS=',' read -ra cpus <<< "$expanded"
  for cpu in "${cpus[@]}"; do allowed[$cpu]=1; done
  [[ $# -eq 6 ]] || { echo 'Expected six workload CPU lists.' >&2; return 1; }
  for cpu_list in "$@"; do
    expanded=$(normalize_cpus "$cpu_list") || { echo "Invalid CPU list for ${names[$index]}: $cpu_list" >&2; return 1; }
    IFS=',' read -ra cpus <<< "$expanded"
    for cpu in "${cpus[@]}"; do
      [[ -n ${allowed[$cpu]:-} ]] || { echo "${names[$index]} CPU $cpu unavailable. Allowed CPUs: $allowed_list" >&2; return 1; }
      owner=${cpu_owner[$cpu]:-}
      # TTFR may share the load generator because the tests run sequentially.
      if [[ -n $owner && ! ( $owner == 3 && $index == 5 ) && $owner != "$index" ]]; then
        echo "CPU overlap between ${names[$index]} and ${names[$owner]}; choose disjoint CPUs." >&2
        return 1
      fi
      [[ -r "$topology_dir/cpu$cpu/topology/physical_package_id" && -r "$topology_dir/cpu$cpu/topology/core_id" ]] || {
        echo "Cannot read physical CPU topology for CPU $cpu." >&2; return 1;
      }
      read -r package < "$topology_dir/cpu$cpu/topology/physical_package_id"
      read -r core < "$topology_dir/cpu$cpu/topology/core_id"
      key="$package:$core"
      owner=${core_owner[$key]:-}
      if [[ -n $owner && ! ( $owner == 3 && $index == 5 ) && $owner != "$index" ]]; then
        echo "${names[$index]} and ${names[$owner]} share physical cores (SMT siblings). Choose separate cores." >&2
        return 1
      fi
      cpu_owner[$cpu]=$index
      core_owner[$key]=$index
    done
    index=$((index + 1))
  done
}

validate_local_ports() {
  local port listeners
  for port in 8080 5432 4317 4318 3000 4040 9090; do
    listeners=$(ss -H -ltn "sport = :$port") || return 1
    if [[ -n $listeners ]]; then
      echo "Port $port is unavailable: an existing TCP listener is using it." >&2
      return 1
    fi
  done
}

validate_podman_delegation() {
  local info=$1
  [[ $(jq -r '.host.security.rootless' <<< "$info") == true ]] || return 0
  if [[ $(jq -r '.host.cgroupVersion' <<< "$info") != v2 ]] || ! jq -e '.host.cgroupControllers | index("cpuset") != null and index("memory") != null' <<< "$info" >/dev/null; then
    echo 'Rootless Podman lacks cgroup v2 cpuset/memory delegation. See README.md: Fedora / rootless Podman.' >&2
    echo 'After configuring delegation, run sudo systemctl daemon-reload and retry. No unpinned fallback is used.' >&2
    return 1
  fi
}
