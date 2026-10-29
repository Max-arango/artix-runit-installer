#!/usr/bin/env bash
# Stage 2: graphical environment and development tools for Artix + runit.
set -Eeuo pipefail
IFS=$'\n\t'
trap 'rc=$?; echo "\nERROR on line ${LINENO} (exit ${rc}). No partitions were changed by this stage." >&2; exit "$rc"' ERR

log(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn(){ printf '\nWARNING: %s\n' "$*" >&2; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die 'Run this as your normal user, not as root.'
[[ -e /etc/artix-release ]] || grep -qi 'artix' /etc/os-release 2>/dev/null || die 'This does not look like an Artix installation.'
command -v sudo >/dev/null || die 'sudo is missing.'
command -v pacman >/dev/null || die 'pacman is missing.'
[[ -e /dev/tty ]] || die 'An interactive terminal is required.'
exec 3<>/dev/tty
ask(){ local __var="$1"; local __prompt="$2"; read -r -p "$__prompt" "$__var" <&3; }
confirm(){ local answer; ask answer "$1 [y/N]: "; [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; }

sudo -v
log 'Artix desktop / Caelestia preparation'
echo 'This stage will not repartition or format any disk.'
echo 'Package availability varies between Artix repositories; unavailable optional packages will be skipped.'
if confirm 'Run a full system update first?'; then
  sudo pacman -Syu
else
  warn 'Skipping full update. Package installations may fail if the system is out of date.'
fi

pkg_exists(){ pacman -Si "$1" >/dev/null 2>&1; }
install_optional(){
  local requested=() available=() package
  requested=("$@")
  for package in "${requested[@]}"; do
    if pkg_exists "$package"; then
      available+=("$package")
    else
      warn "Package not available in enabled repositories; skipped: $package"
    fi
  done
  if ((${#available[@]})); then
    sudo pacman -S --needed "${available[@]}"
  fi
}
require_package(){
  local package
  for package in "$@"; do
    pkg_exists "$package" || die "Required package is not available in the enabled Artix repositories: $package. Check /etc/pacman.conf and mirrors before continuing."
  done
  sudo pacman -S --needed "$@"
}

log 'Install the minimum Hyprland session'
require_package hyprland xorg-xwayland
install_optional \
  xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
  polkit elogind dbus \
  pipewire pipewire-alsa pipewire-pulse wireplumber \
  qt5-wayland qt6-wayland \
  mesa vulkan-icd-loader vulkan-radeon \
  foot kitty fish starship fastfetch \
  grim slurp wl-clipboard cliphist fuzzel swappy libnotify \
  ffmpeg glib2 dart-sass gpu-screen-recorder \
  ddcutil libcava lm_sensors aubio libpipewire libqalculate power-profiles-daemon swappy \
  papirus-icon-theme ttf-jetbrains-mono-nerd ttf-material-symbols-variable ttf-rubik-vf ttf-cascadia-code-nerd noto-fonts noto-fonts-emoji \
  xdg-utils xdg-user-dirs pavucontrol brightnessctl playerctl \
  firefox chromium libreoffice-fresh

log 'Enable/verify the core runit services'
for service in dbus elogind NetworkManager; do
  service_path=''
  for candidate in "/etc/runit/sv/$service" "/etc/runit/sv/${service,,}"; do
    if [[ -d "$candidate" ]]; then service_path="$candidate"; break; fi
  done
  if [[ -n "$service_path" ]]; then
    sudo mkdir -p /etc/runit/runsvdir/default
    sudo ln -sfn "$service_path" "/etc/runit/runsvdir/default/$(basename "$service_path")"
    printf 'Enabled runit service: %s\n' "$(basename "$service_path")"
  else
    warn "No runit service directory found for $service; verify its Artix -runit package."
  fi
done

log 'Install development and cybersecurity tools'
install_optional \
  git github-cli base-devel cmake ninja meson gcc clang lldb gdb make \
  python python-pip python-virtualenv python-build python-installer \
  python-hatchling python-hatch-vcs python-pillow python-materialyoucolor \
  nodejs npm pnpm go rust cargo \
  nmap tcpdump wireshark-qt bind whois traceroute mtr socat openbsd-netcat \
  openssh rsync curl wget jq yq unzip zip p7zip tmux htop btop ripgrep fd \
  shellcheck shfmt strace ltrace radare2 ghex hexedit

log 'NVIDIA RTX 3050 driver (optional)'
if confirm 'Attempt installation of an NVIDIA DKMS driver and Vulkan libraries?'; then
  driver=''
  if pkg_exists nvidia-open-dkms; then
    driver=nvidia-open-dkms
  elif pkg_exists nvidia-dkms; then
    driver=nvidia-dkms
  elif pkg_exists nvidia; then
    driver=nvidia
    warn 'Using the repository nvidia package rather than a DKMS package. Confirm that it matches the installed kernel.'
  else
    warn 'No NVIDIA driver candidate was found in enabled repositories. Skipping the driver rather than guessing.'
  fi
  if [[ -n "$driver" ]]; then
    if [[ "$driver" == *dkms ]] && ! pkg_exists linux-headers; then
      warn 'DKMS driver found, but linux-headers is unavailable; skipping to avoid an unusable kernel module.'
      driver=''
    fi
  fi
  if [[ -n "$driver" ]]; then
    driver_pkgs=("$driver")
    if pkg_exists linux-headers; then driver_pkgs+=(linux-headers); else warn 'linux-headers unavailable; the installed driver may not build for the current kernel.'; fi
    if pkg_exists nvidia-utils; then driver_pkgs+=(nvidia-utils); else die 'The driver candidate exists but nvidia-utils is unavailable.'; fi
    if pkg_exists vulkan-icd-loader; then driver_pkgs+=(vulkan-icd-loader); fi
    # 32-bit libraries are needed for many Steam games; install them only if present.
    for package in lib32-nvidia-utils lib32-vulkan-icd-loader; do
      if pkg_exists "$package"; then driver_pkgs+=("$package"); fi
    done
    sudo pacman -S --needed "${driver_pkgs[@]}"
    if [[ -f /etc/default/grub ]] && grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
      if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*nvidia_drm.modeset=1' /etc/default/grub; then
        sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/s/"$/ nvidia_drm.modeset=1"/' /etc/default/grub
      fi
      sudo grub-mkconfig -o /boot/grub/grub.cfg
    else
      warn 'Could not find GRUB defaults; add nvidia_drm.modeset=1 manually if required by your driver.'
    fi
    if command -v mkinitcpio >/dev/null 2>&1; then
      sudo mkinitcpio -P
    fi
    echo 'NVIDIA packages installed. Reboot before judging Hyprland rendering.'
  fi
else
  echo 'Skipped NVIDIA driver installation.'
fi

log 'Steam/Proton (optional)'
if confirm 'Prepare the Artix lib32 repository and install Steam if available?'; then
  if grep -Eq '^[[:space:]]*#?\[lib32\][[:space:]]*$' /etc/pacman.conf; then
    tmp_conf="$(mktemp)"
    awk '
      /^[[:space:]]*#?\[lib32\][[:space:]]*$/ { sub(/^[[:space:]]*#/, ""); in_lib32=1; print; next }
      /^[[:space:]]*\[/ { in_lib32=0 }
      in_lib32 && /^[[:space:]]*#Include[[:space:]]*=/ { sub(/#/, "") }
      { print }
    ' /etc/pacman.conf > "$tmp_conf"
    sudo cp -n /etc/pacman.conf "/etc/pacman.conf.artix-installer-backup.$(date +%Y%m%d%H%M%S)"
    sudo install -o root -g root -m 0644 "$tmp_conf" /etc/pacman.conf
    rm -f "$tmp_conf"
  else
    warn 'No [lib32] repository block found in /etc/pacman.conf; Steam might not be available.'
  fi
  sudo pacman -Syu
  if pkg_exists steam; then
    install_optional steam lib32-nvidia-utils lib32-vulkan-icd-loader lib32-mesa lib32-pipewire lib32-libpulse
  else
    warn 'Native Steam package unavailable. Will offer its official Flathub package below if Flatpak is available.'
  fi
  if pkg_exists flatpak; then
    if confirm 'Install Steam from Flathub if native Steam was unavailable?'; then
      sudo pacman -S --needed flatpak
      flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
      flatpak --user install flathub com.valvesoftware.Steam
    fi
  fi
else
  echo 'Skipped Steam.'
fi

log 'Sober (Roblox, optional)'
echo 'Sober is an unofficial, experimental, closed-source project; Roblox does not support it.'
if confirm 'Install Sober from its Flathub package?'; then
  if ! command -v flatpak >/dev/null 2>&1; then
    pkg_exists flatpak || die 'Flatpak is not available in the enabled repositories.'
    sudo pacman -S --needed flatpak
  fi
  flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak --user install flathub org.vinegarhq.Sober
fi

log 'Caelestia (best-effort Artix/runit adaptation)'
echo 'Upstream documents Arch/AUR packaging, not official Artix/runit support.'
echo 'The graphical shell needs the CLI, Quickshell Git, and qt6-m3shapes-git; these may fail to build on Artix.'
if confirm 'Attempt Caelestia CLI + graphical shell through the upstream AUR packages?'; then
  install_optional git go base-devel cmake ninja qt6-shadertools qt6-base qt6-declarative qt6-imageformats qt6-multimedia
  if ! command -v makepkg >/dev/null 2>&1; then
    warn 'makepkg is missing. Skipping Caelestia AUR packages; the rest of the system setup can continue.'
  elif ! command -v yay >/dev/null 2>&1; then
    if ! pkg_exists go; then
      warn 'Go is unavailable in enabled repositories; cannot bootstrap yay, so Caelestia AUR packages are skipped.'
    else
      mkdir -p "$HOME/.cache"
      yay_work="$(mktemp -d "$HOME/.cache/yay-bootstrap.XXXXXX")"
      if git clone https://aur.archlinux.org/yay.git "$yay_work/yay"; then
        echo 'Review the AUR helper build recipe before executing it:'
        echo "  $yay_work/yay/PKGBUILD"
        if command -v less >/dev/null 2>&1; then less "$yay_work/yay/PKGBUILD"; else cat "$yay_work/yay/PKGBUILD"; fi
        reviewed=''
        ask reviewed 'Type REVIEWED YAY PKGBUILD to build/install yay: '
        if [[ "$reviewed" == 'REVIEWED YAY PKGBUILD' ]]; then
          if (cd "$yay_work/yay" && makepkg -si); then
            echo 'yay helper installed.'
          else
            warn 'Building/installing yay failed; skipping Caelestia AUR packages.'
          fi
        else
          warn 'AUR helper build cancelled; no AUR packages were installed.'
        fi
      else
        warn 'Could not clone yay from AUR; skipping Caelestia AUR packages.'
      fi
    fi
  fi

  if command -v yay >/dev/null 2>&1; then
    echo 'Next, yay will fetch package build recipes and dependencies. Read its package/diff prompts.'
    if yay -S --needed caelestia-cli caelestia-shell; then
      if command -v caelestia >/dev/null 2>&1; then
        if confirm 'Back up existing Caelestia-related configs and run `caelestia install`?'; then
          backup="$HOME/.local/state/artix-installer-backups/$(date +%Y%m%d-%H%M%S)"
          mkdir -p "$backup"
          for item in hypr caelestia fish foot fuzzel quickshell; do
            if [[ -e "$HOME/.config/$item" ]]; then cp -a "$HOME/.config/$item" "$backup/"; fi
          done
          echo "Config backup (if configs existed): $backup"
          caelestia install || warn 'The dotfiles installer failed. Review the output and Artix/runit-specific compatibility before retrying.'
        else
          echo 'Caelestia packages installed; dotfiles not applied. Run `caelestia install` when ready.'
        fi
      else
        warn 'AUR installation returned success, but `caelestia` was not found in PATH.'
      fi
    else
      warn 'Caelestia AUR package installation failed. This is a known compatibility boundary, not a disk-install failure. See the manual build instructions: https://github.com/caelestia-dots/shell#manual-installation'
    fi
  else
    warn 'yay is not installed; skipped the Caelestia AUR packages.'
  fi
else
  echo 'Skipped Caelestia CLI/shell. You can attempt the manual installation later.'
fi

log 'Finish'
mkdir -p "$HOME/.local/bin" "$HOME/.config/fish"
if [[ ! -f "$HOME/.config/hypr/hyprland.conf" ]]; then
  mkdir -p "$HOME/.config/hypr"
  cat > "$HOME/.config/hypr/hyprland.conf" <<'HYPR_FALLBACK'
# Minimal fallback for Artix + runit. Caelestia may replace this after `caelestia install`.
$mainMod = SUPER
$terminal = foot
$menu = fuzzel
monitor = , preferred, auto, 1
exec-once = pipewire
exec-once = wireplumber
exec-once = pipewire-pulse
bind = $mainMod, RETURN, exec, $terminal
bind = $mainMod, SPACE, exec, $menu
bind = $mainMod, Q, killactive
bind = $mainMod SHIFT, E, exit
HYPR_FALLBACK
fi
if command -v fish >/dev/null 2>&1; then
  if ! grep -q 'fish_add_path.*\.local/bin' "$HOME/.config/fish/config.fish" 2>/dev/null; then
    printf '\n# Local user scripts\nfish_add_path -g "$HOME/.local/bin"\n' >> "$HOME/.config/fish/config.fish"
  fi
fi
cat <<'DONE'

Post-install stage finished (except for options you skipped or packages unavailable in Artix repositories).

Next steps:
  1. Reboot.
  2. Log in on a TTY and launch: dbus-run-session Hyprland
  3. Check NVIDIA with: nvidia-smi; and `cat /sys/module/nvidia_drm/parameters/modeset`
  4. If the Caelestia AUR route failed, follow its manual build documentation. Its upstream package recipes target Arch, so inspect failures rather than forcing systemd dependencies into Artix.

No systemd units were enabled by this script; services are managed via runit.
DONE
