# Dockerfile Compatibility with run_128_one.sh

This document shows how the Docker image meets the requirements of `circuits/verify_header/run_128_one.sh`.

## Requirements from run_128_one.sh

The script checks for and uses:

| Tool | Script requirement | Dockerfile provides | ✓ |
|------|-------------------|---------------------|---|
| **Node.js** | 16+ (line 102: "Please install Node.js 16+") | Node.js 16.x | ✓ |
| **circom** | Checked via `command -v circom` (line 150-155) | Circom 2.1.0 in `/usr/local/bin/circom` | ✓ |
| **snarkjs** | Used for witness/proof generation | Global install via npm | ✓ |
| **rapidsnark** | Optional (lines 107-111), falls back to snarkjs | Built and installed at `/usr/local/bin/rapidsnark` | ✓ |
| **GCC/make** | For compiling witness generator in C++ mode | `build-essential` package | ✓ |
| **git** | For submodule operations | Installed via apt | ✓ |
| **PTAU file** | Required for zkey generation (lines 73-82) | **NOT included** - must mount as volume | ⚠️ |

## Requirements from circom-pairing

From `circuits/utils/circom-pairing/README.md`:

| Requirement | Dockerfile provides | ✓ |
|-------------|---------------------|---|
| circom >= 2.0.3 | Circom 2.0.8 | ✓ |
| snarkjs | Global npm install | ✓ |
| Node.js (for snarkjs) | Node.js 16 | ✓ |

## What's NOT included

1. **Powers of Tau file** (`.ptau`):  
   - The script looks for it at paths like `/home_data/.../powersOfTau28_hez_final_27.ptau`, `pot25_final.ptau`, etc.
   - You must mount it as a volume when running the container and set `PTAU_FILE` env var.

2. **Patched Node** (optional):
   - The script prefers a patched Node binary for very large circuits (>128GB memory).
   - The Docker image uses standard Node 16 with `--max-old-space-size` flag.
   - For most use cases this is sufficient.

3. **Git submodules**:
   - Must be initialized inside the container or on the host before mounting:
     ```bash
     git submodule update --init --recursive
     ```

4. **npm dependencies**:
   - Must run `npm install` inside `circuits/` directory after mounting the repo.

## Usage example

```bash
# On the server, from the repo root
docker run --rm -it \
  -v "$(pwd):/workspace" \
  -v "/path/to/ptau:/ptau:ro" \
  -e PTAU_FILE=/ptau/powersOfTau28_hez_final_27.ptau \
  -e NODE_MEM=32768 \
  zkbridge-lightclient

# Inside the container
git submodule update --init --recursive
cd circuits && npm install && cd ..
cd circuits/verify_header
./run_128_one.sh --compile-only
```

## Summary

The Dockerfile provides **all required tools** for running `run_128_one.sh`. The only external dependency is the **Powers of Tau file**, which must be provided by the user.
