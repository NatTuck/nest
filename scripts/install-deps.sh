#!/usr/bin/env bash
#
# scripts/install-deps.sh
#
# Install the *system* dependencies Nest needs in order to build and run on
# this machine:
#
#   * the system prerequisites for building Erlang/OTP 27 from source, which
#     is what `mise install` does for `erlang 27.3.4.6` (see .tool-versions),
#   * Postgres (server + client) plus a login role for the current user --
#     config/test.exs uses `System.fetch_env!("USER")` as the role and a
#     socket in /var/run/postgresql,
#   * bubblewrap, which the sandbox runs every tool call through, working --
#     not merely installed (see `ensure_bwrap`),
#   * git, curl, ca-certificates, ripgrep and the rest of the tooling the
#     repo's own scripts assume.
#
# The language runtimes themselves (nodejs, erlang, elixir, pnpm) come from
# mise; this script installs the system side only. If mise is missing we say
# so at the end rather than installing a version manager behind your back.
#
# Supported targets
# -----------------
#
#   Ubuntu 24.04 LTS   ID=ubuntu     VERSION_ID=24.04
#   Ubuntu 26.04       ID=ubuntu     VERSION_ID=26.04
#   Linux Mint 22.x    ID=linuxmint  UBUNTU_CODENAME=noble
#   Debian 13          ID=debian     VERSION_CODENAME=trixie
#
# Anything else is refused before the first package is touched: a
# half-installed host is worse than an un-installed one. Mint is branched on
# UBUNTU_CODENAME because its own VERSION_ID (22.x) says nothing about which
# Ubuntu release it is built on.
#
# Usage
# -----
#
#   sudo bash scripts/install-deps.sh
#   sudo bash scripts/install-deps.sh --dry-run
#   bash scripts/install-deps.sh --os-release FILE --dry-run
#
# `--dry-run` prints exactly what would happen and changes nothing. It is
# also the way to exercise the distro detection against a synthetic
# os-release file (`--os-release`), which is useful on a host that is not one
# of the four targets.
#
# Re-running
# ----------
#
# The script is idempotent. Every step reports what it is doing, and a step
# that is already satisfied is reported as skipped. A second run on a
# provisioned host installs nothing and exits 0.
#
# Reboots
# -------
#
# None needed. The only kernel setting we may touch,
# kernel.apparmor_restrict_unprivileged_userns, is applied with `sysctl -w`
# (live for this boot) *and* written to /etc/sysctl.d (live for the next one),
# so `bwrap` starts working immediately.

set -euo pipefail

# Never prompt. The script is meant to run unattended, including from CI.
export DEBIAN_FRONTEND=noninteractive

PROG=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PG_SOCKET_DIR=${PG_SOCKET_DIR:-/var/run/postgresql}

DRY_RUN=0
OS_RELEASE_FILE=/etc/os-release

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
skip() { printf '    ok, already done: %s\n' "$*"; }

# Print a labelled, wrapped list (used for the package report).
print_list() {
  local label=$1
  shift
  printf '    %s:\n' "$label"
  printf '%s\n' "$*" | fold -s -w 74 | sed 's/^/      /'
}

# Echo a command the way the user would have to type it.
show_cmd() {
  printf '    $'
  printf ' %q' "$@"
  printf '\n'
}

die() {
  printf '\n%s: error: %s\n' "$PROG" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install-deps.sh [--dry-run] [--os-release FILE]

  --dry-run            print what would be done; change nothing
  --os-release FILE    read the distro from FILE instead of /etc/os-release
                       (for testing the detection against synthetic data)
  -h, --help           this message
EOF
}

require_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  die "$1 needs root: re-run with sudo (e.g. sudo bash $0)"
}

# ---------------------------------------------------------------------------
# Package sets
# ---------------------------------------------------------------------------

