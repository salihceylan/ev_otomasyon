#include <Arduino.h>
#include "config.h"

// Güvenli test pinleri listesi (ESP32-WROOM için flaş harici çıkış pinleri)
static const uint8_t SAFE_GPIO_CANDIDATES[] = {
    2, 4, 5, 12, 13, 14, 15, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33
};
static const size_t SAFE_GPIO_COUNT = sizeof(SAFE_GPIO_CANDIDATES) / sizeof(SAFE_GPIO_CANDIDATES[0]);

// RS485 Serial Port
HardwareSerial RS485Serial(2);

// 74HC165 okuma fonksiyonu
uint8_t read74HC165(uint8_t dataPin, uint8_t clockPin, uint8_t latchPin) {
    digitalWrite(latchPin, LOW);
    delayMicroseconds(5);
    digitalWrite(latchPin, HIGH);
    delayMicroseconds(5);

    uint8_t value = 0;
    for (int i = 0; i < 8; ++i) {
        value |= (digitalRead(dataPin) << (7 - i));
        digitalWrite(clockPin, HIGH);
        delayMicroseconds(5);
        digitalWrite(clockPin, LOW);
        delayMicroseconds(5);
    }
    return value;
}

#if RUN_MODE_SCANNER == 1
// ==============================================================================
// MOD 1: PIN TARAYICI VE TEŞHİS KONSOLU
// ==============================================================================
bool autoScanRunning = false;
int currentScanIndex = 0;
unsigned long lastScanStepTime = 0;

void printMenu() {
    Serial.println("\n========================================================");
    Serial.printf(" [EK MODUL 1] PIN TARAMA VE TESHIS KONSOLU (Cihaz: %d)\n", DEVICE_ID);
    Serial.println("========================================================");
    Serial.println(" Komutlar:");
    Serial.println("   SCAN             -> Tum pinleri sirayla 1sn yak-sondur");
    Serial.println("   STOP             -> Taramayi durdur, tum pinleri LOW yap");
    Serial.println("   SET <pin> <0|1>  -> Belirtilen GPIO'yu HIGH veya LOW yap (Orn: SET 25 1)");
    Serial.println("   RELAY <1-8> <0|1>-> Tanimli roleyi cek/birak (Orn: RELAY 1 1)");
    Serial.println("   ALL <0|1>        -> Tum tanimli roleleri ac/kapat");
    Serial.println("   DI               -> 74HC165 dijital girislerini oku");
    Serial.println("   RS485_SEND <msg> -> RS485 portundan metin gonder");
    Serial.println("========================================================\n");
}

void setup() {
    Serial.begin(115200);
    delay(1000);

    printMenu();

    // Tanımlı röle pinlerini çıkış yap ve kapat
    for (int i = 0; i < 8; i++) {
        pinMode(RELAY_PINS[i], OUTPUT);
        digitalWrite(RELAY_PINS[i], !RELAY_ACTIVE_LEVEL);
    }

    // RS485 Başlat
    if (RS485_DE_RE_PIN >= 0) {
        pinMode(RS485_DE_RE_PIN, OUTPUT);
        digitalWrite(RS485_DE_RE_PIN, LOW); // Alıcı modu
    }
    RS485Serial.begin(RS485_BAUDRATE, SERIAL_8N1, RS485_RX_PIN, RS485_TX_PIN);

    // 74HC165 Başlat
    pinMode(HC165_LATCH_PIN, OUTPUT);
    digitalWrite(HC165_LATCH_PIN, HIGH);
    pinMode(HC165_CLOCK_PIN, OUTPUT);
    digitalWrite(HC165_CLOCK_PIN, LOW);
    pinMode(HC165_DATA_PIN, INPUT);
}

