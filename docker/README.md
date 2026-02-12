# Running with Docker

The project provides a Docker image with all toolchain dependencies: Node.js 14, circom, snarkjs, rapidsnark, and build tools (GCC, cmake, etc.). Use it to compile circuits without installing dependencies on the host.

## Building the image

From the repository root:

```bash
docker build -t zkbridge-lightclient .
```

## Running the container

The image expects the repository to be mounted at `/workspace`. Optionally mount a directory containing the Powers of Tau (`.ptau`) file so circuit scripts can use it.

```bash
docker run --rm -it -v "$(pwd):/workspace" -w /workspace zkbridge-lightclient bash
```

With a volume for the PTAU file (e.g. `~/ptau` contains `pot25_final.ptau`):

```bash
docker run --rm -it \
  -v "$(pwd):/workspace" \
  -v "$HOME/ptau:/ptau:ro" \
  -e PTAU_FILE=/ptau/pot25_final.ptau \
  -w /workspace \
  zkbridge-lightclient bash
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
| `NODE_MEM`          | Node.js heap size in MB (default in scripts is 16384). Increase for large circuits (e.g. 65536 for 64GB). |
| `PATCHED_NODE_PATH` | Optional path to a patched Node binary with larger heap; only needed for very large circuits. |

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
docker compose run --rm app bash
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

Set `INSTALL_RAPIDSNARK=1` to also build and install rapidsnark. Set `INSTALL_FOUNDRY=1` if you need Foundry for contracts (not included in Docker image by default).