# Ubuntu 24.04 LTS (noble). Ubuntu 26.04 and Linux Mint 22.x use this set too;
# see detect_distro.
PKGS_NOBLE=(
  # Erlang/OTP 27 build prerequisites, checked against OTP 27.3.4.6's own
  # configure scripts rather than against folklore:
  #   * erts/configure.ac:1218-1235 hard-errors with "No curses library
  #     functions found" without a termcap library  -> libncurses-dev;
  #   * erts/configure.ac:1785-1807 hard-errors with "sctp support requested,
  #     but cannot be enabled since 'netinet/sctp.h' is missing", and
  #     --enable-sctp is the *default*, so libsctp-dev is required, not
  #     optional;
  #   * erts/configure.ac:1275 errors on zlib older than 1.2.5 -> zlib1g-dev;
  #   * OpenSSL is what crypto (and so ssl and ssh) needs -> libssl-dev.
  # libssh-dev, libyaml-dev, libgmp-dev, libxml2-utils and xsltproc are *not*
  # referenced by OTP 27's configure anywhere (lib/ssh is pure Erlang, with no
  # configure of its own). They are in asdf-erlang's and kerl's canonical
  # Ubuntu list, they are small, and the XML toolchain is what the OTP and
  # `mix docs` doc builds use, so they stay: this is the set the ecosystem
  # builds OTP with, and being one package short of a build is worse than
  # carrying a spare.
  # wxWidgets, the JDK, ODBC and `fop` are deliberately left out: a headless
  # build skips the wx, jinterface and odbc applications, and the docs are
  # built by `mix docs`, not by the OTP build.
  build-essential autoconf m4
  libncurses-dev libssl-dev libssh-dev libsctp-dev
  libyaml-dev libgmp-dev zlib1g-dev
  libxml2-utils xsltproc
  # What the repo's own scripts and the sandbox need.
  git curl ca-certificates unzip
  ripgrep
  bubblewrap
  # Postgres. `postgresql` is a metapackage: pkg_needed() accepts any
  # installed server instead, so a host with postgresql-16 already is fine.
  # `citext` (used by the users migration) ships inside the server package on
  # both Ubuntu 24.04 and Debian 13, so no -contrib is needed.
  postgresql postgresql-client
)

# Debian 13 (trixie) needs exactly the same set today. It is kept as its own
# list so a future divergence (a renamed or split package) has an obvious
# home, and so the archive contents are checked per distro.
PKGS_TRIXIE=("${PKGS_NOBLE[@]}")

PKGS=()

# ---------------------------------------------------------------------------
# Distro detection
# ---------------------------------------------------------------------------