void handleCommand(String cmd) {
    cmd.trim();
    if (cmd.length() == 0) return;

    if (cmd.equalsIgnoreCase("SCAN")) {
        autoScanRunning = true;
        currentScanIndex = 0;
        lastScanStepTime = millis();
        Serial.println(">> Otomatik tarama baslatildi. Her pin 1.5 saniye HIGH yapilacak.");
        Serial.printf(">> [Adim 1/%d] GPIO %d HIGH yapiliyor... (Role cekti mi?)\n", 
                      SAFE_GPIO_COUNT, SAFE_GPIO_CANDIDATES[0]);
        pinMode(SAFE_GPIO_CANDIDATES[0], OUTPUT);
        digitalWrite(SAFE_GPIO_CANDIDATES[0], HIGH);
    }
    else if (cmd.equalsIgnoreCase("STOP")) {
        autoScanRunning = false;
        for (size_t i = 0; i < SAFE_GPIO_COUNT; i++) {
            pinMode(SAFE_GPIO_CANDIDATES[i], OUTPUT);
            digitalWrite(SAFE_GPIO_CANDIDATES[i], LOW);
        }
        Serial.println(">> Tarama durduruldu, tum pinler LOW yapildi.");
    }
    else if (cmd.startsWith("SET ")) {
        int space1 = cmd.indexOf(' ');
        int space2 = cmd.indexOf(' ', space1 + 1);
        if (space1 > 0 && space2 > 0) {
            int pin = cmd.substring(space1 + 1, space2).toInt();
            int val = cmd.substring(space2 + 1).toInt();
            pinMode(pin, OUTPUT);
            digitalWrite(pin, val ? HIGH : LOW);
            Serial.printf(">> GPIO %d -> %s yapildi.\n", pin, val ? "HIGH" : "LOW");
        }
    }
    else if (cmd.startsWith("RELAY ")) {
        int space1 = cmd.indexOf(' ');
        int space2 = cmd.indexOf(' ', space1 + 1);
        if (space1 > 0 && space2 > 0) {
            int r = cmd.substring(space1 + 1, space2).toInt();
            int val = cmd.substring(space2 + 1).toInt();
            if (r >= 1 && r <= 8) {
                uint8_t pin = RELAY_PINS[r - 1];
                pinMode(pin, OUTPUT);
                digitalWrite(pin, val ? RELAY_ACTIVE_LEVEL : !RELAY_ACTIVE_LEVEL);
                Serial.printf(">> Role %d (GPIO %d) -> %s\n", r, pin, val ? "ACIK" : "KAPALI");
            }
        }
    }
    else if (cmd.startsWith("ALL ")) {
        int val = cmd.substring(4).toInt();
        for (int i = 0; i < 8; i++) {
            digitalWrite(RELAY_PINS[i], val ? RELAY_ACTIVE_LEVEL : !RELAY_ACTIVE_LEVEL);
        }
        Serial.printf(">> Tum roleler -> %s\n", val ? "ACIK" : "KAPALI");
    }
    else if (cmd.equalsIgnoreCase("DI")) {
        uint8_t inputs = read74HC165(HC165_DATA_PIN, HC165_CLOCK_PIN, HC165_LATCH_PIN);
        Serial.printf(">> 74HC165 Giris Durumu (Byte): 0x%02X | ", inputs);
        for (int b = 7; b >= 0; b--) {
            Serial.printf("IN%d:%d ", 8 - b, (inputs >> b) & 1);
        }
        Serial.println();
    }
    else if (cmd.startsWith("RS485_SEND ")) {
        String msg = cmd.substring(11);
        if (RS485_DE_RE_PIN >= 0) {
            digitalWrite(RS485_DE_RE_PIN, HIGH); // Gönderme modu
            delayMicroseconds(200);
        }
        RS485Serial.println(msg);
        RS485Serial.flush();
        if (RS485_DE_RE_PIN >= 0) {
            delayMicroseconds(200);
            digitalWrite(RS485_DE_RE_PIN, LOW); // Alma modu
        }
        Serial.printf(">> RS485'ten gonderildi: '%s'\n", msg.c_str());
    }
    else {
        Serial.println(">> Bilinmeyen komut. Menuyu gormek icin Enter'a basin.");
        printMenu();
    }
}

void loop() {
    // Seri porttan komut okuma
    if (Serial.available()) {
        String cmd = Serial.readStringUntil('\n');
        handleCommand(cmd);
    }

    // RS485'ten veri gelirse USB'ye yaz
    if (RS485Serial.available()) {
        Serial.print("[RS485 GELEN]: ");
        while (RS485Serial.available()) {
            Serial.write(RS485Serial.read());
        }
        Serial.println();
    }

    // Otomatik pin tarama döngüsü
    if (autoScanRunning) {
        if (millis() - lastScanStepTime >= 1500) {
            // Önceki pini kapat
            digitalWrite(SAFE_GPIO_CANDIDATES[currentScanIndex], LOW);

            // Sonraki pine geç
            currentScanIndex++;
            if (currentScanIndex >= SAFE_GPIO_COUNT) {
                currentScanIndex = 0;
                Serial.println("\n>> [Tarama Tamamlandi - Basa donuluyor]");
            }

            uint8_t nextPin = SAFE_GPIO_CANDIDATES[currentScanIndex];
            pinMode(nextPin, OUTPUT);
            digitalWrite(nextPin, HIGH);
            Serial.printf(">> [Adim %d/%d] GPIO %d HIGH yapildi! (Role ceken oldu mu?)\n",
                          currentScanIndex + 1, SAFE_GPIO_COUNT, nextPin);

            lastScanStepTime = millis();
        }
    }
}

