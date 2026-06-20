# Octofan CLI - Controle Ventilation Octominer

CLI simple pour controler les fans d'un boitier Octominer depuis Pop!_OS / Ubuntu / Linux.

Tout inclus : binaire + firmware + script + service systemd.

## Installation (une seule commande)

```bash
git clone https://github.com/amavaljoh04-lang/octofan-cli.git
cd octofan-cli
sudo bash install.sh
```

L'installeur:
1. Installe les dependances (libusb, avrdude)
2. Copie le binaire et le firmware
3. Flash automatiquement le firmware si le controleur est vide (version 0.0)
4. Installe la commande `fan` et le service systemd

Ensuite scanner les ports (premiere fois) :

```bash
sudo fan scan
```

## Utilisation

```bash
sudo fan 30       # Tous les fans a 30%
sudo fan 50       # Tous les fans a 50%
sudo fan 100      # Tous les fans a 100%
sudo fan max      # Maximum (100%)
sudo fan min      # Minimum (30%)
sudo fan status   # Voir l'etat actuel
sudo fan auto     # Ajuster selon la temperature
sudo fan scan     # Re-scanner les ports
sudo fan help     # Aide
```

## Flash du firmware

Si le firmware du controleur est vide ou corrompu (VERSION-FW: 0.0),
le script d'installation le flash automatiquement. Pour flasher manuellement :

```bash
sudo bash flash-firmware.sh
```

Cela utilise `avrdude` pour programmer le microcontroleur ATmega324PB
via l'interface USBasp integree a la carte Octominer.

## Contenu du repo

| Fichier | Description |
|---------|-------------|
| `fan` | CLI principal - commande directe |
| `fan_controller_cli` | Binaire de controle hardware (HiveOS) |
| `install.sh` | Installeur tout-en-un |
| `flash-firmware.sh` | Script de flash firmware |
| `firmware/firmware_09.hex` | Firmware HW v0.9+ (ATmega324PB) |
| `firmware/firmware_07.hex` | Firmware HW v0.7 (ancien hardware) |
| `firmware/avrdude.conf` | Config avrdude pour USBasp |
| `octofan-manager.sh` | Version interactive avec dashboard (screen) |

## Ce que fait install.sh

1. Installe `libusb` et `avrdude` (dependances)
2. Copie `fan_controller_cli` dans `/hive/opt/octofan/`
3. Copie les firmwares dans `/hive/opt/octofan/`
4. Copie la commande `fan` dans `/usr/local/bin/`
5. Flash le firmware si le controleur est vide
6. Active le service systemd (persiste apres reboot)

## Persistance

- Les ports scannes sont sauvegardes dans `/etc/octofan.conf`
- La derniere vitesse est restauree automatiquement au demarrage
- Pas besoin de re-scanner apres un reboot

## Hardware supporte

- Octominer X8 / X12Ultra
- HW v0.7 / v0.9 / v1.2
- FW 1.1 / 1.6
- CLI 1.7
- Jusqu'a 6 fans synchronises
- Temperatures intake/outgoing
- Pop!_OS, Ubuntu, ou tout Linux avec libusb
