# linux-runner-box

Turns a Debian 13 machine (bare metal, VM, or VPS; x86_64 or arm64) into an always-on host for several GitHub Actions self-hosted runners. The setup script installs a common build toolchain and Docker, registers the runners as systemd services, and installs a watchdog that polls GitHub every two minutes with a read-only token and restarts any runner GitHub reports as offline — the state a runner gets stuck in after a network outage, where the process is alive but never reconnects. No `gh` CLI and no account sign-in on the machine; the only credentials it holds are the runners' own registration and a fine-grained PAT that can only list runners.

The runners are persistent, not ephemeral: they favor fast jobs and warm caches over a clean environment per job. Use them for private repositories you trust.

## What gets installed

- Packages: `git`, `git-lfs`, `curl`, `jq`, `tar`, `gzip`, `unzip`, `zip`, `zstd`, `xz-utils`, `build-essential`, `pkg-config`, `python3`, `python3-venv`, `docker.io`, `docker-cli`, `docker-buildx`, plus anything in `EXTRA_APT_PACKAGES`.
- `uv` in `/usr/local/bin` (Debian 13 does not package it).
- Go, Node, and Python toolchains come from `actions/setup-go`, `actions/setup-node`, and `uv` in the workflows. Each runner keeps its own tool cache under `_work/_tool`, so a toolchain downloads once per runner.
- The runner user joins the `docker` group, so jobs can use `container:` and `services:`.

To add a tool, add its package to `EXTRA_APT_PACKAGES` and rerun the script.

## Caches

All runners run as one user and share one `$HOME`, so the Go build and module caches, the npm cache, and the uv cache are shared. Each tool locks its own cache, so concurrent jobs are safe.

The script also creates `CACHE_DIR` (default `/var/cache/github-runners`), owned by the runner user, and exports it to every job as `RUNNER_SHARED_CACHE` through each runner's `.env`. Workflows can keep their own entries there (for example, prebuilt `node_modules` keyed by lockfile). A workflow owns its entries and their pruning; the box never deletes anything there.

Container jobs run as root, so files they write into the workspace or a bind-mounted cache are root-owned. A job that uses `container:` must chown those files back to the runner user before it ends, or the next job on that runner fails at checkout.

Nothing trims `~/go/pkg/mod`, `~/.npm`, or `~/.cache/uv`. Clear them by hand when disk space matters.

## Setup

1. Install Debian 13 with a normal user that has sudo, and enable SSH. For a VM, enable autostart in the hypervisor.
2. Clone this repo onto the machine and edit the variables at the top of `setup-runner-linux.sh` (`RUNNER_URL`, `SCOPE`, `RUNNER_COUNT`, `RUNNER_PREFIX`, `LABELS`, `CACHE_DIR`, `EXTRA_APT_PACKAGES`).
3. From another machine, create a fine-grained PAT with only **Self-hosted runners: Read-only** (org runners) or **Administration: Read-only** (repo runners).
4. From another machine, get a runner registration token from *Settings → Actions → Runners → New self-hosted runner*. It is valid for one hour and registers all runners.
5. On the machine, run `./setup-runner-linux.sh` as the normal user and paste the two tokens when prompted (or pass `REG_TOKEN=... WATCHDOG_TOKEN=...`). A rerun keeps registered runners and the stored PAT.
6. Verify with `systemctl list-units 'actions.runner.*'` and `journalctl -t github-runner-watchdog -f`.

If you lower `RUNNER_COUNT` later, remove the extra runners by hand (`sudo ./svc.sh uninstall` and `./config.sh remove` in their directories).