# Read one KEY=VALUE out of an os-release file *without* sourcing it: the file
# is data, and --os-release lets a test point us at synthetic data, so we
# never execute it.
os_release_value() {
  local key=$1
  local line
  line=$(grep -m1 "^${key}=" "$OS_RELEASE_FILE" 2>/dev/null || true)
  line=${line#*=}
  line=${line%\"}
  line=${line#\"}
  printf '%s' "$line"
}

detect_distro() {
  [ -r "$OS_RELEASE_FILE" ] || die "cannot read $OS_RELEASE_FILE"

  DISTRO_ID=$(os_release_value ID)
  DISTRO_VERSION_ID=$(os_release_value VERSION_ID)
  DISTRO_CODENAME=$(os_release_value VERSION_CODENAME)
  DISTRO_UBUNTU_CODENAME=$(os_release_value UBUNTU_CODENAME)
  DISTRO_PRETTY=$(os_release_value PRETTY_NAME)

  case "$DISTRO_ID" in
    ubuntu)
      case "$DISTRO_VERSION_ID" in
        24.04)
          # Branch on the codename as well as the ID: a renamed or re-based
          # Ubuntu would land here with a codename we do not know.
          case "${DISTRO_UBUNTU_CODENAME:-$DISTRO_CODENAME}" in
            noble) ;;
            "") note "no codename in $OS_RELEASE_FILE; trusting VERSION_ID=24.04" ;;
            *) die "unsupported Ubuntu codename: ${DISTRO_UBUNTU_CODENAME:-$DISTRO_CODENAME} (expected noble)" ;;
          esac
          ;;
        26.04)
          # Ubuntu 26.04 does not exist yet, so there is nothing to check its
          # package names against. We assume the 24.04 (noble) set is still
          # right and say so; when 26.04 ships, re-check libssh-dev,
          # libsctp-dev and libncurses-dev against the archive and split
          # PKGS_NOBLE if they have moved. Any codename is accepted here
          # because we cannot know 26.04's yet.
          note "Ubuntu 26.04 is not released yet: assuming the 24.04 (noble) package set"
          ;;
        *)
          die "unsupported Ubuntu release: ${DISTRO_VERSION_ID:-unknown} (supported: 24.04, 26.04)"
          ;;
      esac
      PKGS=("${PKGS_NOBLE[@]}")
      DISTRO_SET=noble
      ;;
    linuxmint)
      # Mint 22.x is Ubuntu 24.04 underneath; VERSION_ID is Mint's own 22.x,
      # so UBUNTU_CODENAME is the only thing that identifies the base.
      case "$DISTRO_UBUNTU_CODENAME" in
        noble) ;;
        "") die "Linux Mint with no UBUNTU_CODENAME: cannot tell which Ubuntu release this is" ;;
        *) die "unsupported Linux Mint base: $DISTRO_UBUNTU_CODENAME (supported: Mint 22.x, i.e. noble)" ;;
      esac
      PKGS=("${PKGS_NOBLE[@]}")
      DISTRO_SET=noble
      ;;
    debian)
      case "$DISTRO_CODENAME" in
        trixie) ;;
        *) die "unsupported Debian release: ${DISTRO_VERSION_ID:-unknown} (${DISTRO_CODENAME:-unknown}); supported: 13/trixie" ;;
      esac
      PKGS=("${PKGS_TRIXIE[@]}")
      DISTRO_SET=trixie
      ;;
    *)
      die "unsupported distribution: ID=${DISTRO_ID:-unknown} (${DISTRO_PRETTY:-no PRETTY_NAME}). Supported: Ubuntu 24.04/26.04, Linux Mint 22.x, Debian 13/trixie."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

dpkg_installed() {
  local status
  status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
  [ "$status" = "install ok installed" ]
}

postgres_server_present() {
  local bindir
  command -v pg_config >/dev/null 2>&1 || return 1
  bindir=$(pg_config --bindir 2>/dev/null) || return 1
  [ -x "$bindir/postgres" ]
}

# Is this package genuinely absent? A couple of the names we install are
# metapackages, and a host that installed the real thing directly is just as
# provisioned as one that went through the metapackage.
pkg_needed() {
  case "$1" in
    postgresql)
      ! postgres_server_present
      ;;
    postgresql-client)
      ! command -v psql >/dev/null 2>&1
      ;;
    *)
      ! dpkg_installed "$1"
      ;;
  esac
}

install_packages() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    show_cmd apt-get update
    show_cmd apt-get install -y "$@"
    return 0
  fi

  require_root "installing packages"
  show_cmd apt-get update
  apt-get update
  show_cmd apt-get install -y "$@"
  apt-get install -y "$@"
}

# ---------------------------------------------------------------------------
# Postgres
# ---------------------------------------------------------------------------

postgres_running() {
  command -v pg_isready >/dev/null 2>&1 || return 1
  pg_isready -q -h "$PG_SOCKET_DIR" >/dev/null 2>&1
}

ensure_postgres_running() {
  if postgres_running; then
    skip "Postgres is accepting connections on $PG_SOCKET_DIR"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    note "would start the Postgres cluster (systemctl, or pg_ctlcluster without systemd)"
    return 0
  fi

  require_root "starting Postgres"
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    show_cmd systemctl enable --now postgresql
    systemctl enable --now postgresql
  elif command -v pg_ctlcluster >/dev/null 2>&1; then
    # No systemd (a container, or a host that boots some other way): start
    # the first cluster directly. `pg_lsclusters -h` prints one line per
    # cluster, "Ver Cluster Port Status Owner Data directory Log file".
    local version
    version=$(pg_lsclusters -h | awk 'NR == 1 { print $1 }')
    [ -n "$version" ] || die "no Postgres cluster exists yet; is the postgresql package installed?"
    show_cmd pg_ctlcluster "$version" main start
    pg_ctlcluster "$version" main start
  else
    die "Postgres is not running and neither systemctl nor pg_ctlcluster is available"
  fi

  postgres_running || die "Postgres still is not accepting connections on $PG_SOCKET_DIR"
}

