# Dolphin Deck Bridge

Die FAP verbindet Flipper-Aktionen mit Dolphin Deck auf dem iPhone.

- **iPhone RPC:** Die iPhone-App startet die FAP und empfängt Befehle über das
  offizielle bidirektionale Application-RPC.
- **ESP32 GPIO:** Befehle werden mit 115200 Baud über USART als
  `DD1|HID|COMMAND` gesendet.

Direkt auf iOS möglich sind ein lauter lokaler Suchhinweis und
Benachrichtigungen. Sperren, Home, App-Umschalter sowie globale Mediensteuerung
stellt iOS Drittanbieter-Apps nicht als öffentliche API bereit. Diese Einträge
werden deshalb nur im ESP32-HID-Modus ausgeführt; im iPhone-Modus meldet die App
die Einschränkung zurück.

## Build

Im Ordner ausführen:

```bash
ufbt
```

Das Ergebnis liegt unter `dist/dolphin_deck_bridge.fap`.
