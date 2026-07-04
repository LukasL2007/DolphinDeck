/*
 * Dolphin Deck ESP32 BLE-HID bridge
 *
 * Dependencies:
 *   - ESP32 Arduino Core
 *   - ESP32 BLE Keyboard by T-vK
 *
 * Flipper GPIO TX (pin 13) -> ESP32 RX2 (GPIO 16)
 * Flipper GPIO RX (pin 14) <- ESP32 TX2 (GPIO 17, optional)
 * GND                         GND
 *
 * Power the ESP32 from a suitable external supply. Both UART sides use 3.3 V
 * logic. Do not feed 5 V into a Flipper GPIO pin.
 */

#include <BleKeyboard.h>

BleKeyboard keyboard("Dolphin Deck Bridge", "Dolphin Deck", 100);
HardwareSerial flipper(2);
String line;

static void sendShortcut(uint8_t modifier, char key) {
  keyboard.press(modifier);
  keyboard.press(key);
  delay(45);
  keyboard.releaseAll();
}

static void executeCommand(const String& command) {
  if (!keyboard.isConnected()) {
    flipper.println("DD1|STATUS|ESP32_NOT_PAIRED");
    return;
  }

  if (command == "VOLUME_UP") {
    keyboard.write(KEY_MEDIA_VOLUME_UP);
  } else if (command == "VOLUME_DOWN") {
    keyboard.write(KEY_MEDIA_VOLUME_DOWN);
  } else if (command == "PLAY_PAUSE") {
    keyboard.write(KEY_MEDIA_PLAY_PAUSE);
  } else if (command == "HOME") {
    // iPadOS/iOS hardware-keyboard shortcut. Availability depends on context.
    sendShortcut(KEY_LEFT_GUI, 'h');
  } else if (command == "APP_SWITCHER") {
    keyboard.press(KEY_LEFT_GUI);
    keyboard.press(KEY_TAB);
    delay(120);
    keyboard.releaseAll();
  } else if (command == "LOCK_REQUEST") {
    // This BLE keyboard library has no iOS lock-screen consumer usage.
    flipper.println("DD1|RESULT|LOCK_REQUEST|UNAVAILABLE_ON_IOS");
    return;
  } else if (command == "FIND_PHONE" || command == "NOTIFY") {
    keyboard.write(KEY_MEDIA_VOLUME_UP);
    keyboard.write(KEY_MEDIA_VOLUME_UP);
    keyboard.write(KEY_MEDIA_PLAY_PAUSE);
  } else {
    flipper.println("DD1|STATUS|UNKNOWN_COMMAND");
    return;
  }

  flipper.print("DD1|RESULT|");
  flipper.print(command);
  flipper.println("|OK");
}

void setup() {
  flipper.begin(115200, SERIAL_8N1, 16, 17);
  keyboard.begin();
  flipper.println("DD1|STATUS|ESP32_READY");
}

void loop() {
  while (flipper.available()) {
    const char value = static_cast<char>(flipper.read());
    if (value == '\n') {
      line.trim();
      const String prefix = "DD1|HID|";
      if (line.startsWith(prefix)) {
        executeCommand(line.substring(prefix.length()));
      }
      line = "";
    } else if (value != '\r' && line.length() < 95) {
      line += value;
    }
  }
  delay(2);
}
