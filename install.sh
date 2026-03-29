#!/bin/sh

ESC="$(printf '\033')"
RED="${ESC}[0;31m"
GREEN="${ESC}[0;32m"
BLUE="${ESC}[0;34m"
YELLOW="${ESC}[0;33m"
NC="${ESC}[0m"

OK_MARK="[OK]"
ERR_MARK="[ERR]"
WARN_MARK="[WARN]"
INFO_MARK="[INFO]"
BUN_EXEC=""
SPINNER_MAX=4
USE_UTF8_UI=0

supports_utf8() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*|*utf-8*)
            return 0
            ;;
    esac
    return 1
}

setup_ui() {
    if supports_utf8; then
        OK_MARK="$(printf '%b' '\342\234\223')"
        ERR_MARK="$(printf '%b' '\342\234\227')"
        WARN_MARK="!"
        INFO_MARK="$(printf '%b' '\342\200\272')"
        SPINNER_MAX=10
        USE_UTF8_UI=1
    fi
}

print_success() {
    printf "%b\n" "${GREEN}${OK_MARK}${NC} $*"
}

print_error() {
    printf "%b\n" "${RED}${ERR_MARK}${NC} $*"
}

print_warning() {
    printf "%b\n" "${YELLOW}${WARN_MARK}${NC} $*"
}

print_info() {
    printf "%b\n" "${BLUE}${INFO_MARK}${NC} $*"
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

has_terminal() {
    [ -t 0 ] && [ -t 1 ]
}

spinner_char() {
    if [ "$USE_UTF8_UI" -eq 1 ]; then
        case "$1" in
            0) printf '%b' '\342\240\213' ;;
            1) printf '%b' '\342\240\231' ;;
            2) printf '%b' '\342\240\271' ;;
            3) printf '%b' '\342\240\270' ;;
            4) printf '%b' '\342\240\274' ;;
            5) printf '%b' '\342\240\264' ;;
            6) printf '%b' '\342\240\246' ;;
            7) printf '%b' '\342\240\247' ;;
            8) printf '%b' '\342\240\207' ;;
            *) printf '%b' '\342\240\217' ;;
        esac
        return 0
    fi

    case "$1" in
        0) printf "%s" "|" ;;
        1) printf "%s" "/" ;;
        2) printf "%s" "-" ;;
        *) printf "%s" "\\" ;;
    esac
}

run_quiet() {
    msg="$1"
    shift
    temp_file=$(mktemp)

    if has_terminal; then
        "$@" </dev/null >"$temp_file" 2>&1 &
        cmd_pid=$!
        spinner_i=0

        while kill -0 "$cmd_pid" 2>/dev/null; do
            spinner_c=$(spinner_char "$spinner_i")
            spinner_line="${BLUE}${spinner_c}${NC} $msg"
            printf "\r%s" "$spinner_line"
            spinner_i=$((spinner_i + 1))
            if [ "$spinner_i" -ge "$SPINNER_MAX" ]; then
                spinner_i=0
            fi
            sleep 0.1
        done

        wait "$cmd_pid"
        rc=$?
        printf "\r\033[K"
    else
        print_info "$msg"
        "$@" >"$temp_file" 2>&1
        rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        rm -f "$temp_file"
        print_success "$msg"
        return 0
    fi

    print_error "$msg"
    cat "$temp_file"
    rm -f "$temp_file"
    return "$rc"
}

require_admin() {
    if is_root; then
        return 0
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        print_error "Admin access is needed."
        print_error "sudo is not installed."
        return 1
    fi

    if sudo -n true >/dev/null 2>&1; then
        return 0
    fi

    if ! has_terminal; then
        print_error "Admin access is needed."
        print_error "No terminal is available for sudo."
        return 1
    fi

    print_info "Administrator access is required."
    sudo -v
}

run_as_root() {
    if is_root; then
        "$@"
        return $?
    fi
    sudo "$@"
}

