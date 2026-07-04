/*
 * Dolphin Deck nRF24 transmitter.
 * Reads DD1 lines from the Flipper UART and forwards them over nRF24.
 *
 * Dependency: RF24 by TMRh20
 */

#include <RF24.h>

RF24 radio(4, 5);  // CE, CSN - adapt to your board
HardwareSerial flipper(2);
const uint8_t pipe[6] = "DD110";
String line;

void setup() {
  flipper.begin(115200, SERIAL_8N1, 16, 17);
  radio.begin();
  radio.setPALevel(RF24_PA_LOW);
  radio.setDataRate(RF24_250KBPS);
  radio.openWritingPipe(pipe);
  radio.stopListening();
}

void loop() {
  while (flipper.available()) {
    const char value = static_cast<char>(flipper.read());
    if (value == '\n') {
      line.trim();
      if (line.startsWith("DD1|HID|")) {
        char packet[32] = {};
        line.substring(8).toCharArray(packet, sizeof(packet));
        const bool ok = radio.write(&packet, sizeof(packet));
        flipper.println(ok ? "DD1|STATUS|NRF24_SENT" : "DD1|STATUS|NRF24_FAILED");
      }
      line = "";
    } else if (value != '\r' && line.length() < 95) {
      line += value;
    }
  }
}
