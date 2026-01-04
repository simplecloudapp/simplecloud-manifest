#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

spin() {
    local msg="$1"
    shift
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local pid
    local i=0
    local temp_file=$(mktemp)
    
    "$@" > "$temp_file" 2>&1 &
    pid=$!
    
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${BLUE}%s${NC} %s" "${frames:i++%${#frames}:1}" "$msg"
        sleep 0.1
    done
    
    wait "$pid"
    local exit_code=$?
    
    printf "\r\033[K"
    
    if [ $exit_code -eq 0 ]; then
        print_success "$msg"
    else
        print_error "$msg"
        cat "$temp_file"
    fi
    
    rm -f "$temp_file"
    return $exit_code
}

detect_os() {
    OS=$(uname -s)
    case "$OS" in
        Linux)
            echo "linux"
            ;;
        Darwin)
            echo "macos"
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

install_unzip_apt() {
    if ! sudo apt-get install -y unzip 2>/dev/null; then
        sudo apt-get update -y
        sudo apt-get install -y unzip
    fi
}

install_unzip() {
    local pkg_manager=$1

    if command -v unzip &> /dev/null; then
        print_success "unzip is already installed"
        return
    fi

    case "$pkg_manager" in
        apt)
            spin "Installing unzip" install_unzip_apt
            ;;
        dnf)
            spin "Installing unzip" sudo dnf install -y unzip
            ;;
        yum)
            spin "Installing unzip" sudo yum install -y unzip
            ;;
        pacman)
            spin "Installing unzip" sudo pacman -S --noconfirm unzip
            ;;
        *)
            print_error "Unknown package manager, cannot install unzip"
            exit 1
            ;;
    esac

    if ! command -v unzip &> /dev/null; then
        print_error "Failed to install unzip"
        exit 1
    fi
}

install_bun_cmd() {
    curl -fsSL https://bun.sh/install | bash
}

install_bun() {
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    hash -r 2>/dev/null || true

    if command -v bun &> /dev/null; then
        print_success "Bun is already installed ($(bun --version))"
        return
    fi

    spin "Installing Bun" install_bun_cmd

    hash -r 2>/dev/null || true

    if ! command -v bun &> /dev/null; then
        if [ -x "$HOME/.bun/bin/bun" ]; then
            print_success "Bun installed at $HOME/.bun/bin/bun"
        else
            print_error "Failed to install Bun"
            exit 1
        fi
    fi
}

install_cli() {
    spin "Installing SimpleCloud CLI" bun i -g simplecloud

    hash -r 2>/dev/null || true

    if ! command -v simplecloud &> /dev/null && ! command -v sc &> /dev/null; then
        if [ -x "$HOME/.bun/bin/simplecloud" ] || [ -x "$HOME/.bun/bin/sc" ]; then
            print_success "SimpleCloud CLI installed at $HOME/.bun/bin/"
        else
            print_error "Failed to install SimpleCloud CLI"
            exit 1
        fi
    fi
}

setup_path() {
    local bun_bin="$HOME/.bun/bin"
    local config_files=""
    
    if [ -n "$ZSH_VERSION" ] || [ "$SHELL" = "/bin/zsh" ]; then
        config_files="$HOME/.zshrc"
    else
        config_files="$HOME/.bashrc $HOME/.profile"
    fi
    
    for config_file in $config_files; do
        if [ -f "$config_file" ]; then
            if ! grep -q 'BUN_INSTALL' "$config_file"; then
                echo '' >> "$config_file"
                echo 'export BUN_INSTALL="$HOME/.bun"' >> "$config_file"
                echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$config_file"
            fi
        fi
    done
    
    export PATH="$bun_bin:$PATH"
}

main() {
    echo ""
    echo -e "${BLUE}SimpleCloud CLI Installer${NC}"
    echo ""
    
    OS=$(detect_os)
    
    if [ "$OS" = "unsupported" ]; then
        print_error "Unsupported operating system. This script supports Linux and macOS only."
        exit 1
    fi
    
    print_success "Detected OS: $OS"
    
    if [ "$OS" = "linux" ]; then
        PKG_MANAGER=$(detect_package_manager)
        print_success "Detected package manager: $PKG_MANAGER"
        install_unzip "$PKG_MANAGER"
    fi
    
    install_bun
    setup_path
    install_cli
    
    echo ""
    print_success "Installation complete!"
    echo ""
    echo -e "Run ${GREEN}simplecloud${NC} or ${GREEN}sc${NC} to get started."
    echo ""
}

main || exit 1

if [ -n "$ZSH_VERSION" ] || [ "$SHELL" = "/bin/zsh" ]; then
    exec zsh -l </dev/tty
else
    exec bash -l </dev/tty
fi
