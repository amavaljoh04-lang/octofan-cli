#!/usr/bin/env bash
###############################################################################
#  octofan-manager.sh  -  Gestion interactive de ventilation Octominer
#  Basé sur le code octofan de HiveOS (hiveos-linux)
#  Compatible HW v1.2 / FW 3.0 / CLI 1.7
#
#  Lancement :  sudo screen -S fanctl ./octofan-manager.sh
#  Ou direct :  sudo ./octofan-manager.sh
#
#  Le script tourne en boucle, affiche un dashboard en temps réel,
#  et accepte des commandes clavier à tout moment.
###############################################################################

set -o pipefail

################################################################################
# VERIFIER ROOT (nécessaire pour USB)
################################################################################
if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit etre lance avec sudo."
    echo "Usage: sudo $0"
    exit 1
fi

################################################################################
# COULEURS
################################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NOCOLOR='\033[0m'

################################################################################
# CONFIGURATION PAR DEFAUT
################################################################################
OCTOFAN_BIN="${OCTOFAN_BIN:-/hive/opt/octofan/fan_controller_cli}"
OCTOFAN_CONF="${OCTOFAN_CONF:-/hive-config/octofan/octofan.conf}"
CLI_OUTPUT="/tmp/fan_controller_cli_output"
CLI_TMP_OUTPUT="/tmp/octofan_cli_temp.txt"
MANAGER_CONF="/tmp/octofan_manager.conf"
LOG_FILE="/tmp/octofan-manager.log"
MAINTENANCE_SEM="/tmp/octofan_fw_update"

REFRESH_INTERVAL=10
AUTO_ENABLED=1
MANUAL_FAN=100
MIN_FAN=30
MAX_FAN=100
TARGET_TEMP=66
FAN_INC_SPEED_STEP=5

# Nombre de fans
NUM_FANS=4

# Mapping des fans physiques (ports)
FAN0_PORT=2
FAN1_PORT=3
FAN2_PORT=4
FAN3_PORT=5

# Facteur PWM
FAN_PWM_FACTOR=-30

################################################################################
# VARIABLES INTERNES
################################################################################
SELECTED_FAN="all"
CURRENT_SPEEDS=(100 100 100 100)
FAN_RPM=("--" "--" "--" "--")
FAN_MAX_RPM=("--" "--" "--" "--")
TEMPS=("N/A" "N/A" "N/A" "N/A" "N/A")
PSU_VAC="N/A"
PSU_PAC="N/A"
PSU_VDC="N/A"
FAN_PWM_FACTORS=($FAN_PWM_FACTOR $FAN_PWM_FACTOR $FAN_PWM_FACTOR $FAN_PWM_FACTOR)
HW_DETECTED=0
HW_VERSION=""
FW_VERSION=""
CLI_VERSION=""
RUNNING=1
LAST_CMD_MSG=""
LAST_CMD_TIME=0

################################################################################
# FONCTIONS UTILITAIRES
################################################################################

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

show_msg() {
    LAST_CMD_MSG="$1"
    LAST_CMD_TIME=$(date +%s)
    log_msg "$1"
}

check_maintenance() {
    if [[ -f "$MAINTENANCE_SEM" ]]; then
        local age=0
        age=$(( $(date +%s) - $(stat --format='%Y' "$MAINTENANCE_SEM" 2>/dev/null || echo 0) ))
        [[ $age -le 60 ]] && return 1
    fi
    return 0
}

# Détecter le matériel Octofan
detect_hardware() {
    # Vérifier si le binaire existe
    if [[ ! -x "$OCTOFAN_BIN" ]]; then
        echo -e "${RED}Binaire $OCTOFAN_BIN introuvable ou non executable${NOCOLOR}"
        HW_DETECTED=0
        return 1
    fi

    # Tester la communication
    local output
    output=$($OCTOFAN_BIN -r 2>/dev/null)
    if echo "$output" | grep -q "Serial No:"; then
        HW_DETECTED=1
        HW_VERSION=$(echo "$output" | grep "VERSION-HW:" | awk '{print $2}')
        FW_VERSION=$(echo "$output" | grep "VERSION-FW:" | awk '{print $2}')
        CLI_VERSION=$(echo "$output" | grep "VERSION-CLI:" | awk '{print $2}')
        # Sauvegarder la sortie initiale
        echo "$output" > "$CLI_OUTPUT"
        return 0
    fi

    # Essayer aussi via lsusb
    if command -v lsusb &>/dev/null; then
        local count
        count=$(lsusb 2>/dev/null | grep -c '16c0:05dc')
        if [[ $count -ge 1 ]]; then
            HW_DETECTED=1
            return 0
        fi
    fi

    HW_DETECTED=0
    return 1
}

# Convertir pourcentage en valeur PWM (0-255)
percent_to_pwm() {
    local percent=$1
    local fan_idx=${2:-}
    local factor=$FAN_PWM_FACTOR

    if [[ -n "$fan_idx" && -n "${FAN_PWM_FACTORS[$fan_idx]:-}" ]]; then
        factor=${FAN_PWM_FACTORS[$fan_idx]}
    fi

    local pwm
    pwm=$(awk "BEGIN { printf \"%.0f\", 255 * $percent / 100 + $factor }")
    [[ $pwm -gt 255 ]] && pwm=255
    [[ $pwm -lt 0 ]] && pwm=0
    echo "$pwm"
}

get_fan_port() {
    case $1 in
        0) echo "$FAN0_PORT" ;;
        1) echo "$FAN1_PORT" ;;
        2) echo "$FAN2_PORT" ;;
        3) echo "$FAN3_PORT" ;;
    esac
}

################################################################################
# FONCTIONS HARDWARE
################################################################################

# Lire les données du contrôleur
read_cli_data() {
    [[ $HW_DETECTED -eq 0 ]] && return 1
    check_maintenance || return 1

    $OCTOFAN_BIN -r > "$CLI_TMP_OUTPUT" 2>/dev/null
    if [[ $? -eq 0 ]] && grep -q "Serial No:" "$CLI_TMP_OUTPUT" 2>/dev/null; then
        mv "$CLI_TMP_OUTPUT" "$CLI_OUTPUT" 2>/dev/null
        return 0
    fi
    return 1
}

