#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
source "$TEST_DIR/../scripts/local-checks.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
TESTS_RUN=0
TESTS_FAILED=0
check() {
  local description=$1
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@"; then echo "PASS: $description"
  else echo "FAIL: $description"; TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}
expect_status() {
  local expected=$1 actual=0
  shift
  "$@" > "$TEST_TMP/output" 2>&1 || actual=$?
  [[ $actual == "$expected" ]]
}
output_contains() { [[ $(< "$TEST_TMP/output") == *"$1"* ]]; }
output_lacks() { [[ $(< "$TEST_TMP/output") != *"$1"* ]]; }
args_lack() { ! args_contain "$1"; }
args_contain() {
  local arg
  while IFS= read -r arg; do [[ $arg == "$1" ]] && return 0; done < "$TEST_TMP/args"
  return 1
}

# Fixtures exercise real allocation checks, independent of host CPU count/topology.
topology="$TEST_TMP/topology"
for cpu in {0..7}; do
  mkdir -p "$topology/cpu$cpu/topology"
  echo 0 > "$topology/cpu$cpu/topology/physical_package_id"
  echo "$((cpu == 7 ? 0 : cpu))" > "$topology/cpu$cpu/topology/core_id"
done
check 'disjoint CPUs with sequential TTFR/load sharing' expect_status 0 validate_local_cpus 0-7 "$topology" 0 1 2 3 4 3
check 'SMT siblings within one workload allowed' expect_status 0 validate_local_cpus 0-7 "$topology" 0,7 1 2 3 4 3
check 'unavailable CPU rejected' expect_status 1 validate_local_cpus 0-7 "$topology" 8 1 2 3 4 3
check 'unavailable CPU diagnosed' output_contains unavailable
check 'overlapping workload CPUs rejected' expect_status 1 validate_local_cpus 0-7 "$topology" 0 0 2 3 4 3
check 'SMT siblings across workloads rejected' expect_status 1 validate_local_cpus 0-7 "$topology" 0 7 2 3 4 3
check 'SMT conflict diagnosed' output_contains 'share physical cores'
check 'TTFR cannot share application cores' expect_status 1 validate_local_cpus 0-7 "$topology" 0 1 2 3 4 0

# Stub only external commands; run the real entrypoint from another directory.
checkout="$TEST_TMP/checkout"
lab="$checkout/scripts/perf-lab"
mock_bin="$TEST_TMP/bin"
mkdir -p "$lab/scripts" "$mock_bin" "$TEST_TMP/home"
cp "$TEST_DIR/../run-benchmarks.sh" "$lab/run-benchmarks.sh"
cat > "$lab/scripts/local-preflight.sh" <<'STUB'
#!/usr/bin/env bash
echo preflight >&2
STUB
cat > "$mock_bin/jbang" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == --version ]]; then echo test; exit; fi
printf '%s\n' "$@" > "$CAPTURE"
pwd > "$CAPTURE.cwd"
STUB
chmod +x "$lab/scripts/local-preflight.sh" "$mock_bin/jbang"
runner=(env "PATH=$mock_bin:$PATH" "HOME=$TEST_TMP/home" "CAPTURE=$TEST_TMP/args" bash "$lab/run-benchmarks.sh" --output-dir "$TEST_TMP/results" --runtimes quarkus3-jvm --iterations 1)
cd "$TEST_TMP"
check 'lab dispatch from another directory' expect_status 0 "${runner[@]}" --cpus-db 4-8:2
check 'lab YAML selected' args_contain ./main.yml
check 'shared measurements loaded' args_contain ./benchmarks.yml
check 'lab exit behavior preserved' args_contain -ix
check 'step ranges normalized for container pinning' args_contain config.resources.cpu.db=4,6,8
check 'runner resolves its own directory' test "$(< "$TEST_TMP/args.cwd")" = "$lab"

mkdir -p "$TEST_TMP/home/spring-quarkus-perf-comparison/.git"
echo keep-me > "$TEST_TMP/home/spring-quarkus-perf-comparison/pom.xml"
check 'lab refuses existing checkout' expect_status 1 "${runner[@]}"
check 'lab checkout preserved' test "$(< "$TEST_TMP/home/spring-quarkus-perf-comparison/pom.xml")" = keep-me
rm -rf "$TEST_TMP/home/spring-quarkus-perf-comparison"
echo keep-me > "$checkout/pom.xml"
check 'local workflow executes' expect_status 0 "${runner[@]}" --locally
check 'local YAML selected' args_contain ./main-local.yml
check 'local checkout forwarded' args_contain "config.local.checkout=$checkout"
check 'local checkout preserved' test "$(< "$checkout/pom.xml")" = keep-me
check 'local does not ignore exit codes' args_lack -ix
workspaces=("$TEST_TMP"/results/perf-local.*)
check 'local output is isolated' args_contain "${workspaces[0]}/qdup"
rm "$TEST_TMP/args"
check 'noninteractive POM edits abort' expect_status 1 "${runner[@]}" --locally --quarkus-version 3.30.5
check 'confirmation required' output_contains 'interactive confirmation'
check 'unapproved edits prevent execution' test ! -e "$TEST_TMP/args"