detect_os() {
    case "$(uname -s)" in
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
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
        return
    fi
    if command -v dnf >/dev/null 2>&1; then
        echo "dnf"
        return
    fi
    if command -v yum >/dev/null 2>&1; then
        echo "yum"
        return
    fi
    if command -v pacman >/dev/null 2>&1; then
        echo "pacman"
        return
    fi
    echo "unknown"
}

install_unzip_apt() {
    if run_as_root apt-get install -y unzip >/dev/null 2>&1; then
        return 0
    fi
    run_as_root apt-get update -y
    run_as_root apt-get install -y unzip
}

install_unzip_dnf() {
    run_as_root dnf install -y unzip
}

install_unzip_yum() {
    run_as_root yum install -y unzip
}

install_unzip_pacman() {
    run_as_root pacman -S --noconfirm unzip
}

install_unzip() {
    pkg_manager="$1"

    if command -v unzip >/dev/null 2>&1; then
        print_success "unzip is already installed"
        return 0
    fi

    require_admin || exit 1

    case "$pkg_manager" in
        apt)
            run_quiet "Installing unzip" install_unzip_apt || exit 1
            ;;
        dnf)
            run_quiet "Installing unzip" install_unzip_dnf || exit 1
            ;;
        yum)
            run_quiet "Installing unzip" install_unzip_yum || exit 1
            ;;
        pacman)
            run_quiet "Installing unzip" install_unzip_pacman || exit 1
            ;;
        *)
            print_error "Unknown package manager."
            print_error "Cannot install unzip."
            exit 1
            ;;
    esac

    if ! command -v unzip >/dev/null 2>&1; then
        print_error "Failed to install unzip."
        exit 1
    fi
}

resolve_bun_exec() {
    if [ -x "$HOME/.bun/bin/bun" ]; then
        echo "$HOME/.bun/bin/bun"
        return
    fi
    if command -v bun >/dev/null 2>&1; then
        command -v bun
        return
    fi
    echo ""
}

verify_bun_runtime() {
    BUN_EXEC=$(resolve_bun_exec)
    if [ -z "$BUN_EXEC" ]; then
        print_error "Package Manager binary was not found."
        exit 1
    fi

    bun_version=$("$BUN_EXEC" --version 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        print_error "Package Manager binary could not run."
        print_error "$BUN_EXEC"
        exit 1
    fi

    if [ -z "$bun_version" ]; then
        print_error "Package Manager version check was empty."
        exit 1
    fi

    print_success "Verified Package Manager runtime:"
    print_success "$bun_version"
}

install_bun_cmd() {
    curl -fsSL https://bun.sh/install | sh
}

install_bun() {
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    hash -r 2>/dev/null || true

    BUN_EXEC=$(resolve_bun_exec)
    if [ -n "$BUN_EXEC" ]; then
        verify_bun_runtime
        return 0
    fi

    run_quiet "Installing Package Manager" install_bun_cmd || exit 1
    hash -r 2>/dev/null || true
    verify_bun_runtime
}

install_cli_cmd() {
    "$BUN_EXEC" i -g simplecloud
}

install_cli() {
    run_quiet "Installing SimpleCloud CLI" install_cli_cmd || exit 1
    hash -r 2>/dev/null || true

    if command -v simplecloud >/dev/null 2>&1; then
        return 0
    fi
    if command -v sc >/dev/null 2>&1; then
        return 0
    fi
    if [ -x "$HOME/.bun/bin/simplecloud" ]; then
        print_success "SimpleCloud CLI installed at ~/.bun/bin/"
        return 0
    fi
    if [ -x "$HOME/.bun/bin/sc" ]; then
        print_success "SimpleCloud CLI installed at ~/.bun/bin/"
        return 0
    fi

    print_error "Failed to install SimpleCloud CLI."
    exit 1
}

remove_path() {
    target="$1"

    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        return 0
    fi
    if rm -f "$target" 2>/dev/null; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        if sudo rm -f "$target"; then
            return 0
        fi
    fi
    return 1
}

cleanup_user_cli_paths() {
    removed_any=0

    if remove_path "$HOME/.bun/bin/simplecloud"; then
        removed_any=1
    fi
    if remove_path "$HOME/.bun/bin/sc"; then
        removed_any=1
    fi
    if remove_path "$HOME/.local/bin/simplecloud"; then
        removed_any=1
    fi
    if remove_path "$HOME/.local/bin/sc"; then
        removed_any=1
    fi

    if [ "$removed_any" -eq 1 ]; then
        print_success "Removed existing user CLI command paths"
    fi
}

cleanup_system_sc_symlink() {
    target="/usr/local/bin/sc"

    if [ ! -L "$target" ]; then
        return 0
    fi

    link_target=$(readlink "$target" 2>/dev/null || true)
    case "$link_target" in
        *simplecloud*|*"/.bun/bin/sc"|*"/.bun/bin/simplecloud")
            if remove_path "$target"; then
                print_success "Removed existing system sc symlink"
            else
                print_warning "Could not remove old sc symlink:"
                print_warning "$target"
            fi
            ;;
    esac
}

