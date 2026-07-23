#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ ! -t 1 ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

terminate_process_tree() {
    local pid="$1"
    local signal="$2"
    local child

    if command -v pgrep > /dev/null 2>&1; then
        for child in $(pgrep -P "$pid" 2>/dev/null); do
            terminate_process_tree "$child" "$signal"
        done
    fi

    kill "-$signal" "$pid" 2>/dev/null || true
}

run_with_timeout() {
    local timeout_seconds="$1"
    shift
    local command_pid
    local watchdog_pid
    local exit_code
    local timeout_marker

    timeout_marker=$(mktemp)
    rm -f "$timeout_marker"

    "$@" &
    command_pid=$!

    (
        sleep "$timeout_seconds"
        if kill -0 "$command_pid" 2>/dev/null; then
            : > "$timeout_marker"
            terminate_process_tree "$command_pid" TERM
            sleep 3
            if kill -0 "$command_pid" 2>/dev/null; then
                terminate_process_tree "$command_pid" KILL
            fi
        fi
    ) &
    watchdog_pid=$!

    wait "$command_pid" 2>/dev/null
    exit_code=$?

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [ -e "$timeout_marker" ]; then
        rm -f "$timeout_marker"
        echo "Command timed out after ${timeout_seconds} seconds."
        return 124
    fi

    rm -f "$timeout_marker"
    return "$exit_code"
}

run_with_retries() {
    local timeout_seconds="$1"
    local max_attempts="$2"
    shift 2
    local attempt=1
    local exit_code

    while [ "$attempt" -le "$max_attempts" ]; do
        run_with_timeout "$timeout_seconds" "$@"
        exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            return 0
        fi

        if [ "$attempt" -ge "$max_attempts" ]; then
            return "$exit_code"
        fi

        echo "Attempt ${attempt}/${max_attempts} failed; retrying in $((attempt * 2)) seconds..."
        sleep $((attempt * 2))
        attempt=$((attempt + 1))
    done
}

spin() {
    local msg="$1"
    local timeout_seconds="$2"
    local max_attempts="$3"
    shift 3
    local frames='|/-\'
    local pid
    local i=0
    local temp_file
    local exit_code

    temp_file=$(mktemp)
    
    run_with_retries "$timeout_seconds" "$max_attempts" "$@" > "$temp_file" 2>&1 &
    pid=$!
    
    if [ -t 1 ]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf "\r${BLUE}%s${NC} %s" "${frames:i++%${#frames}:1}" "$msg"
            sleep 0.1
        done
    else
        printf "%s...\n" "$msg"
    fi
    
    wait "$pid"
    exit_code=$?
    
    if [ -t 1 ]; then
        printf "\r\033[K"
    fi
    
    if [ "$exit_code" -eq 0 ]; then
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

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

prepare_privileges() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi

    if ! command -v sudo > /dev/null 2>&1; then
        print_error "Administrator access is required to install missing system packages, but sudo was not found"
        return 1
    fi

    echo "Administrator access is required to install missing prerequisites."
    sudo -v
}

install_packages_apt() {
    if ! run_privileged env DEBIAN_FRONTEND=noninteractive apt-get \
        -o DPkg::Lock::Timeout=60 \
        -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        install -y "$@"; then
        run_privileged apt-get \
            -o DPkg::Lock::Timeout=60 \
            -o Acquire::Retries=3 \
            -o Acquire::http::Timeout=30 \
            -o Acquire::https::Timeout=30 \
            update
        run_privileged env DEBIAN_FRONTEND=noninteractive apt-get \
            -o DPkg::Lock::Timeout=60 \
            -o Acquire::Retries=3 \
            -o Acquire::http::Timeout=30 \
            -o Acquire::https::Timeout=30 \
            install -y "$@"
    fi
}

install_packages() {
    local pkg_manager=$1
    shift

    case "$pkg_manager" in
        apt)
            install_packages_apt "$@"
            ;;
        dnf)
            run_privileged dnf install -y --setopt=timeout=30 --setopt=retries=3 "$@"
            ;;
        yum)
            run_privileged yum install -y --setopt=timeout=30 --setopt=retries=3 "$@"
            ;;
        pacman)
            run_privileged pacman -Syu --noconfirm --needed "$@"
            ;;
        *)
            print_error "Unknown package manager; install these prerequisites manually: $*"
            return 1
            ;;
    esac
}

