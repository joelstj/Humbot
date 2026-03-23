#!/usr/bin/env bash
# setup_debian.sh — One-shot Hummingbot setup & launcher for Linux Debian systems.
#
# Usage:
#   chmod +x setup_debian.sh
#   ./setup_debian.sh            # install everything, then open the Hummingbot dashboard
#   ./setup_debian.sh --dydx     # use the dYdX environment instead of the default one
#   ./setup_debian.sh --skip-launch   # install only, do not open the dashboard

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die()     { error "$*"; exit 1; }

require_root_or_sudo() {
    if [[ $EUID -ne 0 ]] && ! command -v sudo &>/dev/null; then
        die "This script needs sudo (or must be run as root) to install system packages."
    fi
}

apt_install() {
    if [[ $EUID -eq 0 ]]; then
        apt-get install -y "$@"
    else
        sudo apt-get install -y "$@"
    fi
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
USE_DYDX=false
SKIP_LAUNCH=false
for arg in "$@"; do
    case "$arg" in
        --dydx)        USE_DYDX=true ;;
        --skip-launch) SKIP_LAUNCH=true ;;
        *)             warn "Unknown argument: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve project root (the directory that contains this script)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
info "Checking OS …"
if ! grep -qiE 'debian|ubuntu|raspbian|linuxmint' /etc/os-release 2>/dev/null; then
    warn "This script is designed for Debian-based systems. Proceeding anyway…"
fi

require_root_or_sudo

info "Updating package lists …"
if [[ $EUID -eq 0 ]]; then
    apt-get update -qq
else
    sudo apt-get update -qq
fi

DEBIAN_PKGS=(
    build-essential
    curl
    wget
    git
    gcc
    g++
    python3-dev
    libusb-1.0-0
    libssl-dev
    libffi-dev
    zlib1g-dev
    bzip2
    ca-certificates
)

info "Installing system packages: ${DEBIAN_PKGS[*]} …"
apt_install "${DEBIAN_PKGS[@]}"

# ---------------------------------------------------------------------------
# 2. Miniconda / Conda
# ---------------------------------------------------------------------------
CONDA_EXE=""

# Try to find an existing conda installation
for candidate in \
    "$HOME/miniconda3/bin/conda" \
    "$HOME/anaconda3/bin/conda" \
    "/opt/conda/bin/conda" \
    "/usr/local/anaconda3/bin/conda" \
    "/root/miniconda/bin/conda" \
    "${CONDA:-}/bin/conda"
do
    if [[ -x "$candidate" ]]; then
        CONDA_EXE="$candidate"
        break
    fi
done

# Fall back to whatever is on PATH
if [[ -z "$CONDA_EXE" ]] && command -v conda &>/dev/null; then
    CONDA_EXE="$(command -v conda)"
fi

if [[ -z "$CONDA_EXE" ]]; then
    info "Conda not found — downloading Miniconda3 …"
    MINICONDA_INSTALLER="/tmp/miniconda_installer.sh"
    MINICONDA_PREFIX="$HOME/miniconda3"

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" ;;
        aarch64) MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh" ;;
        *)        die "Unsupported architecture: $ARCH" ;;
    esac

    curl -fsSL "$MINICONDA_URL" -o "$MINICONDA_INSTALLER"
    bash "$MINICONDA_INSTALLER" -b -p "$MINICONDA_PREFIX"
    rm -f "$MINICONDA_INSTALLER"

    CONDA_EXE="$MINICONDA_PREFIX/bin/conda"
    # Initialise conda for the current shell session
    # shellcheck source=/dev/null
    source "$MINICONDA_PREFIX/etc/profile.d/conda.sh"
    info "Miniconda installed at $MINICONDA_PREFIX"
else
    info "Using conda: $CONDA_EXE"
    CONDA_BIN_DIR="$(dirname "$CONDA_EXE")"
    CONDA_PROFILE="$(dirname "$CONDA_BIN_DIR")/etc/profile.d/conda.sh"
    if [[ -f "$CONDA_PROFILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONDA_PROFILE"
    fi
fi

CONDA_BIN="$(dirname "$CONDA_EXE")"

# ---------------------------------------------------------------------------
# 3. Create / update the hummingbot conda environment
# ---------------------------------------------------------------------------
ENV_FILE="setup/environment.yml"
if [[ "$USE_DYDX" == true ]]; then
    ENV_FILE="setup/environment_dydx.yml"
    info "Using dYdX environment file: $ENV_FILE"
fi

[[ -f "$ENV_FILE" ]] || die "Environment file not found: $ENV_FILE"

if "$CONDA_EXE" env list | awk '{print $1}' | grep -qx hummingbot; then
    info "Updating existing 'hummingbot' conda environment …"
    "$CONDA_EXE" env update -n hummingbot -f "$ENV_FILE"
else
    info "Creating 'hummingbot' conda environment …"
    "$CONDA_EXE" env create -f "$ENV_FILE"
fi

# Activate the environment for subsequent commands
# shellcheck source=/dev/null
source "${CONDA_BIN}/activate" hummingbot

# ---------------------------------------------------------------------------
# 4. Register project directory on the Python path (conda develop)
# ---------------------------------------------------------------------------
info "Registering project directory with conda develop …"
if ! conda develop . 2>/dev/null; then
    warn "'conda develop .' failed — the project directory may not be on sys.path. Continuing anyway."
fi

# ---------------------------------------------------------------------------
# 5. Extra pip packages
# ---------------------------------------------------------------------------
PIP_LOG="logs/pip_install.log"
mkdir -p logs
info "Installing pip packages from setup/pip_packages.txt …"
python -m pip install --no-deps -r setup/pip_packages.txt >"$PIP_LOG" 2>&1 \
    || { error "pip install failed — check $PIP_LOG for details."; cat "$PIP_LOG"; exit 1; }

# ---------------------------------------------------------------------------
# 6. Compile Cython extensions
# ---------------------------------------------------------------------------
info "Compiling Cython extensions (this may take several minutes) …"
python setup.py build_ext --inplace \
    || die "Cython build failed. Make sure build-essential and gcc/g++ are installed."

# ---------------------------------------------------------------------------
# 7. Pre-commit hooks
# ---------------------------------------------------------------------------
if command -v pre-commit &>/dev/null; then
    info "Installing pre-commit hooks …"
    pre-commit install
else
    warn "pre-commit not found on PATH — skipping hook installation."
fi

# ---------------------------------------------------------------------------
# 8. Launch the Hummingbot dashboard
# ---------------------------------------------------------------------------
info "Setup complete!"
echo ""
echo "  To launch Hummingbot later, run:"
echo "    conda activate hummingbot && ./bin/hummingbot_quickstart.py"
echo ""

if [[ "$SKIP_LAUNCH" == true ]]; then
    info "--skip-launch specified. Exiting without starting the dashboard."
    exit 0
fi

QUICKSTART="./bin/hummingbot_quickstart.py"
if [[ ! -f "$QUICKSTART" ]]; then
    die "Launch file not found: $QUICKSTART — please run this script from the Hummingbot project root."
fi
if [[ ! -x "$QUICKSTART" ]]; then
    info "Making $QUICKSTART executable …"
    chmod +x "$QUICKSTART"
fi

info "Launching Hummingbot dashboard …"
exec "$QUICKSTART"