# The role config/test.exs logs in as: `System.fetch_env!("USER")`. Under
# sudo that is `root`, so prefer SUDO_USER, which is the human who invoked it.
target_db_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    printf '%s' "$SUDO_USER"
  elif [ -n "${USER:-}" ]; then
    printf '%s' "$USER"
  else
    id -un
  fi
}

# Peer authentication means only the `postgres` OS account can act as the
# postgres superuser. `su` rather than `sudo`: sudo is not in every minimal
# container, and we only need to *be* that user.
run_as_postgres() {
  if [ "$(id -un)" = "postgres" ]; then
    "$@"
  elif [ "$(id -u)" -eq 0 ]; then
    su -s /bin/sh postgres -c "$(printf '%q ' "$@")"
  else
    die "creating the Postgres role for $(target_db_user) needs root: re-run with sudo"
  fi
}

role_can_log_in() {
  local user=$1
  if [ "$(id -un)" = "$user" ]; then
    psql -h "$PG_SOCKET_DIR" -U "$user" -d postgres -c 'select 1' >/dev/null 2>&1
  elif [ "$(id -u)" -eq 0 ]; then
    su -s /bin/sh "$user" -c "psql -h $PG_SOCKET_DIR -U $user -d postgres -c 'select 1'" >/dev/null 2>&1
  else
    return 1
  fi
}

ensure_postgres_role() {
  local user
  user=$(target_db_user)

  if role_can_log_in "$user"; then
    skip "Postgres role \"$user\" can log in"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    note "would create Postgres role \"$user\" (LOGIN CREATEDB)"
    return 0
  fi

  require_root "creating the Postgres role for \"$user\""
  note "creating Postgres role \"$user\" (LOGIN CREATEDB)"

  # \gexec turns the SELECT's output into the command to run, so this is a
  # no-op when the role already exists -- and %I quotes the identifier, so no
  # shell or SQL quoting of $user is needed here.
  run_as_postgres psql -q -X -d postgres -v ON_ERROR_STOP=1 -v "u=$user" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN CREATEDB', :'u')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'u')
\gexec
SQL

  if role_can_log_in "$user"; then
    note "role \"$user\" created and able to log in"
  else
    die "Postgres role \"$user\" exists but cannot log in; check pg_hba.conf peer auth for $PG_SOCKET_DIR"
  fi
}

# ---------------------------------------------------------------------------
# bubblewrap
# ---------------------------------------------------------------------------

# The exact flag set Nest's sandbox builds (lib/nest/sandbox.ex:base_args/2),
# running a real command *inside* the sandbox. `bwrap --version` is not a test
# of anything: it succeeds on hosts where every sandbox fails.
bwrap_works() {
  local out
  command -v bwrap >/dev/null 2>&1 || return 1
  out=$(bwrap --unshare-all --die-with-parent --new-session \
    --ro-bind / / --dev /dev --proc /proc \
    /bin/sh -c 'echo nest-bwrap-probe-ok' 2>&1) || return 1
  [ "$out" = "nest-bwrap-probe-ok" ]
}