install_prerequisites() {
    local pkg_manager="$1"
    local packages=""
    local package

    for package in curl unzip; do
        if ! command -v "$package" > /dev/null 2>&1; then
            packages="$packages $package"
        fi
    done

    if [ -z "$packages" ]; then
        print_success "System prerequisites are already installed"
        return 0
    fi

    if [ "$pkg_manager" = "unknown" ]; then
        print_error "No supported package manager was found. Install curl and unzip manually, then run this installer again."
        exit 1
    fi

    prepare_privileges || exit 1

    # Word splitting is intentional: package names are fixed above.
    spin "Installing system prerequisites" 300 1 install_packages "$pkg_manager" $packages || exit 1

    for package in curl unzip; do
        if ! command -v "$package" > /dev/null 2>&1; then
            print_error "Failed to install required command: $package"
            exit 1
        fi
    done
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
    local installer_file
    local exit_code

    installer_file=$(mktemp)

    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 120 \
        --output "$installer_file" \
        https://bun.sh/install
    exit_code=$?

    if [ "$exit_code" -eq 0 ] && [ -s "$installer_file" ]; then
        bash "$installer_file"
        exit_code=$?
    elif [ "$exit_code" -eq 0 ]; then
        echo "Downloaded Package Manager installer was empty."
        exit_code=1
    fi

    rm -f "$installer_file"
    return "$exit_code"
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

    spin "Installing Package Manager" 180 2 install_bun_cmd || exit 1

    hash -r 2>/dev/null || true

    verify_bun_runtime
}

install_cli() {
    spin "Installing SimpleCloud CLI" 180 3 "$BUN_EXEC" i -g simplecloud || exit 1

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

remove_path() {
    local target="$1"

    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        return 0
    fi

    if rm -f "$target" 2>/dev/null; then
        return 0
    fi

    if command -v sudo > /dev/null 2>&1; then
        if sudo rm -f "$target"; then
            return 0
        fi
    fi

    return 1
}

cleanup_user_cli_paths() {
    local removed_any=0
    local target

    for target in "$HOME/.bun/bin/simplecloud" "$HOME/.bun/bin/sc" "$HOME/.local/bin/simplecloud" "$HOME/.local/bin/sc"; do
        if [ -e "$target" ] || [ -L "$target" ]; then
            if remove_path "$target"; then
                removed_any=1
            else
                print_warning "Could not remove old CLI path: $target"
            fi
        fi
    done

    if [ "$removed_any" -eq 1 ]; then
        print_success "Removed existing user-level CLI command paths"
    fi
}

cleanup_system_sc_symlink() {
    local target="/usr/local/bin/sc"
    local link_target=""

    if [ ! -L "$target" ]; then
        return
    fi

    link_target=$(readlink "$target" 2>/dev/null || true)
    case "$link_target" in
        *simplecloud*|*"/.bun/bin/sc"|*"/.bun/bin/simplecloud")
            if remove_path "$target"; then
                print_success "Removed existing system-level sc symlink"
            else
                print_warning "Could not remove old CLI symlink: $target"
            fi
            ;;
    esac
}

cleanup_existing_cli() {
    local target="/usr/local/bin/simplecloud"

    cleanup_user_cli_paths

    if [ -e "$target" ] || [ -L "$target" ]; then
        if remove_path "$target"; then
            print_success "Removed existing system-level simplecloud command"
        else
            print_warning "Could not remove old CLI command: $target"
        fi
    fi

    cleanup_system_sc_symlink
    hash -r 2>/dev/null || true
}

confirm_preinstall_stop() {
    local response

    if [ ! -t 0 ]; then
        print_warning "Previous CLI installation detected; attempting a non-interactive stop before reinstalling."
        return 0
    fi

    echo "A previous SimpleCloud CLI installation was detected."
    echo "Is it okay to uninstall the old version and stop all running servers before continuing?"

    printf "[Y/n]: "
    read -r response

    case "$response" in
        ""|[Yy]|[Yy][Ee][Ss])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

stop_existing_cloud() {
    if ! command -v simplecloud > /dev/null 2>&1; then
        return
    fi

    if ! confirm_preinstall_stop; then
        print_error "Installation canceled by user"
        exit 1
    fi

    if simplecloud stop cloud -ys > /dev/null 2>&1; then
        print_success "Stopped running cloud before reinstall"
        return
    fi

    if simplecloud stop --stop-servers > /dev/null 2>&1; then
        print_success "Stopped running cloud before reinstall"
        return
    fi

    print_warning "Could not stop cloud automatically; continuing installation"
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
        install_prerequisites "$PKG_MANAGER"
    else
        if ! command -v curl > /dev/null 2>&1 || ! command -v unzip > /dev/null 2>&1; then
            print_error "Missing required commands. Install curl and unzip, then run this installer again."
            exit 1
        fi
        print_success "System prerequisites are already installed"
    fi
    
    install_bun
    setup_path
    stop_existing_cloud
    cleanup_existing_cli
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

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main || exit 1
fi