# Parser les données du CLI - compatible avec le format HW v1.2
# Format attendu:
#   Temperature No. 0 Celsius: 22
#   1800W PSU Vac: 0.1
#   FAN No. X RPM: YYYY  (si disponible)
parse_cli_data() {
    [[ ! -f "$CLI_OUTPUT" ]] && return 1

    # Températures - le format est "Temperature No. X Celsius: YY"
    # Avec cut -d " " -f 5, on obtient "22" pour "Temperature No. 0 Celsius: 22"
    local in_t out_t psu_t1 psu_t2 psu_t3

    # Essayer le format "Celsius: XX" d'abord
    in_t=$(grep "Temperature No. 0" "$CLI_OUTPUT" 2>/dev/null | grep -oP ':\s*\K[0-9.]+')
    out_t=$(grep "Temperature No. 1" "$CLI_OUTPUT" 2>/dev/null | grep -oP ':\s*\K[0-9.]+')

    # Fallback: essayer le format ancien "Temperature No. 0 : XX"
    if [[ -z "$in_t" ]]; then
        in_t=$(grep "Temperature No. 0" "$CLI_OUTPUT" 2>/dev/null | awk '{print $NF}')
    fi
    if [[ -z "$out_t" ]]; then
        out_t=$(grep "Temperature No. 1" "$CLI_OUTPUT" 2>/dev/null | awk '{print $NF}')
    fi

    # PSU Temperatures - format "1800W PSU T1: 0.0"
    psu_t1=$(grep "PSU T1:" "$CLI_OUTPUT" 2>/dev/null | grep -oP 'T1:\s*\K[0-9.]+')
    psu_t2=$(grep "PSU T2:" "$CLI_OUTPUT" 2>/dev/null | grep -oP 'T2:\s*\K[0-9.]+')
    psu_t3=$(grep "PSU T3:" "$CLI_OUTPUT" 2>/dev/null | grep -oP 'T3:\s*\K[0-9.]+')

    # Filtrer les valeurs aberrantes (>200 = capteur absent)
    [[ -n "$in_t" ]] && (( $(echo "$in_t > 200" | bc -l 2>/dev/null || echo 0) )) && in_t=""
    [[ -n "$out_t" ]] && (( $(echo "$out_t > 200" | bc -l 2>/dev/null || echo 0) )) && out_t=""
    [[ -n "$psu_t1" ]] && (( $(echo "$psu_t1 > 200" | bc -l 2>/dev/null || echo 0) )) && psu_t1=""
    [[ -n "$psu_t2" ]] && (( $(echo "$psu_t2 > 200" | bc -l 2>/dev/null || echo 0) )) && psu_t2=""
    [[ -n "$psu_t3" ]] && (( $(echo "$psu_t3 > 200" | bc -l 2>/dev/null || echo 0) )) && psu_t3=""

    TEMPS=("${in_t:-N/A}" "${out_t:-N/A}" "${psu_t2:-N/A}" "${psu_t1:-N/A}" "${psu_t3:-N/A}")

    # PSU - format "1800W PSU Vac: 0.1"
    PSU_VAC=$(grep "PSU Vac:" "$CLI_OUTPUT" 2>/dev/null | grep -oP 'Vac:\s*\K[0-9.]+')
    PSU_PAC=$(grep "PSU Pac:" "$CLI_OUTPUT" 2>/dev/null | grep -oP 'Pac:\s*\K[0-9.]+')
    PSU_VDC=$(grep "PSU Vdc:" "$CLI_OUTPUT" 2>/dev/null | grep -oP 'Vdc:\s*\K[0-9.]+')
    PSU_VAC=${PSU_VAC:-N/A}
    PSU_PAC=${PSU_PAC:-N/A}
    PSU_VDC=${PSU_VDC:-N/A}

    # Fans RPM et pourcentages - peut ne pas exister selon la version FW
    for i in $(seq 0 $((NUM_FANS - 1))); do
        local port
        port=$(get_fan_port "$i")

        local rpm_line
        rpm_line=$(grep "FAN No. $port RPM:" "$CLI_OUTPUT" 2>/dev/null | head -1)
        if [[ -n "$rpm_line" ]]; then
            FAN_RPM[$i]=$(echo "$rpm_line" | grep -oP 'RPM:\s*\K[0-9]+')
            FAN_RPM[$i]=${FAN_RPM[$i]:-"--"}
        fi

        local pct_line
        pct_line=$(grep "FAN No. $port RPM in percent:" "$CLI_OUTPUT" 2>/dev/null)
        if [[ -n "$pct_line" ]]; then
            local pct
            pct=$(echo "$pct_line" | grep -oP 'percent:\s*\K[0-9]+')
            [[ -n "$pct" ]] && CURRENT_SPEEDS[$i]=$pct
        fi

        local max_line
        max_line=$(grep "FAN No. $port max RPM:" "$CLI_OUTPUT" 2>/dev/null)
        if [[ -n "$max_line" ]]; then
            FAN_MAX_RPM[$i]=$(echo "$max_line" | grep -oP 'max RPM:\s*\K[0-9]+')
            FAN_MAX_RPM[$i]=${FAN_MAX_RPM[$i]:-"--"}
        fi
    done
}

# Appliquer la vitesse d'un fan
apply_fan_speed() {
    local fan_idx=$1
    local speed_pct=$2

    if [[ $HW_DETECTED -eq 0 ]]; then
        CURRENT_SPEEDS[$fan_idx]=$speed_pct
        return 0
    fi

    check_maintenance || return 1

    local port pwm
    port=$(get_fan_port "$fan_idx")
    pwm=$(percent_to_pwm "$speed_pct" "$fan_idx")
    $OCTOFAN_BIN -f "$port" -v "$pwm" &>/dev/null
    CURRENT_SPEEDS[$fan_idx]=$speed_pct
    log_msg "FAN$fan_idx port=$port -> ${speed_pct}% PWM=$pwm"
}

apply_all_fans_speed() {
    local speed=$1
    for i in $(seq 0 $((NUM_FANS - 1))); do
        apply_fan_speed "$i" "$speed"
        sleep 0.1
    done
}

