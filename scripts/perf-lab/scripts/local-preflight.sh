#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-checks.sh"
java_home=$1
native_home=$2
runtimes=$3
profiler=$4
drop_caches=$5
shift 5
[[ $(uname -s) == Linux ]] || { echo '--locally requires Linux CPU affinity and cgroups.' >&2; exit 1; }
for tool in git jbang jq ss taskset timeout curl pidstat flock lscpu; do
  command -v "$tool" >/dev/null || { echo "Missing local prerequisite: $tool (install it before running)." >&2; exit 1; }
done
[[ -x /usr/bin/time && -x "$java_home/bin/java" && -x "$java_home/bin/javac" ]] || { echo 'Install /usr/bin/time and provide a valid --java-home.' >&2; exit 1; }
if [[ "$runtimes" == *native* ]]; then
  [[ -x "$native_home/bin/native-image" ]] || { echo 'Native runtimes require --graalvm-home with bin/native-image.' >&2; exit 1; }
  command -v gcc >/dev/null || { echo 'Native runtimes require gcc and zlib development headers.' >&2; exit 1; }
  printf '#include <zlib.h>\n' | gcc -x c -fsyntax-only - || { echo 'Install zlib development headers for native builds.' >&2; exit 1; }
fi
if [[ "$profiler" == jfr || "$profiler" == flamegraph ]]; then
  [[ $(cat /proc/sys/kernel/perf_event_paranoid) -le 1 && $(cat /proc/sys/kernel/kptr_restrict) == 0 ]] || {
    echo 'async-profiler requires perf_event_paranoid <= 1 and kptr_restrict = 0. Configure them explicitly, or use --profiler syncjfr.' >&2; exit 1;
  }
fi
if [[ "$drop_caches" == true ]]; then
  sudo -n true || { echo '--drop-fs-caches requires noninteractive sudo on the local machine.' >&2; exit 1; }
fi
allowed_cpus=$(awk '$1 == "Cpus_allowed_list:" { print $2 }' /proc/self/status)
validate_local_cpus "$allowed_cpus" /sys/devices/system/cpu "$@"
validate_local_ports
if command -v podman >/dev/null; then engine=podman
elif command -v docker >/dev/null; then engine=docker
else echo 'Install Podman or Docker before running.' >&2; exit 1
fi
info=$("$engine" info --format json)
if [[ "$engine" == podman ]]; then
  validate_podman_delegation "$info"
fi
for container in fruits_db otel_lgtm; do
  if "$engine" container exists "$container" 2>/dev/null || "$engine" inspect "$container" >/dev/null 2>&1; then
    echo "Container $container already exists. Stop/remove it explicitly before a local benchmark." >&2
    exit 1
  fi
done
# Exercise the actual container resource settings; controller files alone do not
# establish that the session's complete cgroup hierarchy is usable.
image=ghcr.io/quarkusio/postgres-17-perf@sha256:25547aa2c1a44685066f552e1c262929cf629cbc2f3a82bd18fa791a03f7cd48
for cpus in "$2" "$3"; do
  probe=("$engine" run --rm --network none --cpuset-cpus "$cpus" --memory 2g --entrypoint /bin/true "$image")
  if [[ "$engine" == podman && $(id -u) -ne 0 ]] && command -v systemd-run >/dev/null; then
    probe=(systemd-run --user --scope --quiet -- "${probe[@]}")
  fi
  if ! "${probe[@]}"; then
    echo 'Container CPU/memory enforcement failed. Rootless Podman requires cgroup v2 and delegated cpuset/memory controllers.' >&2
    echo 'See scripts/perf-lab/README.md: Fedora / rootless Podman. No unpinned fallback is used.' >&2
    exit 1
  fi
done
echo 'Local preflight passed: CPUs, prerequisites, ports, containers, and resource enforcement.'