cleanup_existing_cli() {
    target="/usr/local/bin/simplecloud"

    cleanup_user_cli_paths

    if [ -e "$target" ] || [ -L "$target" ]; then
        if remove_path "$target"; then
            print_success "Removed existing system simplecloud command"
        else
            print_warning "Could not remove old CLI command:"
            print_warning "$target"
        fi
    fi

    cleanup_system_sc_symlink
    hash -r 2>/dev/null || true
}

confirm_preinstall_stop() {
    echo "A previous SimpleCloud CLI installation was detected."
    echo "Remove old CLI links and stop running servers?"
    echo "This will not delete project files, cloud data,"
    echo "or config files."

    if ! has_terminal; then
        print_warning "No terminal detected. Trying stop anyway."
        return 0
    fi

    printf "[Y/n]: "
    read response

    case "$response" in
        ""|y|Y|yes|YES|Yes)
            return 0
            ;;
    esac
    return 1
}

resolve_existing_cli() {
    if command -v simplecloud >/dev/null 2>&1; then
        command -v simplecloud
        return
    fi
    if command -v sc >/dev/null 2>&1; then
        command -v sc
        return
    fi
    echo ""
}

stop_existing_cloud() {
    cli_exec=$(resolve_existing_cli)
    if [ -z "$cli_exec" ]; then
        return 0
    fi

    if ! confirm_preinstall_stop; then
        print_error "Installation canceled by user."
        exit 1
    fi

    if "$cli_exec" stop cloud -ys >/dev/null 2>&1; then
        print_success "Stopped running cloud before reinstall"
        return 0
    fi
    if "$cli_exec" stop --stop-servers >/dev/null 2>&1; then
        print_success "Stopped running cloud before reinstall"
        return 0
    fi

    print_warning "Could not stop cloud automatically."
    print_warning "Continuing installation."
}

verify_cli_runtime() {
    cli_exec=""

    if [ -x "$HOME/.bun/bin/simplecloud" ]; then
        cli_exec="$HOME/.bun/bin/simplecloud"
    elif [ -x "$HOME/.bun/bin/sc" ]; then
        cli_exec="$HOME/.bun/bin/sc"
    else
        cli_exec=$(resolve_existing_cli)
    fi

    if [ -z "$cli_exec" ]; then
        print_error "SimpleCloud CLI binary was not found."
        exit 1
    fi

    cli_version=$("$cli_exec" --version 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        print_error "SimpleCloud CLI binary could not run."
        print_error "$cli_exec"
        exit 1
    fi

    if [ -z "$cli_version" ]; then
        print_error "SimpleCloud CLI version check was empty."
        exit 1
    fi

    print_success "Verified SimpleCloud CLI runtime:"
    print_success "$cli_version"
}

rewrite_cli_shebang() {
    cli_file="$1"

    if [ ! -f "$cli_file" ]; then
        return 0
    fi

    first_line=$(head -n 1 "$cli_file" 2>/dev/null || true)
    if [ "$first_line" != "#!/usr/bin/env bun" ]; then
        return 0
    fi

    case "$BUN_EXEC" in
        *" "*)
            print_warning "Skipping shebang rewrite for:"
            print_warning "$cli_file"
            return 0
            ;;
    esac

    temp_file=$(mktemp)
    printf "#!%s\n" "$BUN_EXEC" >"$temp_file"
    tail -n +2 "$cli_file" >>"$temp_file"
    mv "$temp_file" "$cli_file"
    chmod +x "$cli_file"
}