set_led() {
    local led=$1
    local mode=$2
    [[ $HW_DETECTED -eq 1 ]] && $OCTOFAN_BIN -l "$led" -v "$mode" &>/dev/null
}

recalibrate_fans() {
    show_msg "Recalibration des fans en cours..."

    if [[ $HW_DETECTED -eq 0 ]]; then
        show_msg "Pas de materiel detecte"
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') - recalibrate fans" > "$MAINTENANCE_SEM"

    for i in $(seq 0 $((NUM_FANS - 1))); do
        local port
        port=$(get_fan_port "$i")
        $OCTOFAN_BIN -f "$port" -v 255 &>/dev/null
        sleep 0.1
    done

    sleep 5

    local fans_max_rpm=()
    for t in $(seq 1 10); do
        $OCTOFAN_BIN -r > "$CLI_OUTPUT" 2>/dev/null
        for i in $(seq 0 $((NUM_FANS - 1))); do
            local port t_rpm
            port=$(get_fan_port "$i")
            t_rpm=$(grep "FAN No. $port RPM:" "$CLI_OUTPUT" 2>/dev/null | head -1 | grep -oP 'RPM:\s*\K[0-9]+')
            t_rpm=${t_rpm:-0}
            [[ ${fans_max_rpm[$i]:-0} -lt $t_rpm ]] && fans_max_rpm[$i]=$t_rpm
            sleep 0.1
        done
        sleep 0.7
    done

    for i in $(seq 0 $((NUM_FANS - 1))); do
        local port
        port=$(get_fan_port "$i")
        local rpm=${fans_max_rpm[$i]:-0}
        $OCTOFAN_BIN -m "$port" -v "$rpm" &>/dev/null
        FAN_MAX_RPM[$i]=$rpm
        sleep 0.1
    done

    $OCTOFAN_BIN -r > "$CLI_OUTPUT" 2>/dev/null
    rm -f "$MAINTENANCE_SEM"
    show_msg "Recalibration terminee - Max RPM: ${fans_max_rpm[*]}"
}

################################################################################
# SCAN DES PORTS - Identifier quels ports controlent des fans reels
################################################################################

