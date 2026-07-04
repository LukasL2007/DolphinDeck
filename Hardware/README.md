# Dolphin Deck Range Modules

## Direct ESP32 BLE HID

`ESP32DolphinDeckBridge.ino` accepts the FAP's UART protocol and pairs with the
iPhone as a Bluetooth keyboard/media remote.

Wiring:

| Flipper Zero | ESP32 |
| --- | --- |
| GPIO pin 13 / TX | GPIO 16 / RX2 |
| GPIO pin 14 / RX | GPIO 17 / TX2 (optional) |
| GND | GND |

Use 115200 baud and 3.3 V logic. An ESP32 board can draw more current than the
Flipper's 3.3 V rail should provide, so a suitable external supply is
recommended.

## nRF24 long-range relay

The nRF24 option needs **two** radio nodes because an iPhone has no nRF24
radio:

```text
Flipper → UART → ESP32+nRF24 sender ⇄ nRF24+ESP32 receiver → BLE HID → iPhone
```

Flash the sketches in `NRF24DolphinDeckRelay/Transmitter` and `Receiver`.
Adapt CE/CSN/SPI pins to the boards in use. nRF24 packets in this reference
implementation are not encrypted; use it only for harmless media/control
commands in an environment you trust.

## iOS limitations

Volume and media keys are standard BLE HID consumer controls. Command-H and
Command-Tab are hardware-keyboard shortcuts and may depend on the current iOS
context. This reference firmware reports the lock command as unavailable
because the selected BLE keyboard library exposes no dependable iOS lock-screen
usage. Dolphin Deck never uses private iOS APIs.
