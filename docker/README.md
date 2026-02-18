# Running with Docker

The project provides a Docker image with all toolchain dependencies: Node.js 16, Circom 2.0.8, snarkjs, and build tools (GCC, cmake, etc.). Use it to compile and run circuits without installing dependencies on the host.

## Versions included

- **Node.js**: 16.x (default, for npm and circuit scripts)
- **Circom**: 2.0.8 (meets requirement >= 2.0.3 from circom-pairing)
- **snarkjs**: 0.4.10 (global install in image)
- **Build tools**: GCC, cmake, make, libgmp-dev, libsodium-dev, nasm (for compiling C++ witness generators)

**Note:** Rapidsnark and patched Node are not included. The circuit scripts compile C++ witness generators for heavy parts (Part2, Part3A, Part3B) to avoid WASM memory limits.

## Building the image

From the repository root (build time: ~2 minutes):

```bash
docker build -t zkbridge-lightclient .
```

## Running the container

The image expects the repository to be mounted at `/workspace`. Optionally mount a directory containing the Powers of Tau (`.ptau`) file so circuit scripts can use it.

```bash
docker run --rm -it -v "$(pwd):/workspace" -w /workspace zkbridge-lightclient
```

(The container starts with `/bin/sh` by default; you can also explicitly run `sh` or other commands.)

With a volume for the PTAU file (e.g. `~/ptau` contains `pot25_final.ptau`):

```bash
docker run --rm -it \
  -v "$(pwd):/workspace" \
  -v "$HOME/ptau:/ptau:ro" \
  -e PTAU_FILE=/ptau/pot25_final.ptau \
  -w /workspace \
  zkbridge-lightclient
```

Inside the container you can run any command. Examples:

**Initialize submodules**

```bash
git submodule update --init --recursive
```

**Circuits (compile only)**

```bash
cd circuits && npm install
cd verify_header && ./run_128_one.sh --compile-only
```

For full circuit pipeline (trusted setup, proving) you must have a `.ptau` file available and set `PTAU_FILE` (or place the file in one of the paths the scripts search; see circuit scripts).

## Environment variables

| Variable            | Description |
| ------------------- | ----------- |
| `PTAU_FILE`         | Path to the Powers of Tau file (e.g. `powersOfTau28_hez_final_27.ptau` or `pot25_final.ptau`). Not included in the image; mount a volume and set this. |
| `NODE_MEM`          | Node.js heap size in MB (default 16384 in image env). Increase for large circuits (e.g. 98304 for 96GB with 128GB RAM). |

## Docker Compose (optional)

You can use a `docker-compose.yml` to standardize the run:

```yaml
services:
  app:
    build: .
    image: zkbridge-lightclient
    working_dir: /workspace
    volumes:
      - .:/workspace
      - ./ptau:/ptau:ro
    environment:
      - PTAU_FILE=/ptau/pot25_final.ptau
    stdin_open: true
    tty: true
    command: bash
```

Then:

```bash
docker compose run --rm app
```

Or for an interactive shell:

```bash
docker compose run --rm app sh
```

## Notes

- The image does **not** include a Powers of Tau file. Download it separately and mount it or set `PTAU_FILE` to a path inside the container where it is mounted.
- Submodules must be initialized inside the container (or on the host before mounting) so that `contracts/lib/forge-std`, `contracts/lib/openzeppelin-contracts`, and `circuits/utils/circom-pairing`, `circuits/utils/circom-sha256` are present.
- The container user is non-root (`app`, uid 1000). Files created in `/workspace` will match that user when the volume is mounted.

## Alternative: host setup (no Docker)

On Ubuntu 22.04/24.04 you can install the toolchain on the host with the optional script (not required if you use Docker):

```bash
./scripts/setup-dev-ubuntu.sh
```

Set `INSTALL_RAPIDSNARK=1` to also build and install rapidsnark (optional; snarkjs is used if not available). Set `INSTALL_FOUNDRY=1` if you need Foundry for contracts (not included in Docker image by default).

## How witness generation works

The circuit compilation (with `--compile-only` or full pipeline) generates both:

1. **WASM witness generator** (`*_js/` folder) - fast but has memory limits (~2-4 GB).
2. **C++ witness generator** (`*_cpp/` folder + binary) - slower to compile but no memory limit.

The scripts automatically use C++ generators when available (especially for heavy parts like Part 2, Part 3A, Part 3B), avoiding "memory access out of bounds" errors.
