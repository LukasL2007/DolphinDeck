/*
 * Dolphin Deck nRF24 receiver + ESP32 BLE HID.
 *
 * Dependencies:
 *   - RF24 by TMRh20
 *   - ESP32 BLE Keyboard by T-vK
 */

#include <BleKeyboard.h>
#include <RF24.h>

RF24 radio(4, 5);  // CE, CSN - adapt to your board
BleKeyboard keyboard("Dolphin Deck Long Range", "Dolphin Deck", 100);
const uint8_t pipe[6] = "DD110";

static void shortcut(uint8_t modifier, char key) {
  keyboard.press(modifier);
  keyboard.press(key);
  delay(45);
  keyboard.releaseAll();
}

static void execute(const char* command) {
  if (!keyboard.isConnected()) return;
  if (strcmp(command, "VOLUME_UP") == 0) {
    keyboard.write(KEY_MEDIA_VOLUME_UP);
  } else if (strcmp(command, "VOLUME_DOWN") == 0) {
    keyboard.write(KEY_MEDIA_VOLUME_DOWN);
  } else if (strcmp(command, "PLAY_PAUSE") == 0) {
    keyboard.write(KEY_MEDIA_PLAY_PAUSE);
  } else if (strcmp(command, "HOME") == 0) {
    shortcut(KEY_LEFT_GUI, 'h');
  } else if (strcmp(command, "APP_SWITCHER") == 0) {
    keyboard.press(KEY_LEFT_GUI);
    keyboard.press(KEY_TAB);
    delay(120);
    keyboard.releaseAll();
  } else if (strcmp(command, "LOCK_REQUEST") == 0) {
    // iOS exposes no dependable standard-keyboard lock command here.
    return;
  }
}

void setup() {
  keyboard.begin();
  radio.begin();
  radio.setPALevel(RF24_PA_LOW);
  radio.setDataRate(RF24_250KBPS);
  radio.openReadingPipe(1, pipe);
  radio.startListening();
}

void loop() {
  if (radio.available()) {
    char packet[32] = {};
    radio.read(&packet, sizeof(packet));
    packet[sizeof(packet) - 1] = '\0';
    execute(packet);
  }
}
