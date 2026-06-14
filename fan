#!/usr/bin/env bash
###############################################################################
#  fan - CLI de controle ventilation Octominer
#
#  Usage:
#    fan 30          → tous les fans a 30%
#    fan 50          → tous les fans a 50%
#    fan max         → tous les fans a 100%
#    fan min         → tous les fans au minimum (30%)
#    fan scan        → scanner les ports (sauvegarde automatique)
#    fan status      → afficher l'etat actuel
#    fan auto        → activer le mode auto (temperature)
#    fan help        → afficher l'aide
#
#  Les ports et la vitesse sont sauvegardes dans /etc/octofan.conf
#  Un service systemd maintient la vitesse apres redemarrage.
###############################################################################

# Verifier root
if [[ $EUID -ne 0 ]]; then
    echo "Erreur: lancer avec sudo"
    echo "  sudo fan $*"
    exit 1
fi

################################################################################
# CONFIGURATION
################################################################################

OCTOFAN_BIN="/hive/opt/octofan/fan_controller_cli"
CONF_FILE="/etc/octofan.conf"
FAN_PWM_FACTOR=-30

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

################################################################################
# FONCTIONS
################################################################################

# Charger la config
load_config() {
    if [[ -f "$CONF_FILE" ]]; then
        source "$CONF_FILE"
    fi
}

# Sauvegarder la config
save_config() {
    cat > "$CONF_FILE" <<EOF
# Configuration octofan - generee automatiquement
NUM_FANS=${NUM_FANS:-4}
FAN_PORTS=(${FAN_PORTS[*]})
LAST_SPEED=${LAST_SPEED:-100}
MIN_FAN=${MIN_FAN:-30}
TARGET_TEMP=${TARGET_TEMP:-66}
AUTO_MODE=${AUTO_MODE:-0}
EOF
    chmod 644 "$CONF_FILE"
}

# Convertir pourcentage en PWM
percent_to_pwm() {
    local percent=$1
    local pwm
    pwm=$(awk "BEGIN { printf \"%.0f\", 255 * $percent / 100 + $FAN_PWM_FACTOR }")
    [[ $pwm -gt 255 ]] && pwm=255
    [[ $pwm -lt 0 ]] && pwm=0
    echo "$pwm"
}

# Verifier que le binaire existe
check_binary() {
    if [[ ! -x "$OCTOFAN_BIN" ]]; then
        echo -e "${RED}Erreur: $OCTOFAN_BIN introuvable${NC}"
        echo "Installer avec:"
        echo "  sudo mkdir -p /hive/opt/octofan"
        echo "  sudo curl -sL -o /hive/opt/octofan/fan_controller_cli \\"
        echo "    https://raw.githubusercontent.com/minershive/hiveos-linux/master/hive/opt/octofan/fan_controller_cli"
        echo "  sudo chmod +x /hive/opt/octofan/fan_controller_cli"
        exit 1
    fi
}

