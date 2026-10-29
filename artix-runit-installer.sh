#!/usr/bin/env bash
# Artix Linux Base + runit installer for a dedicated SSD, with optional separate /data HDD.
# DESTRUCTIVE: the selected system disk is erased after two explicit confirmations.
set -Eeuo pipefail
IFS=$'\n\t'

LOG="/tmp/artix-runit-installer-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; printf "\nERROR at line %s (exit %s). Log: %s\n" "$LINENO" "$rc" "$LOG" >&2; exit "$rc"' ERR

log(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn(){ printf '\nWARNING: %s\n' "$*" >&2; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }

MODE="${1:-install}"
if [[ "$MODE" == "--help" || "$MODE" == "-h" ]]; then
  cat <<'HELP'
Artix Base + runit installer

Run from the Artix live ISO as root:
  bash artix-runit-installer.sh
  bash artix-runit-installer.sh --dry-run

The dry-run mode inspects the disks and shows a plan, without partitioning or formatting.
The install mode erases only the explicitly confirmed system SSD. Formatting the data HDD
is optional and requires a second, separate confirmation. The script uses ext4, no LUKS,
no separate swap partition, and installs Hyprland/Caelestia in a second stage after reboot.

Inspect this script before execution. Do not pipe it to bash until you trust the source.
HELP
  exit 0
fi
DRY_RUN=0
[[ "$MODE" == "--dry-run" ]] && DRY_RUN=1
[[ -d /sys/firmware/efi ]] && BOOTMODE="uefi" || BOOTMODE="bios"
[[ "$MODE" == "install" || "$MODE" == "--dry-run" ]] || die "Unknown argument: $MODE"

[[ $EUID -eq 0 ]] || die 'Run as root from the Artix live ISO.'
[[ "$(uname -m)" == "x86_64" ]] || die 'This installer supports x86_64 only.'
if [[ "$DRY_RUN" -eq 0 ]]; then
  for c in basestrap fstabgen artix-chroot pacman wipefs parted mkfs.ext4 mkfs.fat blkid lsblk findmnt mountpoint mount umount udevadm; do need "$c"; done
  [[ -e /run/runit ]] || warn 'The live environment does not expose /run/runit; continue only if you are certain this is Artix Base.'
else
  for c in lsblk readlink; do need "$c"; done
fi
[[ -e /dev/tty ]] || die 'Interactive terminal not found. Run this from a real TTY.'
exec 3<>/dev/tty
ask(){ local __var="$1"; local __prompt="$2"; read -r -p "$__prompt" "$__var" <&3; }

log 'Available physical disks'
lsblk -d -o PATH,SIZE,MODEL,TRAN,ROTA,TYPE
printf '\nSelect the INTERNAL SSD that will contain Artix. Use a whole disk, not a partition.\n'
ask TARGET 'System SSD path (example /dev/nvme0n1 or /dev/sda): '
[[ -b "$TARGET" ]] || die "Not a block device: $TARGET"
TARGET="$(readlink -f -- "$TARGET")"
[[ "$(lsblk -dn -o TYPE "$TARGET" | xargs)" == 'disk' ]] || die 'Select a whole disk, not a partition.'
[[ "$(lsblk -dn -o RM "$TARGET" | xargs)" != '1' ]] || die 'The system disk is marked removable; refusing to erase it.'
TRAN="$(lsblk -dn -o TRAN "$TARGET" | xargs || true)"
[[ "${TRAN,,}" != 'usb' ]] || die 'The system disk appears to be connected over USB; refusing to erase it.'
if lsblk -nrpo MOUNTPOINTS "$TARGET" | grep -qE '[^[:space:]]'; then
  die "At least one partition on $TARGET is mounted. Unmount it before installing."
fi
printf '\nSelected system disk details:\n'
lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS,MODEL "$TARGET"

printf '\nSelect the separate HDD intended for data. The installer will not touch it unless you explicitly request formatting.\n'
ask DATA_DISK 'Data HDD path (example /dev/sdb): '
[[ -b "$DATA_DISK" ]] || die "Not a block device: $DATA_DISK"
DATA_DISK="$(readlink -f -- "$DATA_DISK")"
[[ "$(lsblk -dn -o TYPE "$DATA_DISK" | xargs)" == 'disk' ]] || die 'Select the whole data disk, not one of its partitions.'
[[ "$DATA_DISK" != "$TARGET" ]] || die 'System SSD and data HDD must be different physical disks.'
printf '\nSelected data disk details:\n'
lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS,MODEL "$DATA_DISK"

FORMAT_DATA='no'
ask FORMAT_ANSWER 'Create one ext4 /data partition on this HDD? This erases the HDD. Type yes or no: '
if [[ "${FORMAT_ANSWER,,}" == 'yes' ]]; then
  FORMAT_DATA='yes'
  if lsblk -nrpo MOUNTPOINTS "$DATA_DISK" | grep -qE '[^[:space:]]'; then
    die "A partition on $DATA_DISK is mounted. Unmount it before formatting."
  fi
  printf '\nTo confirm HDD erasure, type exactly: FORMAT DATA %s\n' "$DATA_DISK"
  ask DATA_CONFIRM 'Confirmation: '
  [[ "$DATA_CONFIRM" == "FORMAT DATA $DATA_DISK" ]] || die 'Data HDD confirmation did not match. The HDD will not be formatted.'
else
  echo 'The HDD will be left untouched and will not be automatically mounted by this installer.'
fi

HOSTNAME='artix-pc'
ask HOSTNAME 'Hostname [artix-pc]: '
HOSTNAME="${HOSTNAME:-artix-pc}"
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || die 'Invalid hostname.'
ask USERNAME 'Username to create: '
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid username.'

printf '\nDetected firmware mode: %s\n' "$BOOTMODE"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'DRY-RUN plan (no changes will be made):\n  System disk: %s (would be erased)\n  Data disk:   %s (%s)\n  Filesystem:  ext4; no LUKS; no swap partition\n' \
    "$TARGET" "$DATA_DISK" "$([[ "$FORMAT_DATA" == 'yes' ]] && echo 'would be erased and mounted at /data' || echo 'untouched')"
else
  printf 'Plan:\n  System disk: %s (WILL BE ERASED)\n  Data disk:   %s (%s)\n  Filesystem:  ext4; no LUKS; no swap partition\n' \
    "$TARGET" "$DATA_DISK" "$([[ "$FORMAT_DATA" == 'yes' ]] && echo 'WILL BE ERASED and mounted at /data' || echo 'untouched')"
fi
if [[ "$BOOTMODE" == 'uefi' ]]; then
  echo '  SSD layout: GPT, 1 GiB EFI System Partition at /boot, ext4 root on remaining space.'
  echo '  Disable Secure Boot in firmware before first boot.'
else
  echo '  SSD layout: GPT, 2 MiB BIOS boot partition, ext4 root on remaining space.'
fi
printf '\nTo confirm erasing the system SSD, type exactly: ERASE SYSTEM %s\n' "$TARGET"
ask SYSTEM_CONFIRM 'Confirmation: '
[[ "$SYSTEM_CONFIRM" == "ERASE SYSTEM $TARGET" ]] || die 'System SSD confirmation did not match; no disk changes made.'
ask FINAL_CONFIRM 'Type INSTALL ARTIX to start the installation: '
[[ "$FINAL_CONFIRM" == 'INSTALL ARTIX' ]] || die 'Final confirmation did not match; no disk changes made.'

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo 'DRY RUN COMPLETE: no packages were installed and no disk was modified.'
  exit 0
fi

if mountpoint -q /mnt; then die '/mnt is already a mountpoint. Unmount it before running the installer.'; fi
if findmnt -rn -o TARGET | grep -Fxq /mnt; then die '/mnt is already mounted.'; fi

log 'Prepare partitioning tools before any disk is erased'
# ISO packages may be minimal; install these tools before destructive operations.
pacman -Syu --needed parted dosfstools e2fsprogs < /dev/tty
for c in wipefs parted mkfs.ext4 mkfs.fat; do need "$c"; done
BASE_REQUIRED=(runit runit-rc linux linux-firmware amd-ucode grub sudo fish git vim nano networkmanager networkmanager-runit dbus dbus-runit elogind elogind-runit)
if [[ "$BOOTMODE" == 'uefi' ]]; then BASE_REQUIRED+=(efibootmgr); fi
for package in "${BASE_REQUIRED[@]}"; do
  pacman -Si "$package" >/dev/null 2>&1 || die "Required Artix package unavailable: $package. No disks have been modified; check repositories/mirrors."
done

part_path(){
  local disk="$1" number="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then printf '%sp%s' "$disk" "$number"; else printf '%s%s' "$disk" "$number"; fi
}
PART_BOOT=''
if [[ "$BOOTMODE" == 'uefi' ]]; then
  PART_BOOT="$(part_path "$TARGET" 1)"
  PART_ROOT="$(part_path "$TARGET" 2)"
else
  PART_ROOT="$(part_path "$TARGET" 2)"
fi
DATA_PART=''
if [[ "$FORMAT_DATA" == 'yes' ]]; then DATA_PART="$(part_path "$DATA_DISK" 1)"; fi

log "Erase and partition system SSD: $TARGET"
wipefs -af "$TARGET"
parted -s "$TARGET" mklabel gpt
if [[ "$BOOTMODE" == 'uefi' ]]; then
  parted -s "$TARGET" mkpart ESP fat32 1MiB 1025MiB
  parted -s "$TARGET" set 1 esp on
  parted -s "$TARGET" name 1 ARTIX_EFI
  parted -s "$TARGET" mkpart ROOT ext4 1025MiB 100%
  parted -s "$TARGET" name 2 ARTIX_ROOT
else
  parted -s "$TARGET" mkpart BIOSBOOT 1MiB 3MiB
  parted -s "$TARGET" set 1 bios_grub on
  parted -s "$TARGET" name 1 ARTIX_BIOSBOOT
  parted -s "$TARGET" mkpart ROOT ext4 3MiB 100%
  parted -s "$TARGET" name 2 ARTIX_ROOT
fi
partprobe "$TARGET" || true
udevadm settle || true
if [[ "$BOOTMODE" == 'uefi' ]]; then mkfs.fat -F32 -n ARTIX_EFI "$PART_BOOT"; fi
mkfs.ext4 -F -L ARTIX_ROOT "$PART_ROOT"

if [[ "$FORMAT_DATA" == 'yes' ]]; then
  log "Erase and format data HDD: $DATA_DISK"
  wipefs -af "$DATA_DISK"
  parted -s "$DATA_DISK" mklabel gpt
  parted -s "$DATA_DISK" mkpart DATA ext4 1MiB 100%
  parted -s "$DATA_DISK" name 1 ARTIX_DATA
  partprobe "$DATA_DISK" || true
  udevadm settle || true
  mkfs.ext4 -F -L ARTIX_DATA "$DATA_PART"
fi

log 'Mount target filesystems'
mkdir -p /mnt
mount "$PART_ROOT" /mnt
if [[ "$BOOTMODE" == 'uefi' ]]; then mkdir -p /mnt/boot; mount "$PART_BOOT" /mnt/boot; fi
if [[ "$FORMAT_DATA" == 'yes' ]]; then mkdir -p /mnt/data; mount "$DATA_PART" /mnt/data; fi

log 'Install Artix Base + runit'
basestrap /mnt \
  base base-devel runit runit-rc \
  linux linux-firmware amd-ucode \
  grub sudo fish git vim nano \
  networkmanager networkmanager-runit \
  dbus dbus-runit elogind elogind-runit \
  < /dev/tty || die 'basestrap failed. The system disk has already been partitioned; inspect the log before retrying.'

fstabgen -U /mnt > /mnt/etc/fstab
if [[ "$FORMAT_DATA" == 'yes' ]]; then
  DATA_UUID="$(blkid -s UUID -o value "$DATA_PART")"
  if ! grep -Eq "^[[:space:]]*UUID=${DATA_UUID}[[:space:]]+/data[[:space:]]" /mnt/etc/fstab; then
    printf 'UUID=%s /data ext4 defaults,noatime 0 2\n' "$DATA_UUID" >> /mnt/etc/fstab
  fi
fi

cat > /mnt/root/artix-configure.sh <<'CHROOT_CONFIG'
#!/usr/bin/env bash
set -Eeuo pipefail
HOSTNAME="$1"
USERNAME="$2"
BOOTMODE="$3"
TARGET_DISK="$4"

printf '%s\n' "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF_HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF_HOSTS
ln -sf /usr/share/zoneinfo/America/Bogota /etc/localtime
hwclock --systohc

for locale in "en_US.UTF-8 UTF-8" "es_CO.UTF-8 UTF-8"; do
  if grep -qxF "#$locale" /etc/locale.gen; then
    sed -i "\|^#${locale}$|s/^#//" /etc/locale.gen
  fi
  grep -qxF "$locale" /etc/locale.gen || printf '%s\n' "$locale" >> /etc/locale.gen
done
locale-gen
cat > /etc/locale.conf <<'EOF_LOCALE'
LANG=es_CO.UTF-8
LC_MESSAGES=en_US.UTF-8
EOF_LOCALE
echo 'KEYMAP=la-latin1' > /etc/vconsole.conf

printf '\nSet the root password now.\n'
passwd
USER_GROUPS='wheel,audio,video,storage'
getent group input >/dev/null 2>&1 && USER_GROUPS+=',input'
useradd -m -G "$USER_GROUPS" -s /bin/fish "$USERNAME"
printf '\nSet password for %s now.\n' "$USERNAME"
passwd "$USERNAME"
install -o "$USERNAME" -g "$USERNAME" -m 0755 /root/artix-postinstall.sh "/home/$USERNAME/artix-postinstall.sh"
install -d -m 0750 /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers >/dev/null

mkdir -p /etc/runit/runsvdir/default
for service in dbus elogind NetworkManager; do
  found=''
  for candidate in "/etc/runit/sv/$service" "/etc/runit/sv/${service,,}"; do
    if [[ -d "$candidate" ]]; then found="$candidate"; break; fi
  done
  if [[ -n "$found" ]]; then
    ln -sfn "$found" "/etc/runit/runsvdir/default/$(basename "$found")"
  else
    echo "NOTICE: runit service directory not found for $service; verify the corresponding Artix service package."
  fi
done

if [[ "$BOOTMODE" == 'uefi' ]]; then
  pacman -S --needed --noconfirm efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix --removable
else
  grub-install --target=i386-pc "$TARGET_DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_CONFIG

# Embed the independent second-stage script in the target root; chroot config copies it after user creation.
cat > /mnt/root/artix-postinstall.sh <<'POSTINSTALL_SCRIPT'
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
POSTINSTALL_SCRIPT
chmod 0755 /mnt/root/artix-postinstall.sh
chmod 0755 /mnt/root/artix-configure.sh

log 'Configure the installed system'
artix-chroot /mnt /bin/bash /root/artix-configure.sh "$HOSTNAME" "$USERNAME" "$BOOTMODE" "$TARGET" < /dev/tty

sync
log 'Installation complete'
echo "Target SSD: $TARGET"
if [[ "$FORMAT_DATA" == 'yes' ]]; then echo "Data HDD formatted as ext4 and mounted at /data: $DATA_DISK"; else echo "Data HDD preserved untouched: $DATA_DISK"; fi
echo 'The post-install script is in your new home directory: ~/artix-postinstall.sh'
echo 'No graphical environment was installed in the live chroot; run the second stage after reboot.'
echo
echo 'Next:'
echo '  1. Check the log and confirm GRUB was installed.'
echo '  2. Run: umount -R /mnt'
echo '  3. Reboot and remove the USB.'
echo '  4. Log in, then run: bash ~/artix-postinstall.sh'
echo "Log file: $LOG"