ensure_bwrap() {
  if bwrap_works; then
    skip "bubblewrap starts a sandbox ($(bwrap --version))"
    return 0
  fi

  note "bwrap is installed but cannot start a sandbox; diagnosing"

  local apparmor_sysctl=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  local clone_sysctl=/proc/sys/kernel/unprivileged_userns_clone

  # Ubuntu 23.10+ (and therefore Linux Mint 22) ships
  # kernel.apparmor_restrict_unprivileged_userns=1, which blocks
  # clone(CLONE_NEWUSER) for unprivileged users. bwrap then fails with
  #   bwrap: setting up uid map: Permission denied
  # even though the binary and the kernel are both fine. scripts/fix-apparmor.sh
  # exists for exactly this and does the whole job (live `sysctl -w` plus a
  # persistent /etc/sysctl.d drop-in), so we call it instead of duplicating it.
  if [ -r "$apparmor_sysctl" ] && [ "$(cat "$apparmor_sysctl")" != "0" ]; then
    note "kernel.apparmor_restrict_unprivileged_userns=$(cat "$apparmor_sysctl") blocks unprivileged user namespaces"
    [ -r "$SCRIPT_DIR/fix-apparmor.sh" ] || die "expected $SCRIPT_DIR/fix-apparmor.sh to exist"
    if [ "$DRY_RUN" -eq 1 ]; then
      show_cmd bash "$SCRIPT_DIR/fix-apparmor.sh"
      return 0
    fi
    require_root "disabling the AppArmor user-namespace restriction"
    show_cmd bash "$SCRIPT_DIR/fix-apparmor.sh"
    bash "$SCRIPT_DIR/fix-apparmor.sh"
  elif [ -r "$clone_sysctl" ] && [ "$(cat "$clone_sysctl")" = "0" ]; then
    # Older kernels (Debian 11 and earlier, and some Ubuntu kernels) gate
    # unprivileged user namespaces behind this sysctl instead.
    note "kernel.unprivileged_userns_clone=0 blocks unprivileged user namespaces"
    if [ "$DRY_RUN" -eq 1 ]; then
      show_cmd sysctl -w kernel.unprivileged_userns_clone=1
      return 0
    fi
    require_root "enabling unprivileged user namespaces"
    show_cmd sysctl -w kernel.unprivileged_userns_clone=1
    sysctl -w kernel.unprivileged_userns_clone=1
    printf '%s\n' 'kernel.unprivileged_userns_clone = 1' \
      >/etc/sysctl.d/99-nest-userns-clone.conf
  else
    note "no AppArmor or unprivileged_userns_clone restriction found"
  fi

  if bwrap_works; then
    note "bubblewrap works now; the change is live, no reboot needed"
    return 0
  fi

  die "bwrap still cannot start a sandbox. Check for a seccomp policy that blocks CLONE_NEWUSER (some container runtimes do), and run scripts/probe-bwrap-flags.sh for details."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run | -n)
        DRY_RUN=1
        ;;
      --os-release)
        [ "$#" -ge 2 ] || die "--os-release needs a file argument"
        OS_RELEASE_FILE=$2
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  step "distribution"
  detect_distro
  say "    ${DISTRO_PRETTY:-$DISTRO_ID} (ID=$DISTRO_ID, VERSION_ID=${DISTRO_VERSION_ID:-unknown}, codename=${DISTRO_UBUNTU_CODENAME:-${DISTRO_CODENAME:-unknown}})"
  say "    using the $DISTRO_SET package set"

  step "packages"
  local -a missing=()
  local -a present=()
  local pkg
  for pkg in "${PKGS[@]}"; do
    if pkg_needed "$pkg"; then
      missing+=("$pkg")
    else
      present+=("$pkg")
    fi
  done

  if [ "${#present[@]}" -gt 0 ]; then
    print_list "already installed (${#present[@]})" "${present[@]}"
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    note "nothing to install"
  else
    print_list "to install (${#missing[@]})" "${missing[@]}"
    install_packages "${missing[@]}"
  fi

  step "postgres"
  ensure_postgres_running
  ensure_postgres_role

  step "bubblewrap"
  ensure_bwrap

  step "summary"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "    dry run: nothing on this host was changed."
  else
    say "    system dependencies are in place."
  fi
  if ! command -v mise >/dev/null 2>&1; then
    say "    note: mise is not on PATH, and the runtimes in .tool-versions come"
    say "          from it. Install it with \`curl https://mise.run | sh\`."
  fi
  say "    next: mise install && mix setup"
  say "    no reboot is required."
}

main "$@"
