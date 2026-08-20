#!/usr/bin/env bash
# Installs the `dwatts` alias into your shell profile.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SCRIPT="${ROOT_DIR}/bin/delta_watts"
MARKER_START="# >>> delta_watts >>>"
MARKER_END="# <<< delta_watts <<<"

usage() {
  cat <<EOF
Usage: ./install.sh [options]

Installs a \`dwatts\` alias that launches the delta_watts TUI.

Options:
  -h, --help       Show this help
  -u, --uninstall  Remove the alias from your shell profile
EOF
}

log() {
  printf 'delta_watts: %s\n' "$*"
}

die() {
  printf 'delta_watts: error: %s\n' "$*" >&2
  exit 1
}

find_ruby() {
  local candidate version

  for candidate in \
    /opt/homebrew/bin/ruby \
    /usr/local/bin/ruby \
    "$(command -v ruby 2>/dev/null || true)"
  do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    version="$("$candidate" -e 'print RUBY_VERSION.split(".").first(2).join(".")' 2>/dev/null || true)"
    if [[ -n "$version" ]] && "$candidate" -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0.0") ? 0 : 1)' 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

detect_shell_name() {
  local shell_path="${SHELL:-}"
  if [[ -z "$shell_path" ]]; then
    shell_path="$(ps -p $$ -o comm= 2>/dev/null | tr -d ' ')"
  fi
  basename "$shell_path"
}

profile_for_shell() {
  local shell_name="$1"

  case "$shell_name" in
    zsh)
      printf '%s\n' "${HOME}/.zshrc"
      ;;
    bash)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        if [[ -f "${HOME}/.bash_profile" ]]; then
          printf '%s\n' "${HOME}/.bash_profile"
        else
          printf '%s\n' "${HOME}/.bash_profile"
        fi
      elif [[ -f "${HOME}/.bashrc" ]]; then
        printf '%s\n' "${HOME}/.bashrc"
      else
        printf '%s\n' "${HOME}/.bashrc"
      fi
      ;;
    fish)
      printf '%s\n' "${HOME}/.config/fish/config.fish"
      ;;
    sh|ksh|dash)
      printf '%s\n' "${HOME}/.profile"
      ;;
    *)
      return 1
      ;;
  esac
}

alias_block() {
  local shell_name="$1"
  local ruby_path="$2"

  case "$shell_name" in
    fish)
      cat <<EOF
${MARKER_START}
alias dwatts ${ruby_path} ${BIN_SCRIPT}
${MARKER_END}
EOF
      ;;
    *)
      cat <<EOF
${MARKER_START}
alias dwatts='${ruby_path} ${BIN_SCRIPT}'
${MARKER_END}
EOF
      ;;
  esac
}

remove_block() {
  local profile="$1"
  local tmp

  [[ -f "$profile" ]] || return 0

  tmp="$(mktemp)"
  awk "
    /^${MARKER_START//\//\\/}\$/ { skip=1; next }
    /^${MARKER_END//\//\\/}\$/ { skip=0; next }
    skip == 0 { print }
  " "$profile" > "$tmp"
  mv "$tmp" "$profile"
}

install_block() {
  local profile="$1"
  local shell_name="$2"
  local ruby_path="$3"
  local block

  mkdir -p "$(dirname "$profile")"
  touch "$profile"

  remove_block "$profile"
  block="$(alias_block "$shell_name" "$ruby_path")"
  printf '\n%s\n' "$block" >> "$profile"
}

uninstall() {
  local shell_name profile

  shell_name="$(detect_shell_name)"
  profile="$(profile_for_shell "$shell_name")" || die "unsupported shell: ${shell_name}"

  remove_block "$profile"
  log "removed dwatts alias from ${profile}"
  log "restart your shell or run: source ${profile}"
}

build_sampler() {
  local src="${ROOT_DIR}/ext/power_sampler.c"
  local bin="${ROOT_DIR}/libexec/power_sampler"

  mkdir -p "${ROOT_DIR}/libexec"
  if [[ -x "$bin" && "$bin" -nt "$src" ]]; then
    return 0
  fi

  cc -O2 -o "$bin" "$src" \
    -framework IOKit -framework CoreFoundation -lIOReport \
    || die "failed to build power sampler (install Xcode Command Line Tools)"

  log "built ${bin}"
}

install() {
  local shell_name profile ruby_path

  [[ -x "$BIN_SCRIPT" ]] || die "missing executable: ${BIN_SCRIPT}"

  ruby_path="$(find_ruby)" || die "Ruby 3.0+ is required (brew install ruby)"

  build_sampler

  shell_name="$(detect_shell_name)"
  profile="$(profile_for_shell "$shell_name")" || die "unsupported shell: ${shell_name} (supported: zsh, bash, fish)"

  install_block "$profile" "$shell_name" "$ruby_path"

  log "installed dwatts alias in ${profile}"
  log "using ruby: ${ruby_path}"
  log "restart your shell or run: source ${profile}"
  log "then run: dwatts"
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      ;;
    -u|--uninstall)
      uninstall
      ;;
    "")
      install
      ;;
    *)
      usage
      die "unknown option: $1"
      ;;
  esac
}

main "$@"
