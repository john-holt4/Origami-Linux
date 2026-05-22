#!/bin/bash

LOGO="/tmp/rakuos_logo.png"
if [ ! -f "$LOGO" ]; then
    wget -q -O "$LOGO" "https://rakuos.org/themes/raku/assets/images/rakuos_whitelogo_med.png"
fi

if ! grep -qi 'ID=.*origami' /etc/os-release /usr/lib/os-release 2>/dev/null; then
    exit 0
fi

yad --center \
    --width=700 \
    --borders=20 \
    --title="Migrate to RakuOS" \
    --window-icon="dialog-warning" \
    --image="$LOGO" \
    --image-on-top \
    --text-align=center \
    --button="Remind Me Later":1 \
    --button="Migrate Now":0 \
    --default \
    --text="
<big><b>Origami Linux is merging into RakuOS.</b></big>

<i>To continue receiving updates and support, please migrate to the new RakuOS image.</i>
"

response=$?
if [ $response -eq 0 ]; then
    img_choice=$(yad --center --width=400 --height=150 --title="Choose Image" \
        --button="Standard (Intel/AMD)":0 --button="NVIDIA":1 \
        --text="<b>Select your hardware type:</b>\n\nStandard (Intel/AMD) or NVIDIA")
    if [ $? -eq 0 ]; then
        cosmic-term -e bash -c "echo 'Rebasing to RakuOS standard image...'; sudo rpm-ostree rebase ostree-unverified-registry:registry.gitlab.com/rakuos/images/rakuos-cosmic:latest; echo 'Done. Please reboot.'; read -p 'Press Enter to close...'"
    else
        cosmic-term -e bash -c "echo 'Rebasing to RakuOS NVIDIA image...'; sudo rpm-ostree rebase ostree-unverified-registry:registry.gitlab.com/rakuos/images/rakuos-cosmic/nvidia:latest; echo 'Done. Please reboot.'; read -p 'Press Enter to close...'"
    fi
fi
