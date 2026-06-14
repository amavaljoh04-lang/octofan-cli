# Octofan CLI - Controle Ventilation Octominer

CLI simple pour controler les fans d'un boitier Octominer depuis Pop!_OS / Ubuntu / Linux.

Tout inclus : binaire + script + service systemd.

## Installation (une seule commande)

```bash
git clone https://github.com/amavaljoh04-lang/octofan-cli.git
cd octofan-cli
sudo bash install.sh
```

C'est tout. Ensuite scanner les ports (premiere fois) :

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

## Contenu du repo

| Fichier | Description |
|---------|-------------|
| `fan` | CLI principal - commande directe |
| `fan_controller_cli` | Binaire de controle hardware (HiveOS) |
| `install.sh` | Installeur tout-en-un |
| `octofan-manager.sh` | Version interactive avec dashboard (screen) |

## Ce que fait install.sh

1. Installe `libusb` (dependance USB)
2. Copie `fan_controller_cli` dans `/hive/opt/octofan/`
3. Copie la commande `fan` dans `/usr/local/bin/`
4. Active le service systemd (persiste apres reboot)

## Persistance

- Les ports scannes sont sauvegardes dans `/etc/octofan.conf`
- La derniere vitesse est restauree automatiquement au demarrage
- Pas besoin de re-scanner apres un reboot

## Hardware supporte

- Octominer HW v1.2 / FW 3.0 / CLI 1.7
- Jusqu'a 4 fans synchronises
- Temperatures intake/outgoing
- Pop!_OS, Ubuntu, ou tout Linux avec libusb
