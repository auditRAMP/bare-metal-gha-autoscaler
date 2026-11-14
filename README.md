# Bare-Metal GitHub Actions Auto-Scaler

A lightweight, highly resilient bare-metal daemon that orchestrates ephemeral GitHub Actions runners natively on older, resource-constrained macOS and Linux hardware. 

## Why Build This? (Bare-Metal vs Kubernetes ARC)

While modern CI/CD workloads typically rely on **Kubernetes (K8s)** and the official **Actions Runner Controller (ARC)** for auto-scaling, orchestrating a full Minikube or Helm cluster requires immense underlying compute and memory. 

If you have an older Mac Mini, a spare Linux box, or vintage hardware, running a Kubernetes control plane simply to host runners will enthusiastically suffocate the machine. 

This project was built to bypass Kubernetes entirely. By directly manipulating native shell-scripts and directly communicating with the GitHub Actions REST API, this daemon brings sophisticated, Kubernetes-level auto-scaling to bare-metal systems, allowing you to breathe new life into older hardware with near-zero orchestration overhead.

## Core Capabilities

- **Intelligent API Polling:** The `autoscaler.sh` brain directly talks to `https://api.github.com/rate_limit` and `/actions/runners` to perfectly track the cluster's active capacity natively.
- **Zero-Downtime Hot Reloading:** Control bounds (`MAX_RUNNERS`, etc.) are read natively from a `.properties` file every 15 seconds. You can scale your runner fleet up or down live without interrupting jobs in flight.
- **Dynamic Binary Generation:** Detects native OS (`Darwin/Linux`) and architecture (`x64/arm64`) to automatically retrieve the exact pristine GitHub payload natively and spawn worker directories seamlessly.
- **Purely Ephemeral:** Guaranteeing clean environments, every worker loop utilizes GitHub's `--ephemeral` flag to absolutely annihilate state leakage between consecutive PR test runs.

## System Configuration (The Bare-Metal Tradeoff)

Because these workers execute directly on the host machine OS instead of inside isolated Docker containers, **your host machine MUST be pre-configured with the toolchains your repositories require**. The actions will natively inherit the `$PATH` and packages of the user running `autoscaler.sh`.

### Provisioning the Host Machine

Before throwing CI/CD jobs at this coordinator, ensure you have natively installed the runtimes needed for your specific repositories globally. We highly recommend using resilient version managers so standard actions (like `actions/setup-node`) can switch environments cleanly without fighting permissions:

1. **Node.js**: Install [`nvm`](https://github.com/nvm-sh/nvm) (Node Version Manager) into the runner user's local `~/.nvm` to allow javascript engines to transition dynamically.
2. **Java**: Install `openjdk` via `brew install openjdk` locally, or use [`SDKMAN!`](https://sdkman.io/) for fluid JDK switching inside workflow files.
3. **Rust**: Install [`rustup`](https://rustup.rs/) strictly under the executing user's profile to prevent compiler namespace mismatches (`cc` linker errors).
4. **C/C++ Build Tools**: Ensure `gcc`, `make`, and a native linker `cc` are available (`xcode-select --install` on macOS or `sudo apt install build-essential` on Ubuntu).
5. **Docker (macOS specifics):** If your workflows require `docker build` or Dockerized service containers, install Docker Desktop or [OrbStack](https://orbstack.dev/) natively, and ensure the docker daemon socket is properly bound to the shell's active `$PATH`.

## Quick Start Guide

### 1. Supply your API Token and target Org
You must export a highly-scoped Personal Access Token (PAT) so the core daemon can dynamically request one-time runner registration keys and monitor `/actions/runners`, plus the org the runners should belong to.

**Required PAT Scopes:**
- **Classic PAT**: Must have the `admin:org` scope to manage organization-level runners.
- **Fine-Grained PAT**: Must grant **Read and Write** access to the Organization's **Self-hosted runners** permission.

Put both in a gitignored `.envrc` at the checkout root and load it with [direnv](https://direnv.net/), so each checkout on a host carries its own org and PAT:

```bash
export GH_RUNNER_PAT="github_pat_XXXXX..."
export GH_RUNNER_ORG="my-org"
```

Run `direnv allow` once, and again after any edit. Outside a direnv shell, use `direnv exec . ./start.sh`.

**Optional environment variables:**

| Variable | Default | Purpose |
| --- | --- | --- |
| `GH_RUNNER_NAME_PREFIX` | `baremetal-runner` | Prefix used when registering each runner. Final name is `${prefix}-<N>-<machine-hash>`. |
| `GH_RUNNER_GROUP` | *(unset — uses org default)* | If set, passed to `config.sh` as `--runnergroup`. |

### 2. Tune your Hardware Capacities
Copy `scaler.properties.example` to `scaler.properties` and optimize the maximum compute limit for your specific hardware. Each checkout keeps its own gitignored copy, so two fleets on one host can have different limits. Without one, the scripts use the defaults below.
```properties
MAX_RUNNERS=5
MIN_IDLE=1
POLL_INTERVAL=15
```
*(You can modify this file dynamically while the system is actively running!)*

### 3. Ignition
Launch the autoscaler logic into the background. The script will dynamically download the needed tarballs if absent and build your initial fleet.
```bash
./start.sh
```

### 4. Stopping & Cleanup
Need to freeze the hardware or reboot? Use the `stop.sh` utility to securely execute a graceful `pkill` across the entire fleet and wipe any orphaned config states.
```bash
./stop.sh
```

If you want a full clean slate — deregistering runners from GitHub and wiping the extracted binaries, tarball, and persisted `.machine-id` — use `purge.sh` instead. This is the right tool before decommissioning a host or re-keying to a new org/prefix.
```bash
./purge.sh
```

## Starting at Boot (Linux)

`systemd/gha-fleet@.service` starts a fleet at boot. The instance name is the checkout directory under `~/Tools`:
```bash
cp systemd/gha-fleet@.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now gha-fleet@bare-metal-gha-autoscaler.service
loginctl enable-linger
```

From then on, stop and start that fleet with `systemctl --user`. It restarts only at boot, not after a crash, so a manual `./stop.sh` stays stopped.

## Multi-Machine Deployments

This daemon is designed to run on many hosts against the same GitHub org without collision. On first start, each checkout stamps a random 6-char hex identifier into a local `.machine-id` file. That identifier is appended to every runner name (e.g. `baremetal-runner-1-a1b2c3`), and the autoscaler's GitHub-side filters are scoped to names ending in that suffix.

The practical effect: each machine manages only the runners it registered itself. A machine configured with `MIN_IDLE=1` will always maintain its own idle runner regardless of how many idle runners other machines happen to have online.

The `.machine-id` file is gitignored so every host generates its own on first launch. `purge.sh` deletes it; the next `./start.sh` will stamp a fresh one.

## Monitoring the Brain

Watch the intelligence daemon dynamically make API polling decisions across the fleet live:
```bash
tail -f autoscaler.log
```
