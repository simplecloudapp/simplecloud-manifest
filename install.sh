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

print_warning() {
    echo -e "\033[0;33m!\033[0m $1"
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

resolve_bun_exec() {
    if [ -x "$HOME/.bun/bin/bun" ]; then
        echo "$HOME/.bun/bin/bun"
    elif command -v bun > /dev/null 2>&1; then
        command -v bun
    else
        echo ""
    fi
}

verify_bun_runtime() {
    local bun_version

    BUN_EXEC=$(resolve_bun_exec)
    if [ -z "$BUN_EXEC" ]; then
        print_error "Package Manager binary was not found after installation"
        exit 1
    fi

    if ! bun_version=$("$BUN_EXEC" --version 2>/dev/null); then
        print_error "Package Manager binary exists but cannot be executed ($BUN_EXEC)"
        exit 1
    fi

    if [ -z "$bun_version" ]; then
        print_error "Package Manager version check returned empty output"
        exit 1
    fi

    print_success "Verified Package Manager runtime ($bun_version)"
}

install_bun_cmd() {
    curl -fsSL https://bun.sh/install | bash
}

install_bun() {
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    hash -r 2>/dev/null || true

    BUN_EXEC=$(resolve_bun_exec)
    if [ -n "$BUN_EXEC" ]; then
        verify_bun_runtime
        return
    fi

    spin "Installing Package Manager" install_bun_cmd

    hash -r 2>/dev/null || true

    verify_bun_runtime
}

install_cli() {
    spin "Installing SimpleCloud CLI" "$BUN_EXEC" i -g simplecloud

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

verify_cli_runtime() {
    local cli_exec=""
    local cli_version

    if [ -x "$HOME/.bun/bin/simplecloud" ]; then
        cli_exec="$HOME/.bun/bin/simplecloud"
    elif [ -x "$HOME/.bun/bin/sc" ]; then
        cli_exec="$HOME/.bun/bin/sc"
    elif command -v simplecloud > /dev/null 2>&1; then
        cli_exec=$(command -v simplecloud)
    elif command -v sc > /dev/null 2>&1; then
        cli_exec=$(command -v sc)
    fi

    if [ -z "$cli_exec" ]; then
        print_error "SimpleCloud CLI binary was not found after installation"
        exit 1
    fi

    if ! cli_version=$("$cli_exec" --version 2>/dev/null); then
        print_error "SimpleCloud CLI binary exists but cannot be executed ($cli_exec)"
        exit 1
    fi

    if [ -z "$cli_version" ]; then
        print_error "SimpleCloud CLI version check returned empty output"
        exit 1
    fi

    print_success "Verified SimpleCloud CLI runtime ($cli_version)"
}

rewrite_cli_shebang() {
    local cli_file="$1"
    local first_line
    local temp_file

    if [ ! -f "$cli_file" ]; then
        return
    fi

    first_line=$(head -n 1 "$cli_file" 2>/dev/null || true)
    if [ "$first_line" != "#!/usr/bin/env bun" ]; then
        return
    fi

    if [[ "$BUN_EXEC" =~ [[:space:]] ]]; then
        print_warning "Skipping shebang rewrite for $cli_file because bun path contains spaces"
        return
    fi

    temp_file=$(mktemp)
    printf '#!%s\n' "$BUN_EXEC" > "$temp_file"
    tail -n +2 "$cli_file" >> "$temp_file"
    mv "$temp_file" "$cli_file"
    chmod +x "$cli_file"
}

ensure_runtime_shebang() {
    rewrite_cli_shebang "$HOME/.bun/bin/simplecloud"
    rewrite_cli_shebang "$HOME/.bun/bin/sc"
}

install_user_links() {
    local user_bin="$HOME/.local/bin"
    mkdir -p "$user_bin"

    if [ -x "$HOME/.bun/bin/simplecloud" ]; then
        ln -sf "$HOME/.bun/bin/simplecloud" "$user_bin/simplecloud"
    fi

    if [ -x "$HOME/.bun/bin/sc" ]; then
        ln -sf "$HOME/.bun/bin/sc" "$user_bin/sc"
    fi
}

link_system_binary() {
    local name="$1"
    local source_path="$2"
    local target="/usr/local/bin/$name"

    if [ ! -x "$source_path" ]; then
        return 1
    fi

    if [ -w "/usr/local/bin" ]; then
        ln -sf "$source_path" "$target"
        return 0
    fi

    if command -v sudo > /dev/null 2>&1; then
        if sudo ln -sf "$source_path" "$target"; then
            return 0
        fi
    fi

    return 1
}

install_system_links() {
    local linked_any=0

    if link_system_binary "simplecloud" "$HOME/.bun/bin/simplecloud"; then
        linked_any=1
    fi

    if link_system_binary "sc" "$HOME/.bun/bin/sc"; then
        linked_any=1
    fi

    if [ "$linked_any" -eq 1 ]; then
        print_success "Linked CLI commands into /usr/local/bin"
    else
        print_warning "Could not link into /usr/local/bin (permissions). Added user-level links in ~/.local/bin instead."
    fi
}

setup_path() {
    local bun_bin="$HOME/.bun/bin"
    local user_bin="$HOME/.local/bin"
    local config_files="$HOME/.bashrc $HOME/.bash_profile $HOME/.profile $HOME/.zshrc $HOME/.zprofile"
    local config_file

    for config_file in $config_files; do
        if [ ! -f "$config_file" ]; then
            continue
        fi

        if ! grep -q 'simplecloud installer path setup' "$config_file"; then
            echo '' >> "$config_file"
            echo '# simplecloud installer path setup' >> "$config_file"
            echo 'export BUN_INSTALL="$HOME/.bun"' >> "$config_file"
            echo 'export PATH="$HOME/.local/bin:$BUN_INSTALL/bin:$PATH"' >> "$config_file"
        fi
    done

    export PATH="$user_bin:$bun_bin:$PATH"
}

show_post_install_hint() {
    if command -v simplecloud > /dev/null 2>&1 || command -v sc > /dev/null 2>&1; then
        return
    fi

    print_warning "If your current shell cannot find 'simplecloud' yet, run:"
    echo "  source ~/.bashrc 2>/dev/null || source ~/.zshrc 2>/dev/null"
    print_warning "Direct binary path: $HOME/.bun/bin/simplecloud"
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
    ensure_runtime_shebang
    install_user_links
    install_system_links
    hash -r 2>/dev/null || true
    verify_cli_runtime
    
    echo ""
    print_success "Installation complete!"
    echo ""
    echo -e "Run ${GREEN}simplecloud${NC} or ${GREEN}sc${NC} to get started."
    show_post_install_hint
    echo ""
}

main || exit 1