# Verifier que les ports sont configures
check_ports() {
    if [[ -z "${FAN_PORTS[*]:-}" || ${#FAN_PORTS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Ports non configures. Lancer le scan:${NC}"
        echo "  sudo fan scan"
        exit 1
    fi
}

# Appliquer la vitesse sur tous les fans
apply_speed() {
    local percent=$1
    local pwm
    pwm=$(percent_to_pwm "$percent")

    for port in "${FAN_PORTS[@]}"; do
        $OCTOFAN_BIN -f "$port" -v "$pwm" &>/dev/null
        sleep 0.05
    done

    LAST_SPEED=$percent
    save_config
}

# Scanner les ports
do_scan() {
    echo -e "${BOLD}${CYAN}=== SCAN DES PORTS FAN ===${NC}"
    echo ""
    echo -e "Chaque port (0-11) sera active a 40% pendant 4 secondes."
    echo -e "${YELLOW}Regarde/ecoute quel fan tourne.${NC}"
    echo ""
    echo -e "  ${GREEN}o${NC} = OUI, un fan tourne"
    echo -e "  ${RED}n${NC}/Enter = NON, rien"
    echo -e "  ${YELLOW}q${NC} = Annuler"
    echo ""

    local TEST_PWM
    TEST_PWM=$(percent_to_pwm 40)
    local detected=()

    # Tout couper
    echo -e "${DIM}Arret de tous les ports...${NC}"
    for port in $(seq 0 11); do
        $OCTOFAN_BIN -f "$port" -v 0 &>/dev/null
        sleep 0.03
    done
    sleep 2

    # Tester chaque port
    for port in $(seq 0 11); do
        echo ""
        echo -e "${BOLD}${YELLOW}>>> PORT $port${NC} ${DIM}(40% pendant 4s)${NC}"

        $OCTOFAN_BIN -f "$port" -v "$TEST_PWM" &>/dev/null

        for i in 4 3 2 1; do
            echo -ne "\r  ${DIM}Ecoute... ${i}s ${NC}"
            sleep 1
        done
        echo ""

        $OCTOFAN_BIN -f "$port" -v 0 &>/dev/null

        echo -ne "  Fan tourne ? (${GREEN}o${NC}/${RED}n${NC}): "
        read -rsn1 answer
        echo ""

        case "$answer" in
            o|O|y|Y)
                detected+=("$port")
                echo -e "  ${GREEN}✓ Port $port: DETECTE${NC}"
                ;;
            q|Q)
                echo -e "${YELLOW}Scan annule.${NC}"
                # Remettre les fans
                if [[ ${#FAN_PORTS[@]} -gt 0 ]]; then
                    apply_speed "${LAST_SPEED:-100}"
                fi
                return 1
                ;;
            *)
                echo -e "  ${DIM}  Port $port: rien${NC}"
                ;;
        esac
    done

    echo ""
    echo -e "${BOLD}==============================${NC}"

    if [[ ${#detected[@]} -eq 0 ]]; then
        echo -e "${RED}Aucun fan detecte ! Verifier le branchement.${NC}"
        return 1
    fi

    # Limiter a 4 max
    local max=4
    [[ ${#detected[@]} -lt $max ]] && max=${#detected[@]}

    FAN_PORTS=("${detected[@]:0:$max}")
    NUM_FANS=$max
    LAST_SPEED=${LAST_SPEED:-100}

    echo -e "${GREEN}${max} fan(s) detecte(s) sur ports: ${FAN_PORTS[*]}${NC}"
    save_config
    echo -e "${GREEN}Configuration sauvegardee dans $CONF_FILE${NC}"

    # Remettre les fans en marche
    apply_speed "$LAST_SPEED"
    echo -e "Fans regles a ${LAST_SPEED}%"
}

# Afficher le status
do_status() {
    echo -e "${BOLD}${CYAN}=== OCTOFAN STATUS ===${NC}"
    echo ""

    # Lire les infos du controleur
    local cli_out
    cli_out=$($OCTOFAN_BIN -r 2>/dev/null)

    if [[ $? -ne 0 ]] || ! echo "$cli_out" | grep -q "Serial No:"; then
        echo -e "${RED}Controleur non detecte${NC}"
        return 1
    fi

    # Versions
    local hw fw cli_v
    hw=$(echo "$cli_out" | grep "VERSION-HW:" | awk '{print $2}')
    fw=$(echo "$cli_out" | grep "VERSION-FW:" | awk '{print $2}')
    cli_v=$(echo "$cli_out" | grep "VERSION-CLI:" | awk '{print $2}')
    echo -e "  Hardware: ${GREEN}v${hw}${NC}  Firmware: ${GREEN}v${fw}${NC}  CLI: ${GREEN}v${cli_v}${NC}"
    echo ""

    # Temperatures
    local t0 t1
    t0=$(echo "$cli_out" | grep "Temperature No. 0" | grep -oP ':\s*\K[0-9.]+')
    t1=$(echo "$cli_out" | grep "Temperature No. 1" | grep -oP ':\s*\K[0-9.]+')
    [[ -n "$t0" ]] && (( $(echo "$t0 > 200" | bc -l 2>/dev/null || echo 0) )) && t0=""
    [[ -n "$t1" ]] && (( $(echo "$t1 > 200" | bc -l 2>/dev/null || echo 0) )) && t1=""
    echo -e "  Intake:  ${GREEN}${t0:-N/A}°C${NC}"
    echo -e "  Outgoing: ${GREEN}${t1:-N/A}°C${NC}"
    echo ""

    # Fans
    if [[ ${#FAN_PORTS[@]} -gt 0 ]]; then
        echo -e "  Fans: ${GREEN}${NUM_FANS}${NC} (ports: ${FAN_PORTS[*]})"
        echo -e "  Vitesse: ${GREEN}${LAST_SPEED:-?}%${NC}"
        if [[ "${AUTO_MODE:-0}" -eq 1 ]]; then
            echo -e "  Mode: ${CYAN}AUTO${NC} (cible: ${TARGET_TEMP}°C)"
        else
            echo -e "  Mode: ${YELLOW}MANUEL${NC}"
        fi
    else
        echo -e "  ${YELLOW}Ports non configures - lancer: sudo fan scan${NC}"
    fi
    echo ""
}

# Mode auto (une seule passe)
do_auto() {
    check_ports

    local cli_out t0
    cli_out=$($OCTOFAN_BIN -r 2>/dev/null)
    t0=$(echo "$cli_out" | grep "Temperature No. 0" | grep -oP ':\s*\K[0-9.]+')

    if [[ -z "$t0" ]] || (( $(echo "$t0 > 200" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "${RED}Temperature non lisible - fans a 100% par securite${NC}"
        apply_speed 100
        return 1
    fi

    local target=${TARGET_TEMP:-66}
    local min_speed=${MIN_FAN:-30}
    local speed

    # Calcul proportionnel
    if (( $(echo "$t0 >= $target" | bc -l) )); then
        speed=100
    elif (( $(echo "$t0 <= ($target - 20)" | bc -l) )); then
        speed=$min_speed
    else
        speed=$(awk "BEGIN { printf \"%.0f\", $min_speed + (100 - $min_speed) * ($t0 - ($target - 20)) / 20 }")
    fi

    [[ $speed -gt 100 ]] && speed=100
    [[ $speed -lt $min_speed ]] && speed=$min_speed

    apply_speed "$speed"
    echo -e "Auto: ${t0}°C → ${speed}% (cible: ${target}°C)"
}

# Aide
do_help() {
    echo -e "${BOLD}${CYAN}fan${NC} - Controle ventilation Octominer"
    echo ""
    echo -e "  ${BOLD}Usage:${NC}"
    echo -e "    sudo fan ${GREEN}<pourcentage>${NC}    Regler tous les fans (0-100)"
    echo -e "    sudo fan ${GREEN}max${NC}              Tous a 100%"
    echo -e "    sudo fan ${GREEN}min${NC}              Tous au minimum (30%)"
    echo -e "    sudo fan ${GREEN}scan${NC}             Scanner et sauvegarder les ports"
    echo -e "    sudo fan ${GREEN}status${NC}           Afficher l'etat"
    echo -e "    sudo fan ${GREEN}auto${NC}             Ajuster selon temperature"
    echo -e "    sudo fan ${GREEN}help${NC}             Cette aide"
    echo ""
    echo -e "  ${BOLD}Exemples:${NC}"
    echo -e "    sudo fan 30     → 30%"
    echo -e "    sudo fan 50     → 50%"
    echo -e "    sudo fan 100    → 100%"
    echo ""
    echo -e "  ${BOLD}Config:${NC} $CONF_FILE"
    echo -e "  ${BOLD}Service:${NC} systemctl status octofan"
    echo ""
}

# Installer le service systemd
install_service() {
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

    # Timer pour le mode auto (toutes les 30s)
    cat > /etc/systemd/system/octofan-auto.service <<'UNIT'
[Unit]
Description=Octofan auto adjust

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fan apply
UNIT

    cat > /etc/systemd/system/octofan-auto.timer <<'UNIT'
[Unit]
Description=Octofan auto adjust timer

[Timer]
OnBootSec=30
OnUnitActiveSec=30

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable octofan.service
    systemctl start octofan.service
    echo -e "${GREEN}Service octofan installe et active${NC}"
    echo "  La vitesse sera restauree au demarrage."
}

# Appliquer la derniere config (utilise par systemd)
do_apply() {
    load_config
    if [[ ${#FAN_PORTS[@]} -gt 0 && -n "${LAST_SPEED:-}" ]]; then
        apply_speed "$LAST_SPEED"
    fi
}

################################################################################
# MAIN
################################################################################

check_binary
load_config

case "${1:-}" in
    ""|help|-h|--help)
        do_help
        ;;
    scan)
        do_scan
        ;;
    status|info)
        do_status
        ;;
    auto)
        AUTO_MODE=1
        save_config
        do_auto
        ;;
    max)
        check_ports
        apply_speed 100
        echo -e "${GREEN}Fans: 100%${NC}"
        ;;
    min)
        check_ports
        apply_speed "${MIN_FAN:-30}"
        echo -e "${GREEN}Fans: ${MIN_FAN:-30}%${NC}"
        ;;
    apply)
        do_apply
        ;;
    install)
        install_service
        ;;
    *)
        # Verifier si c'est un nombre
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            check_ports
            speed=$1
            [[ $speed -gt 100 ]] && speed=100
            [[ $speed -lt 0 ]] && speed=0
            apply_speed "$speed"
            echo -e "${GREEN}Fans: ${speed}%${NC}"
        else
            echo -e "${RED}Commande inconnue: $1${NC}"
            echo "Taper 'sudo fan help' pour l'aide"
            exit 1
        fi
        ;;
esac