scan_ports() {
    if [[ $HW_DETECTED -eq 0 ]]; then
        show_msg "Pas de materiel detecte - scan impossible"
        return 1
    fi

    local TEST_SPEED_PCT=40
    local TEST_PWM
    TEST_PWM=$(percent_to_pwm "$TEST_SPEED_PCT")
    local STOP_PWM=0
    local MAX_PORT=11
    local detected_ports=()

    clear_screen
    draw_double_line 70
    echo -e "${BOLD}${CYAN}  SCAN DES PORTS FAN${NOCOLOR}"
    draw_double_line 70
    echo ""
    echo -e "  Ce test va activer chaque port (0-${MAX_PORT}) a ${TEST_SPEED_PCT}%"
    echo -e "  un par un pendant 4 secondes."
    echo -e "  ${YELLOW}Regarde/ecoute quel fan tourne pour chaque port.${NOCOLOR}"
    echo ""
    echo -e "  Commandes pendant le test:"
    echo -e "    ${GREEN}o${NOCOLOR} = OUI, ce port a un fan qui tourne"
    echo -e "    ${RED}n${NOCOLOR} = NON, rien ne bouge"
    echo -e "    ${CYAN}Enter${NOCOLOR} = NON (par defaut)"
    echo -e "    ${YELLOW}q${NOCOLOR} = Annuler le scan"
    echo ""
    draw_line 70
    echo -e "  ${DIM}Appuyez sur une touche pour commencer le scan...${NOCOLOR}"
    read -rsn1 start_key
    [[ "$start_key" == "q" || "$start_key" == "Q" ]] && { show_msg "Scan annule"; return 0; }

    # D'abord, tout eteindre
    echo ""
    echo -e "  ${DIM}Arret de tous les ports...${NOCOLOR}"
    for port in $(seq 0 $MAX_PORT); do
        $OCTOFAN_BIN -f "$port" -v $STOP_PWM &>/dev/null
        sleep 0.05
    done
    sleep 2

    # Scanner chaque port
    for port in $(seq 0 $MAX_PORT); do
        echo ""
        echo -e "  ${BOLD}${YELLOW}>>> Test PORT $port ${NOCOLOR}${DIM}(${TEST_SPEED_PCT}% pendant 4s)${NOCOLOR}"

        # Activer ce port
        $OCTOFAN_BIN -f "$port" -v "$TEST_PWM" &>/dev/null

        # Attendre 4 secondes avec countdown
        for countdown in 4 3 2 1; do
            echo -ne "\r  ${DIM}    Ecoute... ${countdown}s restantes  ${NOCOLOR}"
            sleep 1
        done
        echo ""

        # Couper ce port
        $OCTOFAN_BIN -f "$port" -v $STOP_PWM &>/dev/null

        # Demander confirmation
        echo -ne "  ${CYAN}  Port $port: un fan a tourne ? (${GREEN}o${CYAN}=oui / ${RED}n${CYAN}=non / ${YELLOW}q${CYAN}=quitter): ${NOCOLOR}"
        read -rsn1 answer
        echo ""

        case "$answer" in
            o|O|y|Y)
                detected_ports+=("$port")
                echo -e "  ${GREEN}  -> Port $port: FAN DETECTE${NOCOLOR}"
                ;;
            q|Q)
                echo -e "  ${YELLOW}  Scan interrompu.${NOCOLOR}"
                break
                ;;
            *)
                echo -e "  ${DIM}  -> Port $port: rien${NOCOLOR}"
                ;;
        esac

        sleep 0.5
    done

    # Afficher le resultat
    echo ""
    draw_line 70
    echo -e "  ${BOLD}${GREEN}RESULTAT DU SCAN${NOCOLOR}"
    draw_line 70

    if [[ ${#detected_ports[@]} -eq 0 ]]; then
        echo -e "  ${RED}Aucun port detecte ! Verifier le branchement.${NOCOLOR}"
    else
        echo -e "  ${GREEN}Ports avec fan: ${detected_ports[*]}${NOCOLOR}"
        echo ""

        # Proposer d'appliquer automatiquement
        if [[ ${#detected_ports[@]} -ge 1 ]]; then
            echo -e "  ${CYAN}Appliquer ces ports comme configuration ?${NOCOLOR}"
            echo -e "    ${GREEN}o${NOCOLOR} = Oui, utiliser ces ports"
            echo -e "    ${RED}n${NOCOLOR} = Non, garder la config actuelle"
            echo -ne "  Choix: "
            read -rsn1 apply_choice
            echo ""

            if [[ "$apply_choice" == "o" || "$apply_choice" == "O" || "$apply_choice" == "y" || "$apply_choice" == "Y" ]]; then
                # Appliquer les ports detectes (max 4 fans supportes)
                local num_detected=${#detected_ports[@]}
                [[ $num_detected -gt 4 ]] && num_detected=4
                NUM_FANS=$num_detected

                [[ $num_detected -ge 1 ]] && FAN0_PORT=${detected_ports[0]}
                [[ $num_detected -ge 2 ]] && FAN1_PORT=${detected_ports[1]}
                [[ $num_detected -ge 3 ]] && FAN2_PORT=${detected_ports[2]}
                [[ $num_detected -ge 4 ]] && FAN3_PORT=${detected_ports[3]}

                # Reinitialiser les tableaux
                CURRENT_SPEEDS=()
                FAN_RPM=()
                FAN_MAX_RPM=()
                FAN_PWM_FACTORS=()
                for i in $(seq 0 $((NUM_FANS - 1))); do
                    CURRENT_SPEEDS+=($MANUAL_FAN)
                    FAN_RPM+=("--")
                    FAN_MAX_RPM+=("--")
                    FAN_PWM_FACTORS+=($FAN_PWM_FACTOR)
                done

                show_msg "Config appliquee: ${NUM_FANS} fans, ports: ${detected_ports[*]}"
                echo -e "  ${GREEN}Configuration mise a jour !${NOCOLOR}"
                echo -e "  NUM_FANS=$NUM_FANS"
                echo -e "  Ports: ${detected_ports[*]}"

                # Remettre les fans detectes en marche
                apply_all_fans_speed "$MANUAL_FAN"
            else
                show_msg "Scan termine - config non modifiee"
            fi
        fi
    fi

    # Remettre tous les fans actifs
    echo ""
    echo -e "  ${DIM}Remise en marche des fans...${NOCOLOR}"
    apply_all_fans_speed "$MANUAL_FAN"

    echo ""
    draw_line 70
    echo -e "  ${DIM}Appuyez sur une touche pour revenir...${NOCOLOR}"
    read -rsn1
}

################################################################################
# SAUVEGARDE / CHARGEMENT DE CONFIG
################################################################################

save_config() {
    cat > "$MANAGER_CONF" <<EOF
AUTO_ENABLED=$AUTO_ENABLED
MANUAL_FAN=$MANUAL_FAN
MIN_FAN=$MIN_FAN
MAX_FAN=$MAX_FAN
TARGET_TEMP=$TARGET_TEMP
REFRESH_INTERVAL=$REFRESH_INTERVAL
FAN0_PORT=$FAN0_PORT
FAN1_PORT=$FAN1_PORT
FAN2_PORT=$FAN2_PORT
FAN3_PORT=$FAN3_PORT
NUM_FANS=$NUM_FANS
FAN_PWM_FACTOR=$FAN_PWM_FACTOR
EOF
    show_msg "Configuration sauvegardee dans $MANAGER_CONF"
}

load_config() {
    [[ -f "$OCTOFAN_CONF" ]] && source "$OCTOFAN_CONF" 2>/dev/null
    if [[ -f "$MANAGER_CONF" ]]; then
        source "$MANAGER_CONF" 2>/dev/null
        show_msg "Config chargee"
    fi
}

################################################################################
# AFFICHAGE
################################################################################

clear_screen() {
    printf '\033[2J\033[H'
}

draw_line() {
    local width=${1:-70}
    echo -ne "${DIM}"
    printf '%.0s-' $(seq 1 "$width")
    echo -e "${NOCOLOR}"
}

draw_double_line() {
    local width=${1:-70}
    echo -ne "${CYAN}"
    printf '%.0s=' $(seq 1 "$width")
    echo -e "${NOCOLOR}"
}

speed_bar() {
    local pct=$1
    local width=20
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local color

    if [[ $pct -ge 80 ]]; then
        color=$RED
    elif [[ $pct -ge 50 ]]; then
        color=$YELLOW
    else
        color=$GREEN
    fi

    echo -ne "${color}["
    if [[ $filled -gt 0 ]]; then
        printf '%.0s#' $(seq 1 "$filled")
    fi
    if [[ $empty -gt 0 ]]; then
        echo -ne "${DIM}"
        printf '%.0s.' $(seq 1 "$empty")
        echo -ne "${NOCOLOR}${color}"
    fi
    echo -ne "]${NOCOLOR}"
}

color_temp() {
    local temp=$1
    if [[ "$temp" == "N/A" || -z "$temp" ]]; then
        echo -ne "${DIM}N/A${NOCOLOR}"
        return
    fi

    local t=${temp%.*}
    t=${t:-0}

    if [[ $t -ge 80 ]]; then
        echo -ne "${RED}${BOLD}${temp} C${NOCOLOR}"
    elif [[ $t -ge 65 ]]; then
        echo -ne "${YELLOW}${temp} C${NOCOLOR}"
    elif [[ $t -ge 40 ]]; then
        echo -ne "${GREEN}${temp} C${NOCOLOR}"
    else
        echo -ne "${CYAN}${temp} C${NOCOLOR}"
    fi
}

draw_dashboard() {
    clear_screen

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    draw_double_line 70
    echo -e "${BOLD}${CYAN}  OCTOFAN MANAGER${NOCOLOR}                            ${DIM}$now${NOCOLOR}"
    draw_double_line 70

    # Statut hardware
    if [[ $HW_DETECTED -eq 1 ]]; then
        echo -ne "  ${GREEN}*${NOCOLOR} Octofan ${GREEN}DETECTE${NOCOLOR}"
        [[ -n "$HW_VERSION" ]] && echo -ne " ${DIM}HW:$HW_VERSION FW:$FW_VERSION CLI:$CLI_VERSION${NOCOLOR}"
    else
        echo -ne "  ${YELLOW}*${NOCOLOR} Mode ${YELLOW}SIMULATION${NOCOLOR}"
    fi

    # Mode
    if [[ $AUTO_ENABLED -eq 1 ]]; then
        echo -e "  ${CYAN}[AUTO]${NOCOLOR} Cible: ${BOLD}${TARGET_TEMP}C${NOCOLOR}"
    else
        echo -e "  ${PURPLE}[MANUEL]${NOCOLOR} Vitesse: ${BOLD}${MANUAL_FAN}%%${NOCOLOR}"
    fi

    draw_line 70

    # Section FANS
    echo -e "\n  ${BOLD}${WHITE}VENTILATEURS${NOCOLOR}"
    echo -e "  FAN      VITESSE                              RPM      MAX RPM"
    draw_line 70

    for i in $(seq 0 $((NUM_FANS - 1))); do
        local sel_marker=" "
        if [[ "$SELECTED_FAN" == "$i" ]]; then
            sel_marker=">"
        elif [[ "$SELECTED_FAN" == "all" ]]; then
            sel_marker="*"
        fi

        local pct=${CURRENT_SPEEDS[$i]:-0}
        local rpm=${FAN_RPM[$i]:---}
        local max_rpm=${FAN_MAX_RPM[$i]:---}
        local port
        port=$(get_fan_port "$i")

        echo -ne " ${sel_marker} FAN${i}   ${BOLD}$(printf '%3d' "$pct")%%${NOCOLOR}  "
        speed_bar "$pct"
        echo -e "  $(printf '%6s' "$rpm")   $(printf '%6s' "$max_rpm")"
    done

    echo -e "\n  ${DIM}Plage: ${MIN_FAN}%% - ${MAX_FAN}%%   |   Ports: ${FAN0_PORT}, ${FAN1_PORT}, ${FAN2_PORT}, ${FAN3_PORT}${NOCOLOR}"

    draw_line 70

    # Section TEMPERATURES
    echo -e "\n  ${BOLD}${WHITE}TEMPERATURES${NOCOLOR}"
    echo -ne "  Entree (Intake)  : "; color_temp "${TEMPS[0]:-N/A}"; echo
    echo -ne "  Sortie (Outgoing): "; color_temp "${TEMPS[1]:-N/A}"; echo

    local show_psu_temp=0
    for idx in 2 3 4; do
        [[ "${TEMPS[$idx]:-N/A}" != "N/A" ]] && show_psu_temp=1
    done

    if [[ $show_psu_temp -eq 1 ]]; then
        echo -ne "  PSU Entree       : "; color_temp "${TEMPS[2]:-N/A}"; echo
        echo -ne "  PSU Sortie       : "; color_temp "${TEMPS[3]:-N/A}"; echo
        echo -ne "  PSU Carte        : "; color_temp "${TEMPS[4]:-N/A}"; echo
    fi

    draw_line 70

    # Section PSU
    local show_psu=0
    [[ "$PSU_VAC" != "N/A" && "$PSU_VAC" != "0" ]] && show_psu=1
    [[ "$PSU_PAC" != "N/A" && "$PSU_PAC" != "0" ]] && show_psu=1

    if [[ $show_psu -eq 1 ]]; then
        echo -e "\n  ${BOLD}${WHITE}ALIMENTATION (PSU)${NOCOLOR}"
        echo -e "  AC: ${BOLD}${PSU_VAC}V${NOCOLOR}  |  Puissance: ${BOLD}${YELLOW}${PSU_PAC}W${NOCOLOR}  |  DC: ${BOLD}${PSU_VDC}V${NOCOLOR}"
        draw_line 70
    fi

    # Message de dernière commande
    echo ""
    local msg_age=$(( $(date +%s) - LAST_CMD_TIME ))
    if [[ -n "$LAST_CMD_MSG" && $msg_age -lt 10 ]]; then
        echo -e "  ${GREEN}> ${LAST_CMD_MSG}${NOCOLOR}"
    fi

    # Menu rapide
    echo ""
    draw_line 70
    echo -e "  ${BOLD}COMMANDES${NOCOLOR}"
    echo -e "  ${CYAN}h${NOCOLOR}=aide  ${CYAN}a${NOCOLOR}=auto/manuel  ${CYAN}+/-${NOCOLOR}=vitesse  ${CYAN}0-9${NOCOLOR}=vitesse directe"
    echo -e "  ${CYAN}f${NOCOLOR}=select.fan  ${CYAN}t${NOCOLOR}=temp.cible  ${CYAN}b${NOCOLOR}=scan ports  ${CYAN}s${NOCOLOR}=sauver  ${CYAN}q${NOCOLOR}=quitter"
    draw_double_line 70
    echo -ne "  ${DIM}Refresh dans ${REFRESH_INTERVAL}s | Commande: ${NOCOLOR}"
}

show_help() {
    clear_screen
    draw_double_line 70
    echo -e "${BOLD}${CYAN}  AIDE - OCTOFAN MANAGER${NOCOLOR}"
    draw_double_line 70
    echo ""
    echo -e "  ${BOLD}CONTROLE DES FANS${NOCOLOR}"
    echo -e "  ${CYAN}a${NOCOLOR}         Basculer mode AUTO / MANUEL"
    echo -e "  ${CYAN}0-9${NOCOLOR}       Vitesse directe (x10%%, ex: 7 = 70%%)"
    echo -e "  ${CYAN}+${NOCOLOR}         Augmenter la vitesse de 5%%"
    echo -e "  ${CYAN}-${NOCOLOR}         Diminuer la vitesse de 5%%"
    echo -e "  ${CYAN}f${NOCOLOR}         Changer la selection de fan (all/0/1/2/3)"
    echo -e "  ${CYAN}m${NOCOLOR}         Tous les fans a 100%% (MAX)"
    echo -e "  ${CYAN}n${NOCOLOR}         Tous les fans au minimum"
    echo ""
    echo -e "  ${BOLD}CONFIGURATION${NOCOLOR}"
    echo -e "  ${CYAN}t${NOCOLOR}         Definir la temperature cible"
    echo -e "  ${CYAN}i${NOCOLOR}         Definir la vitesse minimale"
    echo -e "  ${CYAN}x${NOCOLOR}         Definir la vitesse maximale"
    echo -e "  ${CYAN}p${NOCOLOR}         Modifier les ports de fans"
    echo -e "  ${CYAN}d${NOCOLOR}         Modifier l'intervalle de refresh"
    echo ""
    echo -e "  ${BOLD}ACTIONS${NOCOLOR}"
    echo -e "  ${CYAN}b${NOCOLOR}         Scanner les ports (identifier les vrais fans)"
    echo -e "  ${CYAN}r${NOCOLOR}         Recalibrer les fans"
    echo -e "  ${CYAN}l${NOCOLOR}         Controle LED (on/off/blink)"
    echo -e "  ${CYAN}s${NOCOLOR}         Sauvegarder la configuration"
    echo -e "  ${CYAN}c${NOCOLOR}         Afficher la sortie CLI brute"
    echo -e "  ${CYAN}w${NOCOLOR}         Afficher le log"
    echo ""
    echo -e "  ${BOLD}GENERAL${NOCOLOR}"
    echo -e "  ${CYAN}h${NOCOLOR}         Afficher cette aide"
    echo -e "  ${CYAN}q${NOCOLOR}         Quitter le manager"
    echo ""
    draw_line 70
    echo -e "  ${DIM}Appuyez sur une touche pour revenir...${NOCOLOR}"
    read -rsn1
}

################################################################################
# LOGIQUE AUTO-FAN
################################################################################

auto_fan_control() {
    [[ $AUTO_ENABLED -ne 1 ]] && return

    local intake_temp="${TEMPS[0]:-}"
    if [[ -z "$intake_temp" || "$intake_temp" == "N/A" ]]; then
        # Pas de temperature disponible -> securite: MAX
        apply_all_fans_speed "$MAX_FAN"
        return
    fi

    local t=${intake_temp%.*}
    t=${t:-0}

    local new_speed
    local sum=0
    for i in $(seq 0 $((NUM_FANS - 1))); do
        sum=$(( sum + CURRENT_SPEEDS[$i] ))
    done
    local current_avg=$(( sum / NUM_FANS ))

    if [[ $t -ge $(( TARGET_TEMP + 15 )) ]]; then
        new_speed=100
    elif [[ $t -ge $(( TARGET_TEMP + 10 )) ]]; then
        new_speed=90
    elif [[ $t -ge $(( TARGET_TEMP + 5 )) ]]; then
        new_speed=80
    elif [[ $t -ge $TARGET_TEMP ]]; then
        local diff=$(( t - TARGET_TEMP ))
        new_speed=$(( current_avg + diff * FAN_INC_SPEED_STEP ))
    elif [[ $t -ge $(( TARGET_TEMP - 5 )) ]]; then
        new_speed=$current_avg
    elif [[ $t -ge $(( TARGET_TEMP - 10 )) ]]; then
        new_speed=$(( current_avg - FAN_INC_SPEED_STEP ))
    else
        new_speed=$MIN_FAN
    fi

    [[ $new_speed -gt $MAX_FAN ]] && new_speed=$MAX_FAN
    [[ $new_speed -lt $MIN_FAN ]] && new_speed=$MIN_FAN
    [[ $new_speed -gt 100 ]] && new_speed=100

    # Fan 0 recoit +10%% pour compenser la chaleur CPU/PSU
    local fan0_speed=$(( new_speed + 10 ))
    [[ $fan0_speed -gt 100 ]] && fan0_speed=100
    [[ $fan0_speed -gt $MAX_FAN ]] && fan0_speed=$MAX_FAN

    apply_fan_speed 0 "$fan0_speed"
    for i in $(seq 1 $((NUM_FANS - 1))); do
        apply_fan_speed $i "$new_speed"
    done
    sleep 0.1
}

################################################################################
# TRAITEMENT DES COMMANDES
################################################################################

set_speed_for_selection() {
    local speed=$1
    [[ $speed -gt 100 ]] && speed=100
    [[ $speed -lt 0 ]] && speed=0

    if [[ "$SELECTED_FAN" == "all" ]]; then
        apply_all_fans_speed "$speed"
        MANUAL_FAN=$speed
        show_msg "Tous les fans regles a ${speed}%%"
    else
        apply_fan_speed "$SELECTED_FAN" "$speed"
        show_msg "FAN${SELECTED_FAN} regle a ${speed}%%"
    fi
}

get_current_speed() {
    if [[ "$SELECTED_FAN" == "all" ]]; then
        local sum=0
        for i in $(seq 0 $((NUM_FANS - 1))); do
            sum=$(( sum + CURRENT_SPEEDS[$i] ))
        done
        echo $(( sum / NUM_FANS ))
    else
        echo "${CURRENT_SPEEDS[$SELECTED_FAN]}"
    fi
}

process_command() {
    local cmd="$1"

    case "$cmd" in
        h|H|\?)
            show_help
            ;;
        q|Q)
            RUNNING=0
            ;;
        a|A)
            if [[ $AUTO_ENABLED -eq 1 ]]; then
                AUTO_ENABLED=0
                show_msg "Mode MANUEL active - vitesse: ${MANUAL_FAN}%%"
                apply_all_fans_speed "$MANUAL_FAN"
            else
                AUTO_ENABLED=1
                show_msg "Mode AUTO active - cible: ${TARGET_TEMP}C"
            fi
            ;;
        [0-9])
            AUTO_ENABLED=0
            local speed=$(( cmd * 10 ))
            [[ $speed -eq 0 ]] && speed=100
            set_speed_for_selection "$speed"
            ;;
        +|=)
            AUTO_ENABLED=0
            local cur
            cur=$(get_current_speed)
            set_speed_for_selection $(( cur + 5 ))
            ;;
        -|_)
            AUTO_ENABLED=0
            local cur
            cur=$(get_current_speed)
            set_speed_for_selection $(( cur - 5 ))
            ;;
        f|F)
            case "$SELECTED_FAN" in
                all) SELECTED_FAN=0; show_msg "Fan selectionne: FAN0" ;;
                0) SELECTED_FAN=1; show_msg "Fan selectionne: FAN1" ;;
                1) SELECTED_FAN=2; show_msg "Fan selectionne: FAN2" ;;
                2) SELECTED_FAN=3; show_msg "Fan selectionne: FAN3" ;;
                3) SELECTED_FAN="all"; show_msg "Fan selectionne: TOUS" ;;
            esac
            ;;
        m|M)
            AUTO_ENABLED=0
            apply_all_fans_speed 100
            MANUAL_FAN=100
            show_msg "Tous les fans a 100%% MAX"
            ;;
        n|N)
            AUTO_ENABLED=0
            apply_all_fans_speed "$MIN_FAN"
            MANUAL_FAN=$MIN_FAN
            show_msg "Tous les fans au minimum ${MIN_FAN}%%"
            ;;
        t|T)
            echo ""
            echo -e "  ${CYAN}Temperature cible actuelle: ${TARGET_TEMP}C${NOCOLOR}"
            echo -ne "  Nouvelle valeur (30-90): "
            read -r new_temp
            if [[ "$new_temp" =~ ^[0-9]+$ ]] && [[ $new_temp -ge 30 ]] && [[ $new_temp -le 90 ]]; then
                TARGET_TEMP=$new_temp
                show_msg "Temperature cible: ${TARGET_TEMP}C"
            else
                show_msg "Valeur invalide, entrer 30-90"
            fi
            ;;
        i|I)
            echo ""
            echo -e "  ${CYAN}Vitesse minimale actuelle: ${MIN_FAN}%%${NOCOLOR}"
            echo -ne "  Nouvelle valeur (0-100): "
            read -r new_min
            if [[ "$new_min" =~ ^[0-9]+$ ]] && [[ $new_min -ge 0 ]] && [[ $new_min -le 100 ]]; then
                MIN_FAN=$new_min
                show_msg "Vitesse minimale: ${MIN_FAN}%%"
            else
                show_msg "Valeur invalide, entrer 0-100"
            fi
            ;;
        x|X)
            echo ""
            echo -e "  ${CYAN}Vitesse maximale actuelle: ${MAX_FAN}%%${NOCOLOR}"
            echo -ne "  Nouvelle valeur (0-100): "
            read -r new_max
            if [[ "$new_max" =~ ^[0-9]+$ ]] && [[ $new_max -ge 0 ]] && [[ $new_max -le 100 ]]; then
                MAX_FAN=$new_max
                show_msg "Vitesse maximale: ${MAX_FAN}%%"
            else
                show_msg "Valeur invalide, entrer 0-100"
            fi
            ;;
        p|P)
            echo ""
            echo -e "  ${CYAN}Ports actuels: FAN0=${FAN0_PORT}, FAN1=${FAN1_PORT}, FAN2=${FAN2_PORT}, FAN3=${FAN3_PORT}${NOCOLOR}"
            echo -ne "  Port FAN0 (Enter=garder): "; read -r p0
            [[ -n "$p0" ]] && FAN0_PORT=$p0
            echo -ne "  Port FAN1 (Enter=garder): "; read -r p1
            [[ -n "$p1" ]] && FAN1_PORT=$p1
            echo -ne "  Port FAN2 (Enter=garder): "; read -r p2
            [[ -n "$p2" ]] && FAN2_PORT=$p2
            echo -ne "  Port FAN3 (Enter=garder): "; read -r p3
            [[ -n "$p3" ]] && FAN3_PORT=$p3
            show_msg "Ports: ${FAN0_PORT}, ${FAN1_PORT}, ${FAN2_PORT}, ${FAN3_PORT}"
            ;;
        d|D)
            echo ""
            echo -e "  ${CYAN}Intervalle actuel: ${REFRESH_INTERVAL}s${NOCOLOR}"
            echo -ne "  Nouvelle valeur (1-60): "
            read -r new_int
            if [[ "$new_int" =~ ^[0-9]+$ ]] && [[ $new_int -ge 1 ]] && [[ $new_int -le 60 ]]; then
                REFRESH_INTERVAL=$new_int
                show_msg "Intervalle: ${REFRESH_INTERVAL}s"
            else
                show_msg "Valeur invalide, entrer 1-60"
            fi
            ;;
        b|B)
            scan_ports
            ;;
        r|R)
            recalibrate_fans
            ;;
        l|L)
            echo ""
            echo -e "  ${CYAN}Controle LED${NOCOLOR}"
            echo -e "  ${CYAN}1${NOCOLOR}=LED Orange ON  ${CYAN}2${NOCOLOR}=LED Bleue ON  ${CYAN}3${NOCOLOR}=LED Blanche ON"
            echo -e "  ${CYAN}4${NOCOLOR}=Blink rapide   ${CYAN}5${NOCOLOR}=Blink lent    ${CYAN}0${NOCOLOR}=Toutes OFF"
            echo -ne "  Choix: "
            read -rsn1 led_cmd
            echo
            case "$led_cmd" in
                1) set_led 0 1; show_msg "LED Orange allumee" ;;
                2) set_led 1 1; show_msg "LED Bleue allumee" ;;
                3) set_led 2 1; show_msg "LED Blanche allumee" ;;
                4) for l in 0 1 2; do set_led "$l" 2; done; show_msg "Toutes LED blink rapide" ;;
                5) for l in 0 1 2; do set_led "$l" 3; done; show_msg "Toutes LED blink lent" ;;
                0) for l in 0 1 2; do set_led "$l" 0; done; show_msg "Toutes LED eteintes" ;;
                *) show_msg "Commande LED invalide" ;;
            esac
            ;;
        s|S)
            save_config
            ;;
        c|C)
            if [[ -f "$CLI_OUTPUT" ]]; then
                clear_screen
                echo -e "${BOLD}${CYAN}  SORTIE CLI BRUTE${NOCOLOR}"
                draw_line 70
                cat "$CLI_OUTPUT"
                draw_line 70
                echo -e "\n  ${DIM}Appuyez sur une touche pour revenir...${NOCOLOR}"
                read -rsn1
            else
                show_msg "Pas de donnees CLI"
            fi
            ;;
        w|W)
            if [[ -f "$LOG_FILE" ]]; then
                clear_screen
                echo -e "${BOLD}${CYAN}  LOG (30 dernieres lignes)${NOCOLOR}"
                draw_line 70
                tail -30 "$LOG_FILE"
                draw_line 70
                echo -e "\n  ${DIM}Appuyez sur une touche pour revenir...${NOCOLOR}"
                read -rsn1
            else
                show_msg "Pas de log"
            fi
            ;;
        "")
            ;;
        *)
            show_msg "Commande inconnue: $cmd - tapez h pour aide"
            ;;
    esac
}

