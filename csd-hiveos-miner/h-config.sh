#!/bin/bash
# HiveOS config script for CSD Pool Miner
# Reads wallet.conf and builds runtime configuration

cd "$(dirname "$0")"
. h-manifest.conf
[[ -e /hive-config/wallet.conf ]] && . /hive-config/wallet.conf
