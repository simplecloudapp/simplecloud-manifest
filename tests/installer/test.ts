#!/usr/bin/env bun

import { resolve } from "node:path";

type Distro = {
  id: string;
  image: string;
  packageManager: "apt" | "dnf" | "yum" | "pacman";
  default: boolean;
  platform?: string;
  disablePacmanDownloadUser?: boolean;
};

const distros: Distro[] = [
  {
    id: "ubuntu",
    image: "ubuntu:24.04",
    packageManager: "apt",
    default: true,
  },
  {
    id: "fedora",
    image: "fedora:42",
    packageManager: "dnf",
    default: true,
  },
  {
    id: "amazonlinux",
    image: "amazonlinux:2",
    packageManager: "yum",
    default: false,
  },
  {
    id: "arch",
    image: "archlinux:base",
    packageManager: "pacman",
    default: false,
    platform: "linux/amd64",
    disablePacmanDownloadUser: true,
  },
];

const args = Bun.argv.slice(2);
const reinstall = args.includes("--reinstall");
const positionalArgs = args.filter((arg) => !arg.startsWith("--"));

function printUsage(): void {
  console.log(`Usage: bun tests/installer/test.ts [options] [distro...]

Run the SimpleCloud installer in disposable Docker containers.

Options:
  --all          Test every supported package-manager family
  --reinstall    Run the installer twice in each container
  --list         List available distro IDs
  --help         Show this help

Environment:
  INSTALL_TEST_TIMEOUT_SECONDS  Per-container timeout (default: 600)

Examples:
  bun tests/installer/test.ts
  bun tests/installer/test.ts ubuntu
  bun tests/installer/test.ts --all
  bun tests/installer/test.ts --reinstall ubuntu`);
}

if (args.includes("--help")) {
  printUsage();
  process.exit(0);
}

if (args.includes("--list")) {
  for (const distro of distros) {
    console.log(
      `${distro.id.padEnd(12)} ${distro.image.padEnd(20)} ${distro.packageManager}${distro.default ? " (default)" : ""}`,
    );
  }
  process.exit(0);
}

const supportedOptions = new Set(["--all", "--reinstall", "--list", "--help"]);
const unknownOption = args.find(
  (arg) => arg.startsWith("--") && !supportedOptions.has(arg),
);
if (unknownOption) {
  console.error(`Unknown option: ${unknownOption}\n`);
  printUsage();
  process.exit(2);
}

const requestedIds = args.includes("--all")
  ? distros.map((distro) => distro.id)
  : positionalArgs.length > 0
    ? positionalArgs
    : distros.filter((distro) => distro.default).map((distro) => distro.id);

const unknownId = requestedIds.find(
  (id) => !distros.some((distro) => distro.id === id),
);
if (unknownId) {
  console.error(`Unknown distro: ${unknownId}`);
  console.error(`Available distros: ${distros.map((distro) => distro.id).join(", ")}`);
  process.exit(2);
}

const selectedDistros = requestedIds.map(
  (id) => distros.find((distro) => distro.id === id)!,
);
const installerPath = resolve(import.meta.dir, "../../install.sh");
const timeoutSeconds = Number(
  Bun.env.INSTALL_TEST_TIMEOUT_SECONDS ?? "600",
);

if (
  !Number.isInteger(timeoutSeconds) ||
  timeoutSeconds < 1 ||
  timeoutSeconds > 3600
) {
  console.error(
    "INSTALL_TEST_TIMEOUT_SECONDS must be an integer between 1 and 3600.",
  );
  process.exit(2);
}

if (!(await Bun.file(installerPath).exists())) {
  console.error(`Installer not found: ${installerPath}`);
  process.exit(2);
}

const dockerVersion = Bun.spawnSync(
  ["docker", "version", "--format", "{{.Server.Version}}"],
  {
    stdout: "pipe",
    stderr: "pipe",
  },
);
if (dockerVersion.exitCode !== 0) {
  console.error("Docker is not available or its daemon is not running.");
  console.error(dockerVersion.stderr.toString().trim());
  process.exit(2);
}