################################################################################
# GESTION PROPRE DE L'ARRET
################################################################################

cleanup() {
    echo ""
    echo -e "${YELLOW}Arret du manager...${NOCOLOR}"

    if [[ $HW_DETECTED -eq 1 ]]; then
        echo -e "Fans regles a ${MAX_FAN}%% par securite..."
        apply_all_fans_speed "$MAX_FAN"
    fi

    save_config 2>/dev/null
    log_msg "Manager arrete"
    echo -e "${GREEN}Manager arrete. Fans a ${MAX_FAN}%%.${NOCOLOR}"
    exit 0
}

trap cleanup SIGINT SIGTERM

################################################################################
# BOUCLE PRINCIPALE
################################################################################

main() {
    log_msg "=== Demarrage octofan-manager ==="

    load_config
    detect_hardware

    if [[ $HW_DETECTED -eq 1 ]]; then
        log_msg "Octofan detecte HW:$HW_VERSION FW:$FW_VERSION CLI:$CLI_VERSION"
        parse_cli_data
        # Securite: fans a MANUAL_FAN au demarrage
        apply_all_fans_speed "$MANUAL_FAN"
        CURRENT_SPEEDS=($MANUAL_FAN $MANUAL_FAN $MANUAL_FAN $MANUAL_FAN)
        log_msg "Fans initialises a ${MANUAL_FAN}%%"
    else
        log_msg "Pas de materiel Octofan - mode simulation"
        CURRENT_SPEEDS=(50 50 50 50)
        TEMPS=(42 48 35 40 38)
        PSU_VAC=230
        PSU_PAC=850
        PSU_VDC=12
    fi

    while [[ $RUNNING -eq 1 ]]; do
        # Lire les données hardware
        if [[ $HW_DETECTED -eq 1 ]]; then
            read_cli_data
            parse_cli_data
        fi

        # Contrôle auto des fans
        [[ $AUTO_ENABLED -eq 1 ]] && auto_fan_control

        # Afficher le dashboard
        draw_dashboard

        # Attendre une commande
        local cmd=""
        read -rsn1 -t "$REFRESH_INTERVAL" cmd

        [[ -n "$cmd" ]] && process_command "$cmd"
    done

    cleanup
}

