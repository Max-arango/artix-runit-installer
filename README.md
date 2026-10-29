# Artix Base + runit — instalador para PC de escritorio

Este paquete contiene un instalador en dos etapas para instalar Artix Linux Base con **runit** en un SSD dedicado y preparar después un entorno gráfico con **Hyprland**, herramientas de desarrollo/ciberseguridad y opciones para NVIDIA, Steam/Proton, Sober y Caelestia.

> **Advertencia:** la etapa 1 borra por completo el disco seleccionado como SSD del sistema. El HDD de datos se conserva por defecto. El script exige confirmaciones escritas que incluyen la ruta exacta de cada disco; aun así, eres responsable de comprobar los modelos y tamaños antes de confirmar.

## Archivos

- `artix-runit-installer.sh`: instalador principal autocontenido; incluye la segunda etapa dentro del archivo y la copia a `/home/USUARIO/artix-postinstall.sh`.
- `artix-postinstall.sh`: copia independiente de la etapa 2, útil para revisar el setup antes de ejecutar la instalación.
- `README.md`: estas instrucciones.
- `SHA256SUMS`: hashes para comprobar que los archivos no han cambiado accidentalmente.

## Qué hace

### Etapa 1 — desde la ISO Artix Base

- Detecta si la ISO live se arrancó en UEFI o BIOS/Legacy.
- Muestra los discos y pide que identifiques el SSD de sistema y el HDD de datos por ruta (`/dev/sda`, `/dev/nvme0n1`, etc.).
- Se niega a usar como disco de sistema un dispositivo marcado como extraíble o conectado por USB.
- Exige confirmar el borrado del SSD con `ERASE SYSTEM /ruta/exacta` y después `INSTALL ARTIX`.
- Crea una tabla GPT, EFI de 1 GiB + raíz ext4 en UEFI; o partición BIOS boot + raíz ext4 en BIOS/Legacy.
- No usa LUKS ni crea una partición swap.
- Conserva el HDD intacto por defecto. Si eliges expresamente formatearlo, pide otra confirmación separada y crea ext4 montado como `/data`.
- Instala Artix Base, runit, kernel, firmware, GRUB, red con NetworkManager, D-Bus, elogind y herramientas básicas.
- No reinicia automáticamente.

Si eliges **no** formatear el HDD, el instalador no lo monta automáticamente ni cambia sus particiones. Eso evita sobrescribir una instalación o datos existentes. Puedes configurarlo después una vez comprobado su sistema de archivos.

### Etapa 2 — después del primer arranque

Después de reiniciar en Artix e iniciar sesión en TTY, la etapa 2 ofrece instalar Hyprland y sus herramientas, audio, portales, navegador, lenguajes de programación, compiladores y utilidades de ciberseguridad. Luego pregunta por separado si debe instalar el controlador NVIDIA, Steam, Sober y Caelestia.

No instala un gestor de inicio de sesión gráfico: Hyprland se inicia manualmente desde TTY para poder verificar primero que el sistema funciona.

## Cómo usarlo

### 1. Preparar el USB y la ISO

Arranca desde una ISO oficial **Artix Base + runit** y comprueba que tienes conexión a Internet. Arranca la ISO en el modo de firmware que quieras usar en la instalación final. En UEFI, desactiva Secure Boot.

Descarga `artix-runit-installer.sh` desde esta conversación a otro USB o a un medio que puedas montar en la sesión live. No ejecutes el instalador desde un disco que luego vayas a borrar.

### 2. Revisar el script

Desde la terminal de Artix Live, entra en el directorio donde guardaste el archivo y ejecuta:

```bash
less artix-runit-installer.sh
bash -n artix-runit-installer.sh
bash artix-runit-installer.sh --help
```

Con `bash -n` se comprueba la sintaxis, no la compatibilidad real de cada paquete con una ISO particular.

### 3. Ejecutar el modo de simulación

```bash
sudo bash artix-runit-installer.sh --dry-run
```

