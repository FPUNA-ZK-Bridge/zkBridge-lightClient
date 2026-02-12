#!/usr/bin/env bash
# Optional setup script for Ubuntu hosts (22.04 / 24.04).
# For a reproducible environment, prefer using the Docker image; see docker/README.md.

set -e

NODE_VERSION="${NODE_VERSION:-14}"
CIRCOM_VERSION="${CIRCOM_VERSION:-2.2.0}"
INSTALL_RAPIDSNARK="${INSTALL_RAPIDSNARK:-0}"
INSTALL_FOUNDRY="${INSTALL_FOUNDRY:-0}"

echo "Installing system packages..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  git \
  libgmp-dev \
  libsodium-dev \
  m4 \
  nasm \
  python3 \
  python3-pip

echo "Installing Node.js ${NODE_VERSION}..."
curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo bash -
sudo apt-get install -y --no-install-recommends nodejs

echo "Installing snarkjs..."
sudo npm install -g snarkjs

echo "Installing circom v${CIRCOM_VERSION}..."
sudo curl -fsSL "https://github.com/iden3/circom/releases/download/v${CIRCOM_VERSION}/circom-linux-amd64" -o /usr/local/bin/circom
sudo chmod +x /usr/local/bin/circom

if [ "$INSTALL_FOUNDRY" = "1" ]; then
  echo "Installing Foundry..."
  curl -L https://foundry.paradigm.xyz | bash
  export PATH="$HOME/.foundry/bin:$PATH"
  foundryup
  echo "Foundry installed. Add to PATH: export PATH=\"\$HOME/.foundry/bin:\$PATH\""
else
  echo "Skipping Foundry (set INSTALL_FOUNDRY=1 to install for contracts)."
fi

if [ "$INSTALL_RAPIDSNARK" = "1" ]; then
  echo "Building rapidsnark (this may take a while)..."
  RAPIDSNARK_DIR="${RAPIDSNARK_DIR:-$HOME/rapidsnark}"
  git clone --depth 1 https://github.com/iden3/rapidsnark.git "$RAPIDSNARK_DIR"
  cd "$RAPIDSNARK_DIR"
  git submodule update --init --recursive
  ./build_gmp.sh host
  make host
  sudo cp package/bin/prover /usr/local/bin/rapidsnark
  cd - >/dev/null
  echo "Rapidsnark installed at /usr/local/bin/rapidsnark"
else
  echo "Skipping rapidsnark (set INSTALL_RAPIDSNARK=1 to build and install)."
fi

echo "Setup complete. Node $(node --version), circom $(circom --version), snarkjs installed."
