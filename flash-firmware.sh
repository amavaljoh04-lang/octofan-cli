#!/bin/bash
###############################################################################
#  Flash du firmware Octominer sur le controleur ATmega324PB
#
#  Usage: sudo bash flash-firmware.sh
#
#  Pre-requis:
#    - avrdude installe (apt-get install -y avrdude)
#    - Controleur USB Octominer branche (16c0:05dc)
#
#  Le script:
#    1. Detecte le controleur USB
#    2. Entre en mode bootloader
#    3. Flash le firmware (firmware_09.hex par defaut)
#    4. Sort du bootloader
#    5. Verifie que le firmware repond
###############################################################################

set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OCTOFAN_BIN="/hive/opt/octofan/fan_controller_cli"
AVRDUDE_CONF="/hive/opt/octofan/avrdude.conf"
FW_FILE="$SCRIPT_DIR/firmware/firmware_09.hex"

# Verifier root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Erreur: lancer avec sudo${NC}"
    echo "  sudo bash flash-firmware.sh"
    exit 1
fi

# Verifier avrdude
if ! command -v avrdude &>/dev/null; then
    echo -e "${YELLOW}Installation de avrdude...${NC}"
    apt-get install -y avrdude > /dev/null 2>&1
fi

# Verifier le firmware
if [[ ! -f "$FW_FILE" ]]; then
    echo -e "${RED}Erreur: firmware introuvable: $FW_FILE${NC}"
    exit 1
fi

# Verifier avrdude.conf
if [[ ! -f "$AVRDUDE_CONF" ]]; then
    echo -e "${YELLOW}Copie avrdude.conf...${NC}"
    cp "$SCRIPT_DIR/firmware/avrdude.conf" "$AVRDUDE_CONF" 2>/dev/null || true
fi

# Verifier le device USB
if ! lsusb | grep -q "16c0:05dc"; then
    echo -e "${RED}Erreur: controleur USB Octominer non detecte${NC}"
    echo "Verifier le branchement USB"
    exit 1
fi

echo -e "${CYAN}=== Flash firmware Octominer ===${NC}"
echo ""

# Entrer en bootloader
echo -e "${YELLOW}[1/3] Entree en bootloader...${NC}"
$OCTOFAN_BIN -b 2>/dev/null || true
sleep 3
echo -e "${GREEN}  OK${NC}"

# Flasher
echo -e "${YELLOW}[2/3] Flash du firmware...${NC}"
echo -e "${CYAN}  $FW_FILE${NC}"
avrdude -C "$AVRDUDE_CONF" -pm324pb -cusbasp -U flash:w:"$FW_FILE":a 2>&1 | while read -r line; do
    echo "  $line"
done
sleep 3
echo -e "${GREEN}  OK${NC}"

# Sortir du bootloader
echo -e "${YELLOW}[3/3] Sortie du bootloader...${NC}"
$OCTOFAN_BIN -bx 2>/dev/null || true
sleep 3
echo -e "${GREEN}  OK${NC}"

# Verification
echo ""
echo -e "${CYAN}=== Verification ===${NC}"
sleep 2
local_out=$($OCTOFAN_BIN -r 2>/dev/null || echo "ERREUR")

if echo "$local_out" | grep -q "VERSION-FW:"; then
    fw_ver=$(echo "$local_out" | grep "VERSION-FW:" | awk '{print $2}')
    hw_ver=$(echo "$local_out" | grep "VERSION-HW:" | awk '{print $2}')
    echo -e "${GREEN}  Firmware: v${fw_ver}  Hardware: v${hw_ver}${NC}"
    echo ""
    echo -e "${GREEN}=== Flash termine avec succes ===${NC}"
else
    echo -e "${YELLOW}  Le controleur ne repond pas encore.${NC}"
    echo -e "  Essayer: sudo /hive/opt/octofan/fan_controller_cli -h"
    echo -e "  Si ca ne marche pas, debrancher/rebrancher le USB."
fi

echo ""
echo -e "Prochaine etape:"
echo -e "  ${CYAN}sudo fan scan${NC}      Scanner les ports fan"
echo -e "  ${CYAN}sudo fan 50${NC}        Regler les fans a 50%"
