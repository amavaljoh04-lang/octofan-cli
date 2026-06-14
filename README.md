# Octofan CLI - Controle Ventilation Octominer

CLI simple pour controler les fans d'un boitier Octominer depuis Pop!_OS / Ubuntu / Linux.

## Installation rapide

```bash
# Telecharger
sudo curl -sL -o /usr/local/bin/fan \
  "https://raw.githubusercontent.com/hairionjohnny1982-ai/octofan-cli/main/fan"
sudo chmod +x /usr/local/bin/fan

# Installer le binaire Octofan (si pas deja fait)
sudo mkdir -p /hive/opt/octofan
sudo curl -sL -o /hive/opt/octofan/fan_controller_cli \
  "https://raw.githubusercontent.com/minershive/hiveos-linux/master/hive/opt/octofan/fan_controller_cli"
sudo chmod +x /hive/opt/octofan/fan_controller_cli
sudo apt-get install -y libusb-0.1-4

# Scanner les ports (premiere fois)
sudo fan scan

# Installer le service systemd (persiste apres reboot)
sudo fan install
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

## Fichiers

| Fichier | Description |
|---------|-------------|
| `fan` | CLI principal - commande directe |
| `octofan-manager.sh` | Version interactive avec dashboard (screen) |
| `/etc/octofan.conf` | Configuration sauvegardee (ports, vitesse) |

## Prerequis

- Linux (Pop!_OS, Ubuntu, HiveOS...)
- `libusb-0.1-4` (`sudo apt install libusb-0.1-4`)
- Boitier Octominer avec controleur USB

## Hardware supporte

- Octominer HW v1.2 / FW 3.0 / CLI 1.7
- 4 fans synchronises
- Temperatures intake/outgoing
