#!/bin/bash
# Entfernt die fehlerhaft eingefrorene PATH-Zeile und fügt die dynamische Variante ein.
sed -i '/# rootbridge_bin$/d' ~/.bashrc
echo 'export PATH="/data/data/com.termux/files/home/bin:$PATH" # rootbridge_bin' >> ~/.bashrc
tail -3 ~/.bashrc