ensure_runtime_shebang() {
    rewrite_cli_shebang "$HOME/.bun/bin/simplecloud"
    rewrite_cli_shebang "$HOME/.bun/bin/sc"
}

install_user_links() {
    user_bin="$HOME/.local/bin"
    mkdir -p "$user_bin"

    if [ -x "$HOME/.bun/bin/simplecloud" ]; then
        ln -sf "$HOME/.bun/bin/simplecloud" "$user_bin/simplecloud"
    fi
    if [ -x "$HOME/.bun/bin/sc" ]; then
        ln -sf "$HOME/.bun/bin/sc" "$user_bin/sc"
    fi
}

link_system_binary() {
    name="$1"
    source_path="$2"
    target="/usr/local/bin/$name"

    if [ ! -x "$source_path" ]; then
        return 1
    fi
    if [ -w "/usr/local/bin" ]; then
        ln -sf "$source_path" "$target"
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        if sudo ln -sf "$source_path" "$target"; then
            return 0
        fi
    fi
    return 1
}

install_system_links() {
    linked_any=0

    if link_system_binary "simplecloud" "$HOME/.bun/bin/simplecloud"; then
        linked_any=1
    fi
    if link_system_binary "sc" "$HOME/.bun/bin/sc"; then
        linked_any=1
    fi

    if [ "$linked_any" -eq 1 ]; then
        print_success "Linked CLI commands into /usr/local/bin"
    else
        print_warning "Could not link into /usr/local/bin."
        print_warning "Added links in ~/.local/bin instead."
    fi
}

append_path_setup() {
    config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 0
    fi
    if grep -q "simplecloud installer path setup" "$config_file"; then
        return 0
    fi

    cat >>"$config_file" <<EOF

# simplecloud installer path setup
export BUN_INSTALL="\$HOME/.bun"
export PATH="\$HOME/.local/bin:\$BUN_INSTALL/bin:\$PATH"
EOF
}

setup_path() {
    export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

    append_path_setup "$HOME/.bashrc"
    append_path_setup "$HOME/.bash_profile"
    append_path_setup "$HOME/.profile"
    append_path_setup "$HOME/.zshrc"
    append_path_setup "$HOME/.zprofile"
}

show_post_install_hint() {
    if command -v simplecloud >/dev/null 2>&1; then
        return 0
    fi
    if command -v sc >/dev/null 2>&1; then
        return 0
    fi

    print_warning "If the shell cannot find simplecloud yet, run:"
    echo "  . ~/.bashrc 2>/dev/null || . ~/.zshrc"
    print_warning "Direct binary path:"
    print_warning "$HOME/.bun/bin/simplecloud"
}

main() {
    setup_ui

    echo ""
    echo "${BLUE}SimpleCloud CLI Installer${NC}"
    echo ""

    os=$(detect_os)
    if [ "$os" = "unsupported" ]; then
        print_error "Unsupported operating system."
        print_error "This script supports Linux and macOS only."
        exit 1
    fi

    print_success "Detected OS: $os"

    if [ "$os" = "linux" ]; then
        pkg_manager=$(detect_package_manager)
        print_success "Detected package manager: $pkg_manager"
        install_unzip "$pkg_manager"
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
    echo "Run ${GREEN}simplecloud${NC} or ${GREEN}sc${NC}."
    show_post_install_hint
    echo ""
}

main "$@" || exit 1
