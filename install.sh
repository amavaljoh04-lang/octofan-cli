#!/bin/bash
###############################################################################
#  Installation Octofan CLI - Tout en un
#  Usage: sudo bash install.sh
###############################################################################

set -e

# Couleurs
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=== Installation Octofan CLI ===${NC}"
echo ""

# Verifier root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Erreur: lancer avec sudo${NC}"
    echo "  sudo bash install.sh"
    exit 1
fi

# Detecter le dossier du script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Installer libusb
echo -e "${YELLOW}[1/6] Installation libusb + avrdude...${NC}"
apt-get install -y libusb-0.1-4 libusb-dev avrdude > /dev/null 2>&1 || true
echo -e "${GREEN}  OK${NC}"

# 2. Installer fan_controller_cli
echo -e "${YELLOW}[2/6] Installation fan_controller_cli...${NC}"
mkdir -p /hive/opt/octofan
cp "$SCRIPT_DIR/fan_controller_cli" /hive/opt/octofan/fan_controller_cli
chmod +x /hive/opt/octofan/fan_controller_cli
echo -e "${GREEN}  OK -> /hive/opt/octofan/fan_controller_cli${NC}"

# 3. Installer firmware + avrdude.conf
echo -e "${YELLOW}[3/6] Installation firmware...${NC}"
if [[ -d "$SCRIPT_DIR/firmware" ]]; then
    cp "$SCRIPT_DIR/firmware/firmware_07.hex" /hive/opt/octofan/ 2>/dev/null || true
    cp "$SCRIPT_DIR/firmware/firmware_09.hex" /hive/opt/octofan/ 2>/dev/null || true
    cp "$SCRIPT_DIR/firmware/avrdude.conf" /hive/opt/octofan/ 2>/dev/null || true
    echo -e "${GREEN}  OK -> /hive/opt/octofan/firmware_*.hex${NC}"
else
    echo -e "${YELLOW}  Dossier firmware/ absent - flash manuel requis${NC}"
fi

# 4. Installer la commande fan
echo -e "${YELLOW}[4/6] Installation commande fan...${NC}"
cp "$SCRIPT_DIR/fan" /usr/local/bin/fan
chmod +x /usr/local/bin/fan
echo -e "${GREEN}  OK -> /usr/local/bin/fan${NC}"

# 5. Flash firmware si necessaire
echo -e "${YELLOW}[5/6] Verification firmware controleur...${NC}"
if /hive/opt/octofan/fan_controller_cli -r 2>/dev/null | grep -q "VERSION-FW: 0.0"; then
    echo -e "${YELLOW}  Firmware vide detecte - flash automatique...${NC}"
    if [[ -f /hive/opt/octofan/firmware_09.hex ]]; then
        /hive/opt/octofan/fan_controller_cli -b 2>/dev/null || true
        sleep 3
        avrdude -C /hive/opt/octofan/avrdude.conf -pm324pb -cusbasp \
            -U flash:w:/hive/opt/octofan/firmware_09.hex:a 2>/dev/null || true
        sleep 3
        /hive/opt/octofan/fan_controller_cli -bx 2>/dev/null || true
        sleep 3
        echo -e "${GREEN}  Firmware flashe !${NC}"
    else
        echo -e "${YELLOW}  Firmware non trouve - lancer: sudo bash flash-firmware.sh${NC}"
    fi
elif /hive/opt/octofan/fan_controller_cli -r 2>/dev/null | grep -q "VERSION-FW:"; then
    fw_ver=$(/hive/opt/octofan/fan_controller_cli -r 2>/dev/null | grep "VERSION-FW:" | awk '{print $2}')
    echo -e "${GREEN}  Firmware OK (v${fw_ver})${NC}"
else
    echo -e "${YELLOW}  Controleur non detecte - verifier USB${NC}"
fi

# 6. Installer le service systemd
echo -e "${YELLOW}[6/6] Installation service systemd...${NC}"

cat > /etc/systemd/system/octofan.service <<'UNIT'
[Unit]
Description=Octofan - Controle ventilation Octominer
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/fan apply
ExecStop=/usr/local/bin/fan max

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable octofan.service
echo -e "${GREEN}  OK -> service octofan active${NC}"

# Verifier le controleur
echo ""
echo -e "${CYAN}=== Verification ===${NC}"
if /hive/opt/octofan/fan_controller_cli -r 2>/dev/null | grep -q "Serial No:"; then
    echo -e "${GREEN}  Controleur Octofan detecte !${NC}"
    fw_ver=$(/hive/opt/octofan/fan_controller_cli -r 2>/dev/null | grep "VERSION-FW:" | awk '{print $2}')
    hw_ver=$(/hive/opt/octofan/fan_controller_cli -r 2>/dev/null | grep "VERSION-HW:" | awk '{print $2}')
    echo -e "${GREEN}  Firmware: v${fw_ver}  Hardware: v${hw_ver}${NC}"
else
    echo -e "${YELLOW}  Controleur non detecte (verifier branchement USB)${NC}"
fi

echo ""
echo -e "${GREEN}=== Installation terminee ===${NC}"
echo ""
echo -e "Prochaine etape:"
echo -e "  ${CYAN}sudo fan scan${NC}      Scanner les ports (premiere fois)"
echo -e "  ${CYAN}sudo fan 50${NC}        Regler les fans a 50%"
echo -e "  ${CYAN}sudo fan status${NC}    Voir l'etat"
echo ""