################################################################################
# POINT D'ENTREE
################################################################################

case "${1:-}" in
    --help|-h)
        echo "Usage: sudo $(basename "$0") [OPTIONS]"
        echo ""
        echo "Script interactif de gestion de ventilation Octominer."
        echo "Compatible HW v1.2 / FW 3.0 / CLI 1.7"
        echo ""
        echo "OPTIONS:"
        echo "  --help, -h     Afficher cette aide"
        echo "  --screen       Lancer dans un screen detache"
        echo "  --status       Afficher le statut et quitter"
        echo "  --set-speed N  Regler tous les fans a N%% et quitter"
        echo "  --max          Regler tous les fans a 100%% et quitter"
        echo "  --min          Regler tous les fans au minimum et quitter"
        echo ""
        echo "Lancement recommande:"
        echo "  sudo screen -S fanctl $(basename "$0")"
        echo "  (Ctrl+A, D pour detacher le screen)"
        echo ""
        exit 0
        ;;
    --screen)
        exec screen -dmS fanctl "$0"
        echo "Screen 'fanctl' demarre. Rejoindre avec: screen -r fanctl"
        exit 0
        ;;
    --status)
        detect_hardware
        load_config
        if [[ $HW_DETECTED -eq 1 ]]; then
            parse_cli_data
            echo "Hardware: Detecte HW:$HW_VERSION FW:$FW_VERSION CLI:$CLI_VERSION"
            echo "Fans: ${CURRENT_SPEEDS[0]}%% ${CURRENT_SPEEDS[1]}%% ${CURRENT_SPEEDS[2]}%%"
            echo "RPM:  ${FAN_RPM[0]} ${FAN_RPM[1]} ${FAN_RPM[2]}"
            echo "Temp: Intake=${TEMPS[0]:-N/A} Outgoing=${TEMPS[1]:-N/A}"
            echo "PSU:  ${PSU_PAC}W  ${PSU_VAC}Vac  ${PSU_VDC}Vdc"
        else
            echo "Hardware: Non detecte"
        fi
        echo "Mode: $([ $AUTO_ENABLED -eq 1 ] && echo AUTO || echo MANUEL)"
        echo "Config: Min=${MIN_FAN}%% Max=${MAX_FAN}%% Target=${TARGET_TEMP}C"
        exit 0
        ;;
    --set-speed)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: sudo $0 --set-speed <0-100>"
            exit 1
        fi
        detect_hardware
        load_config
        if [[ $HW_DETECTED -eq 1 ]]; then
            apply_all_fans_speed "$2"
            echo "Fans regles a ${2}%%"
        else
            echo "Pas de materiel detecte"
            exit 1
        fi
        exit 0
        ;;
    --max)
        detect_hardware
        load_config
        if [[ $HW_DETECTED -eq 1 ]]; then
            apply_all_fans_speed 100
            echo "Fans regles a 100%%"
        else
            echo "Pas de materiel detecte"
            exit 1
        fi
        exit 0
        ;;
    --min)
        detect_hardware
        load_config
        if [[ $HW_DETECTED -eq 1 ]]; then
            apply_all_fans_speed "$MIN_FAN"
            echo "Fans regles a ${MIN_FAN}%%"
        else
            echo "Pas de materiel detecte"
            exit 1
        fi
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "Option inconnue: $1"
        echo "Utilisez --help pour l'aide"
        exit 1
        ;;
esac