El modo de simulación solicita seleccionar los discos y confirmar el plan, pero no formatea ni instala paquetes. Verifica tres veces el modelo, tamaño y ruta del SSD y del HDD.

### 4. Instalar el sistema base

```bash
sudo bash artix-runit-installer.sh
```

Lee cada pregunta. **No escribas la confirmación de borrado hasta verificar en `lsblk` que has seleccionado el SSD correcto.** Si algo no coincide, cancela con `Ctrl+C` antes de confirmar. El log queda en `/tmp/artix-runit-installer-AAAAmmdd-HHMMSS.log`.

Cuando indique que terminó:

```bash
umount -R /mnt
reboot
```

Retira el USB cuando reinicie el equipo. Inicia sesión con el usuario que creaste.

### 5. Instalar el setup gráfico

```bash
bash ~/artix-postinstall.sh
```

Recomiendo responder **sí** a la actualización completa del sistema. La instalación de paquetes opcionales puede variar según los repositorios y mirrors configurados en ese momento.

Al terminar, reinicia y prueba desde TTY:

```bash
dbus-run-session Hyprland
```

Si instalaste NVIDIA, tras reiniciar comprueba:

```bash
nvidia-smi
cat /sys/module/nvidia_drm/parameters/modeset
```

## Notas importantes de compatibilidad

### Caelestia

La ruta de Caelestia es **best-effort**: sus instrucciones y paquetes AUR se dirigen a Arch Linux y no declaran soporte oficial para Artix/runit. El script pregunta antes de intentar instalar `caelestia-cli` y `caelestia-shell`; si construye un helper AUR como `yay`, te pide revisar su `PKGBUILD`. Si las dependencias esperan systemd o falla la compilación, no fuerces esos paquetes: deja la base Artix funcionando y adapta las dependencias manualmente.

Caelestia Shell upstream enumera dependencias específicas, incluidas `quickshell-git` y `qt6-m3shapes-git`. Las versiones y disponibilidad de dependencias cambian: consulta la [documentación upstream de Caelestia Shell](https://github.com/caelestia-dots/shell#manual-installation).

### NVIDIA

El script busca un paquete de controlador disponible y no presupone que todas las variantes estén presentes en todos los repositorios Artix. Si no encuentra un paquete válido, omite el controlador en vez de instalar un nombre inventado. La selección final puede depender de la versión actual del kernel y de los paquetes que ofrezca el mirror.

### Steam y Sober

Steam/Proton se ofrece como paso opcional. El script intenta habilitar el repositorio `lib32` si existe en `/etc/pacman.conf`. Sober se ofrece a través de Flathub como `org.vinegarhq.Sober`; es un cliente no oficial, experimental y de código cerrado. Roblox no lo respalda. Véase [Flathub — Sober](https://flathub.org/apps/org.vinegarhq.Sober).

## Uso con `curl | bash`

No hay una URL pública para estos archivos en esta conversación. No inventes una URL ni uses el comando hasta que hayas publicado el script en un repositorio tuyo y revisado exactamente el contenido publicado. Una vez publicado, el patrón sería:

```bash
curl -fsSL 'URL_RAW_REAL_DEL_SCRIPT' | sudo bash -s -- --dry-run
curl -fsSL 'URL_RAW_REAL_DEL_SCRIPT' | sudo bash -s --
```

Es preferible descargarlo primero, revisar el código y comprobar `SHA256SUMS`. Nunca ejecutes un script de instalación destructivo desde una URL que no controles o no hayas revisado.

## Estado de validación

- Comprobación de sintaxis con `bash -n` en ambos scripts.
- Comprobación de que la etapa 2 embebida coincide con `artix-postinstall.sh`.
- Prueba de la salida `--help`.
- **No** se ha ejecutado en tu PC ni en una instalación real de Artix; no puedo garantizar la disponibilidad actual de todos los paquetes, el resultado de compilación de Caelestia ni el funcionamiento del controlador en tu hardware. La etapa de instalación consulta la disponibilidad de paquetes críticos antes de modificar el SSD, pero la instalación real debe supervisarse.