const containerScript = String.raw`
set -euo pipefail

if [ "$DISABLE_PACMAN_DOWNLOAD_USER" = "true" ]; then
  # pacman 7's download-user sandbox is incompatible with amd64 emulation.
  sed -i '/^DownloadUser[[:space:]]*=/d' /etc/pacman.conf
fi

detected_package_manager="$(
  bash -c 'source /installer/install.sh; detect_package_manager'
)"
if [ "$detected_package_manager" != "$EXPECTED_PACKAGE_MANAGER" ]; then
  echo "Expected package manager $EXPECTED_PACKAGE_MANAGER, detected $detected_package_manager." >&2
  exit 1
fi

missing_before=""
for command_name in curl unzip; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    if [ -n "$missing_before" ]; then
      missing_before="$missing_before,"
    fi
    missing_before="$missing_before$command_name"
  fi
done

bash /installer/install.sh

if [ "$TEST_REINSTALL" = "true" ]; then
  bash /installer/install.sh
fi

for command_name in curl unzip simplecloud sc; do
  command -v "$command_name" >/dev/null
done

test -x /root/.bun/bin/bun
test -x /root/.bun/bin/simplecloud
test -L /root/.local/bin/simplecloud
test -L /root/.local/bin/sc
test -L /usr/local/bin/simplecloud
test -L /usr/local/bin/sc

bun_version="$(/root/.bun/bin/bun --version)"
cli_version="$(/root/.bun/bin/simplecloud --version)"

test -n "$bun_version"
test -n "$cli_version"

if [ -z "$missing_before" ]; then
  missing_before="none"
fi

printf 'TEST_RESULT manager=%s missing_before=%s bun=%s cli=%s reinstall=%s\n' \
  "$detected_package_manager" "$missing_before" "$bun_version" "$cli_version" "$TEST_REINSTALL"
`;

let activeContainer: string | undefined;

function removeActiveContainer(): void {
  if (!activeContainer) {
    return;
  }

  Bun.spawnSync(["docker", "rm", "--force", activeContainer], {
    stdout: "ignore",
    stderr: "ignore",
  });
  activeContainer = undefined;
}

process.on("SIGINT", () => {
  removeActiveContainer();
  process.exit(130);
});

process.on("SIGTERM", () => {
  removeActiveContainer();
  process.exit(143);
});

const failures: string[] = [];
const startedAt = performance.now();

console.log(
  `Docker ${dockerVersion.stdout.toString().trim()} · ${selectedDistros.length} test(s) · ${timeoutSeconds}s timeout`,
);

for (const [index, distro] of selectedDistros.entries()) {
  const testStartedAt = performance.now();
  activeContainer = `simplecloud-install-test-${distro.id}-${process.pid}`;

  console.log(
    `\n[${index + 1}/${selectedDistros.length}] ${distro.id}: ${distro.image} (${distro.packageManager})`,
  );

  const processHandle = Bun.spawn(
    [
      "docker",
      "run",
      ...(distro.platform ? ["--platform", distro.platform] : []),
      "--rm",
      "--name",
      activeContainer,
      "--env",
      `EXPECTED_PACKAGE_MANAGER=${distro.packageManager}`,
      "--env",
      `TEST_REINSTALL=${reinstall}`,
      "--env",
      `DISABLE_PACMAN_DOWNLOAD_USER=${distro.disablePacmanDownloadUser ?? false}`,
      "--volume",
      `${installerPath}:/installer/install.sh:ro`,
      distro.image,
      "bash",
      "-lc",
      containerScript,
    ],
    {
      stdout: "inherit",
      stderr: "inherit",
    },
  );

  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    processHandle.kill();
    removeActiveContainer();
  }, timeoutSeconds * 1_000);

  const exitCode = await processHandle.exited;
  clearTimeout(timeout);
  activeContainer = undefined;

  const elapsedSeconds = ((performance.now() - testStartedAt) / 1_000).toFixed(
    1,
  );

  if (exitCode === 0 && !timedOut) {
    console.log(`PASS ${distro.id} (${elapsedSeconds}s)`);
  } else {
    const reason = timedOut
      ? `timed out after ${timeoutSeconds}s`
      : `exited with code ${exitCode}`;
    console.error(`FAIL ${distro.id}: ${reason} (${elapsedSeconds}s)`);
    failures.push(distro.id);
  }
}

const totalSeconds = ((performance.now() - startedAt) / 1_000).toFixed(1);

if (failures.length > 0) {
  console.error(
    `\n${failures.length}/${selectedDistros.length} test(s) failed in ${totalSeconds}s: ${failures.join(", ")}`,
  );
  process.exit(1);
}

console.log(
  `\nAll ${selectedDistros.length} installer test(s) passed in ${totalSeconds}s.`,
);