# util-linux script supplies a terminal, so the actual interactive prompt is tested.
if command -v script >/dev/null; then
  printf -v terminal_command '%q ' "${runner[@]}" --locally --quarkus-version 3.30.5
  terminal_status=0
  printf 'n\n' | script -qec "$terminal_command" /dev/null > "$TEST_TMP/output" 2>&1 || terminal_status=$?
  check 'declining POM edits aborts' test "$terminal_status" = 1
  check 'declining prevents execution' test ! -e "$TEST_TMP/args"
  terminal_status=0
  printf 'y\n' | script -qec "$terminal_command" /dev/null > "$TEST_TMP/output" 2>&1 || terminal_status=$?
  check 'approving POM edits continues' test "$terminal_status" = 0
  check 'approved overrides forwarded' args_contain config.quarkus.version=3.30.5
fi
rm -f "$TEST_TMP/args"
check 'zero iterations rejected' expect_status 1 "${runner[@]}" --iterations 0
check 'partial runtime name rejected' expect_status 1 "${runner[@]}" --runtimes quarkus3
check 'invalid CPU step rejected' expect_status 1 "${runner[@]}" --cpus-db 4-6:0
check 'empty CPU element rejected' expect_status 1 "${runner[@]}" --cpus-db 4,,6
check 'missing argument rejected' expect_status 1 "${runner[@]}" --cpus-db
check 'remote local workflow rejected' expect_status 1 "${runner[@]}" --locally --host remote
cat > "$lab/scripts/local-preflight.sh" <<'STUB'
#!/usr/bin/env bash
echo missing-cpuset >&2
exit 1
STUB
check 'preflight failure aborts run' expect_status 1 "${runner[@]}" --locally --quarkus-version 3.30.5
check 'preflight error preserved' output_contains missing-cpuset
check 'preflight failure prevents execution' test ! -e "$TEST_TMP/args"

# Startup failure must retain the original status without entering readiness waits.
cat > "$mock_bin/podman" <<'STUB'
#!/usr/bin/env bash
echo original-container-error >&2
exit 23
STUB
cat > "$mock_bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
while [[ $1 != -- ]]; do shift; done
shift
exec "$@"
STUB
cat > "$mock_bin/timeout" <<'STUB'
#!/usr/bin/env bash
echo unexpected-readiness-wait >&2
exit 99
STUB
chmod +x "$mock_bin/podman" "$mock_bin/systemd-run" "$mock_bin/timeout"
check 'container failure preserves exit status' expect_status 23 env "PATH=$mock_bin:$PATH" bash "$REPO_ROOT/scripts/infra.sh" -s -p 4,6
check 'container error preserved' output_contains original-container-error
check 'container failure avoids readiness wait' output_lacks unexpected-readiness-wait

# ss fixtures cover occupied IPv4/IPv6 listeners without binding host ports.
cat > "$mock_bin/ss" <<'STUB'
#!/usr/bin/env bash
[[ $* != *5432* ]] || echo 'LISTEN 0 4096 [::]:5432 [::]:*'
exit 0
STUB
chmod +x "$mock_bin/ss"
PATH="$mock_bin:$PATH"
check 'occupied listener rejected' expect_status 1 validate_local_ports
check 'occupied port diagnosed' output_contains 'Port 5432 is unavailable'
cat > "$mock_bin/ss" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
check 'free ports accepted' expect_status 0 validate_local_ports

check 'missing Podman cpuset delegation rejected' expect_status 1 validate_podman_delegation '{"host":{"security":{"rootless":true},"cgroupVersion":"v2","cgroupControllers":["cpu","memory","pids"]}}'
check 'delegation failure diagnosed' output_contains 'cpuset/memory delegation'
check 'delegated Podman accepted' expect_status 0 validate_podman_delegation '{"host":{"security":{"rootless":true},"cgroupVersion":"v2","cgroupControllers":["cpuset","memory","pids"]}}'
check 'rootless cgroup v1 rejected' expect_status 1 validate_podman_delegation '{"host":{"security":{"rootless":true},"cgroupVersion":"v1","cgroupControllers":["cpuset","memory"]}}'

echo "$TESTS_RUN checks run, $TESTS_FAILED failed."
[[ $TESTS_FAILED == 0 ]]
