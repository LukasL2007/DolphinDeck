# uFBT Build-Host

Die iOS-App kann die uFBT-/ARM-Toolchain nicht innerhalb der Apple-Sandbox
ausführen. Dieser kleine Build-Host kompiliert den ausgewählten Quellcodeordner
und gibt die erzeugte `.fap` an Dolphin Deck zurück.

## Installation

```bash
python3 -m pip install --upgrade ufbt
export UFBT_BUILD_TOKEN="ein-langes-zufälliges-passwort"
python3 Tools/ufbt_build_server.py --host 0.0.0.0 --port 8787
```

Auf dem iPhone unter **Mehr → uFBT Build & Install** die HTTPS-Adresse des
Hosts und dasselbe Token eintragen. Für die Nutzung unterwegs den Dienst nur
über HTTPS oder ein privates VPN wie Tailscale erreichbar machen. Port `8787`
sollte nicht ungeschützt ins öffentliche Internet freigegeben werden.

Ein Gesundheitscheck steht unter `/health`, Builds werden per `POST /build`
angenommen. Der Server führt ausschließlich den festen Befehl `ufbt` ohne Shell
aus und baut jeden Upload in einem eigenen temporären Ordner.