#else
// ==============================================================================
// MOD 2: ASIL EK MODÜL ÜRETİM FİRMWARE (RS485 Modbus RTU Slave)
// ==============================================================================
// Standart Modbus RTU CRC16 Fonksiyonu
uint16_t calculateCRC(const uint8_t *buffer, size_t length) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < length; i++) {
        crc ^= buffer[i];
        for (int j = 0; j < 8; j++) {
            if (crc & 0x0001) {
                crc = (crc >> 1) ^ 0xA001;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}

void rs485Send(const uint8_t *data, size_t len) {
    if (RS485_DE_RE_PIN >= 0) {
        digitalWrite(RS485_DE_RE_PIN, HIGH);
        delayMicroseconds(200);
    }
    RS485Serial.write(data, len);
    RS485Serial.flush();
    if (RS485_DE_RE_PIN >= 0) {
        delayMicroseconds(200);
        digitalWrite(RS485_DE_RE_PIN, LOW);
    }
}

void processModbusPacket(const uint8_t *buf, size_t len) {
    if (len < 4) return;
    uint8_t slaveId = buf[0];
    if (slaveId != DEVICE_ID && slaveId != 0) return; // Bize ait değilse yok say (0: broadcast)

    // CRC Denetimi
    uint16_t receivedCrc = buf[len - 2] | (buf[len - 1] << 8);
    uint16_t calcCrc = calculateCRC(buf, len - 2);
    if (receivedCrc != calcCrc) return;

    uint8_t func = buf[1];

    // Function 01: Read Coils (Röle durumlarını oku)
    if (func == 0x01) {
        uint16_t startAddr = (buf[2] << 8) | buf[3];
        uint16_t count = (buf[4] << 8) | buf[5];
        if (count > 8) count = 8;

        uint8_t coilByte = 0;
        for (uint16_t i = 0; i < count; i++) {
            uint16_t idx = startAddr + i;
            if (idx < 8) {
                int state = digitalRead(RELAY_PINS[idx]) == RELAY_ACTIVE_LEVEL ? 1 : 0;
                coilByte |= (state << i);
            }
        }

        uint8_t resp[6];
        resp[0] = DEVICE_ID;
        resp[1] = 0x01;
        resp[2] = 0x01; // Byte sayısı
        resp[3] = coilByte;
        uint16_t crc = calculateCRC(resp, 4);
        resp[4] = crc & 0xFF;
        resp[5] = (crc >> 8) & 0xFF;
        rs485Send(resp, 6);
        Serial.printf("[Modbus] Read Coils -> 0x%02X\n", coilByte);
    }
    // Function 05: Write Single Coil (Tek Röle Aç/Kapat)
    else if (func == 0x05) {
        uint16_t coilAddr = (buf[2] << 8) | buf[3];
        uint16_t val = (buf[4] << 8) | buf[5];
        bool turnOn = (val == 0xFF00);

        if (coilAddr < 8) {
            digitalWrite(RELAY_PINS[coilAddr], turnOn ? RELAY_ACTIVE_LEVEL : !RELAY_ACTIVE_LEVEL);
            Serial.printf("[Modbus] Write Coil %d -> %s\n", coilAddr + 1, turnOn ? "ON" : "OFF");
        }

        // Echo response
        rs485Send(buf, len);
    }
    // Function 02: Read Discrete Inputs (8 DI Oku)
    else if (func == 0x02) {
        uint8_t diByte = read74HC165(HC165_DATA_PIN, HC165_CLOCK_PIN, HC165_LATCH_PIN);
        uint8_t resp[6];
        resp[0] = DEVICE_ID;
        resp[1] = 0x02;
        resp[2] = 0x01;
        resp[3] = diByte;
        uint16_t crc = calculateCRC(resp, 4);
        resp[4] = crc & 0xFF;
        resp[5] = (crc >> 8) & 0xFF;
        rs485Send(resp, 6);
        Serial.printf("[Modbus] Read Discrete Inputs -> 0x%02X\n", diByte);
    }
}

uint8_t rxBuffer[64];
size_t rxIndex = 0;
unsigned long lastRxTime = 0;

void setup() {
    Serial.begin(115200);
    delay(500);
    Serial.printf("\n[EK MODUL CALISIYOR] Cihaz ID: %d | RS485 Baud: %d\n", DEVICE_ID, RS485_BAUDRATE);

    for (int i = 0; i < 8; i++) {
        pinMode(RELAY_PINS[i], OUTPUT);
        digitalWrite(RELAY_PINS[i], !RELAY_ACTIVE_LEVEL);
    }

    if (RS485_DE_RE_PIN >= 0) {
        pinMode(RS485_DE_RE_PIN, OUTPUT);
        digitalWrite(RS485_DE_RE_PIN, LOW);
    }
    RS485Serial.begin(RS485_BAUDRATE, SERIAL_8N1, RS485_RX_PIN, RS485_TX_PIN);

    pinMode(HC165_LATCH_PIN, OUTPUT);
    digitalWrite(HC165_LATCH_PIN, HIGH);
    pinMode(HC165_CLOCK_PIN, OUTPUT);
    digitalWrite(HC165_CLOCK_PIN, LOW);
    pinMode(HC165_DATA_PIN, INPUT);
}

void loop() {
    while (RS485Serial.available()) {
        uint8_t b = RS485Serial.read();
        if (rxIndex < sizeof(rxBuffer)) {
            rxBuffer[rxIndex++] = b;
        }
        lastRxTime = millis();
    }

    // Modbus RTU 3.5 karakter süresi sessizlik timeout'u (9600 baud için yakl. 4-5ms)
    if (rxIndex > 0 && (millis() - lastRxTime > 10)) {
        processModbusPacket(rxBuffer, rxIndex);
        rxIndex = 0;
    }
}
#endif

