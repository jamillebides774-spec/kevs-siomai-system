/*
 * =====================================================================
 *  KEVS SIOMAI - ESP32 DUAL OLED + DUAL BUZZER (HTTPS RENDER READY)
 * =====================================================================
 *  Hardware Pinout:
 *   - OLED #1 (Customer Display) -> SDA: GPIO 21, SCL: GPIO 22
 *   - OLED #2 (Kitchen Monitor)  -> SDA: GPIO 16, SCL: GPIO 17
 *   - Active Buzzer              -> GPIO 25
 *   - Passive Buzzer             -> GPIO 26
 * =====================================================================
 */

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <ArduinoJson.h>

// ================= 1. CONFIGURATION ========================
const char* WIFI_SSID     = "FTTx-468700";
const char* WIFI_PASSWORD = "00237550";

// Public HTTPS Cloud Host (Render)
const char* SERVER_HOST   = "kevs-siomai.onrender.com";
const int   SERVER_PORT   = 443;
const char* API_PATH      = "/api/queue/display";

// Set to true if active buzzer module triggers on LOW
const bool ACTIVE_BUZZER_INVERTED = false; 

// ================= 2. PIN DEFINITIONS ======================
#define OLED1_SDA 21
#define OLED1_SCL 22

#define OLED2_SDA 16
#define OLED2_SCL 17

#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT 64
#define OLED_ADDR     0x3C

#define ACTIVE_BUZZER_PIN  25
#define PASSIVE_BUZZER_PIN 26

// ================= 3. OBJECTS & STATE ======================
TwoWire I2C_1 = TwoWire(0);
TwoWire I2C_2 = TwoWire(1);

Adafruit_SSD1306 oledCustomer(SCREEN_WIDTH, SCREEN_HEIGHT, &I2C_1, -1);
Adafruit_SSD1306 oledKitchen(SCREEN_WIDTH, SCREEN_HEIGHT, &I2C_2, -1);

int lastNowServing     = -1;
int lastLatestTicket   = -1;
int lastCompletedCount = -1;
int lastLowStock       = 0;
bool firstPoll         = true;

unsigned long lastPollTime = 0;
const unsigned long POLL_INTERVAL_MS = 2000; // Poll every 2 seconds

// ================= 4. BUZZER FUNCTIONS =====================
void writeActiveBuzzer(bool state) {
  if (ACTIVE_BUZZER_INVERTED) {
    digitalWrite(ACTIVE_BUZZER_PIN, state ? LOW : HIGH);
  } else {
    digitalWrite(ACTIVE_BUZZER_PIN, state ? HIGH : LOW);
  }
}

// Active Buzzer: Double-beep para sa Now Serving Call
void beepActiveBuzzerQueueCall() {
  for (int i = 0; i < 2; i++) {
    writeActiveBuzzer(true);
    delay(160);
    writeActiveBuzzer(false);
    delay(100);
  }
}

// Active Buzzer: Triple-beep para sa Low Stock Alert
void beepActiveBuzzerLowStock() {
  for (int i = 0; i < 3; i++) {
    writeActiveBuzzer(true);
    delay(70);
    writeActiveBuzzer(false);
    delay(70);
  }
}

// Passive Buzzer: Software PWM / Tone generator
void playPassiveTone(int freq, int durationMs) {
  #if ESP_ARDUINO_VERSION >= ESP_ARDUINO_VERSION_VAL(3, 0, 0)
    ledcAttach(PASSIVE_BUZZER_PIN, freq, 8);
    ledcWriteTone(PASSIVE_BUZZER_PIN, freq);
    delay(durationMs);
    ledcWriteTone(PASSIVE_BUZZER_PIN, 0);
  #else
    ledcSetup(0, freq, 8);
    ledcAttachPin(PASSIVE_BUZZER_PIN, 0);
    ledcWriteTone(0, freq);
    delay(durationMs);
    ledcWriteTone(0, 0);
  #endif
}

// Bagong Order Chime: Two cheerful ascending tones (B5 -> E6)
void playPassiveBuzzerNewOrderChime() {
  playPassiveTone(988, 160);  // B5
  delay(50);
  playPassiveTone(1319, 320); // E6
}

// Order Completed Chime: Ascending major triad (C6 -> E6 -> G6)
void playPassiveBuzzerCompletedChime() {
  playPassiveTone(1047, 120); // C6
  delay(40);
  playPassiveTone(1319, 140); // E6
  delay(40);
  playPassiveTone(1568, 250); // G6
}

// Startup Sound: Checks both buzzers on boot
void playStartupSound() {
  writeActiveBuzzer(true);
  delay(120);
  writeActiveBuzzer(false);
  delay(80);
  playPassiveTone(1047, 120);
  delay(40);
  playPassiveTone(1319, 180);
}

// ================= 5. DISPLAY FUNCTIONS ====================
void showStatus(const char* title, const char* line1, const char* line2) {
  oledCustomer.clearDisplay();
  oledCustomer.setTextColor(SSD1306_WHITE);
  oledCustomer.setTextSize(1);
  oledCustomer.setCursor(0, 4);
  oledCustomer.println(title);
  oledCustomer.setCursor(0, 22);
  oledCustomer.println(line1);
  oledCustomer.setCursor(0, 40);
  oledCustomer.println(line2);
  oledCustomer.display();

  oledKitchen.clearDisplay();
  oledKitchen.setTextColor(SSD1306_WHITE);
  oledKitchen.setTextSize(1);
  oledKitchen.setCursor(0, 4);
  oledKitchen.println(title);
  oledKitchen.setCursor(0, 22);
  oledKitchen.println(line1);
  oledKitchen.setCursor(0, 40);
  oledKitchen.println(line2);
  oledKitchen.display();
}

void renderCustomerOLED(int nowServing, int activeCount, const char* statusText) {
  oledCustomer.clearDisplay();
  oledCustomer.setTextColor(SSD1306_WHITE);

  // Header Bar
  oledCustomer.fillRect(0, 0, 128, 14, SSD1306_WHITE);
  oledCustomer.setTextColor(SSD1306_BLACK);
  oledCustomer.setTextSize(1);
  oledCustomer.setCursor(14, 3);
  oledCustomer.print("KEVS SIOMAI QUEUE");

  oledCustomer.setTextColor(SSD1306_WHITE);
  oledCustomer.setTextSize(1);
  oledCustomer.setCursor(22, 18);
  oledCustomer.print("NOW SERVING:");

  char ticketBuf[12];
  if (nowServing > 0) snprintf(ticketBuf, sizeof(ticketBuf), "#%02d", nowServing);
  else snprintf(ticketBuf, sizeof(ticketBuf), "---");

  oledCustomer.setTextSize(3);
  oledCustomer.setCursor(nowServing > 0 ? 28 : 42, 29);
  oledCustomer.print(ticketBuf);

  oledCustomer.drawFastHLine(0, 53, 128, SSD1306_WHITE);
  oledCustomer.setTextSize(1);
  oledCustomer.setCursor(2, 56);
  oledCustomer.print("Wait: ");
  oledCustomer.print(activeCount);
  oledCustomer.print(" | ");
  oledCustomer.print(statusText);

  oledCustomer.display();
}

void renderKitchenOLED(int pending, int preparing, int ready, int latestTicket, const char* cust, float total, int lowStock, const char* item) {
  oledKitchen.clearDisplay();
  oledKitchen.setTextColor(SSD1306_WHITE);

  oledKitchen.fillRect(0, 0, 128, 12, SSD1306_WHITE);
  oledKitchen.setTextColor(SSD1306_BLACK);
  oledKitchen.setTextSize(1);
  oledKitchen.setCursor(16, 2);
  oledKitchen.print("KITCHEN MONITOR");

  oledKitchen.setTextColor(SSD1306_WHITE);
  oledKitchen.setTextSize(1);
  oledKitchen.setCursor(0, 15);
  oledKitchen.print("PND:"); oledKitchen.print(pending);
  oledKitchen.print(" PRP:"); oledKitchen.print(preparing);
  oledKitchen.print(" RDY:"); oledKitchen.print(ready);

  oledKitchen.drawFastHLine(0, 25, 128, SSD1306_WHITE);
  oledKitchen.setCursor(0, 28);
  if (latestTicket > 0) {
    oledKitchen.print("Latest: #");
    oledKitchen.print(latestTicket);
    oledKitchen.print(" P");
    oledKitchen.print((int)total);

    oledKitchen.setCursor(0, 39);
    oledKitchen.print("Cust: ");
    oledKitchen.print(cust);
  } else {
    oledKitchen.print("No Active Orders");
    oledKitchen.setCursor(0, 39);
    oledKitchen.print("Standby Mode...");
  }

  oledKitchen.drawFastHLine(0, 50, 128, SSD1306_WHITE);
  oledKitchen.setCursor(0, 54);
  if (lowStock > 0) {
    oledKitchen.print("LOW: ");
    oledKitchen.print(item);
  } else {
    oledKitchen.print("Stock: ALL OK");
  }
  oledKitchen.display();
}

// ================= 6. HTTPS FETCH VIA WIFICLIENTSECURE =====
bool fetchQueueData() {
  WiFiClientSecure client;
  client.setInsecure(); // Skip certificate verification for smooth cloud connection
  client.setTimeout(4); // 4 seconds timeout

  if (!client.connect(SERVER_HOST, SERVER_PORT)) {
    Serial.printf("[HTTPS] Cannot connect to %s:%d\n", SERVER_HOST, SERVER_PORT);
    return false;
  }

  // Send lightweight HTTP GET request
  client.printf("GET %s HTTP/1.1\r\n", API_PATH);
  client.printf("Host: %s\r\n", SERVER_HOST);
  client.print("User-Agent: ESP32-DualOLED-KevsSiomai\r\n");
  client.print("Connection: close\r\n\r\n");

  // Read HTTP Response
  bool isBody = false;
  String jsonBody = "";
  unsigned long timeout = millis();

  while (client.connected() || client.available()) {
    if (client.available()) {
      String line = client.readStringUntil('\n');
      if (line == "\r" || line.length() == 0) {
        isBody = true;
        continue;
      }
      if (isBody) {
        jsonBody += line;
      }
    }
    if (millis() - timeout > 4000) {
      Serial.println("[HTTPS] Read Timeout!");
      client.stop();
      return false;
    }
  }
  client.stop();

  if (jsonBody.length() == 0) {
    return false;
  }

  // Remove potential trailing or chunked metadata if present
  int jsonStart = jsonBody.indexOf('{');
  int jsonEnd   = jsonBody.lastIndexOf('}');
  if (jsonStart < 0 || jsonEnd < 0 || jsonEnd <= jsonStart) {
    return false;
  }
  jsonBody = jsonBody.substring(jsonStart, jsonEnd + 1);

  StaticJsonDocument<768> doc;
  DeserializationError err = deserializeJson(doc, jsonBody);
  if (err) {
    Serial.print("[JSON] Parse failed: ");
    Serial.println(err.c_str());
    return false;
  }

  int nowServing            = doc["now_serving"] | 0;
  bool hasActive            = doc["has_active"] | false;
  int activeCount           = doc["active_count"] | 0;
  const char* servingStatus = doc["now_serving_status"] | "idle";
  int pendingCount          = doc["pending_count"] | 0;
  int preparingCount        = doc["preparing_count"] | 0;
  int readyCount            = doc["ready_count"] | 0;
  int completedCount        = doc["completed_count"] | 0;
  int latestTicket          = doc["latest_ticket"] | 0;
  const char* latestCust    = doc["latest_customer"] | "-";
  float latestTotal         = doc["latest_total"] | 0.0;
  int lowStockCount         = doc["low_stock_count"] | 0;
  const char* lowStockItem  = doc["low_stock_item"] | "";

  // If no active orders, display 0 ("---")
  if (!hasActive) {
    nowServing = 0;
  }

  // Sound triggers on state changes
  if (!firstPoll) {
    // 1. Bagong Order received -> Passive Buzzer Chime
    if (latestTicket > 0 && latestTicket != lastLatestTicket && latestTicket > lastLatestTicket) {
      Serial.println("🔔 [BUZZER] NEW ORDER RECEIVED: Ticket #" + String(latestTicket));
      playPassiveBuzzerNewOrderChime();
    }
    // 2. Now Serving called -> Active Buzzer double-beep
    if (nowServing > 0 && nowServing != lastNowServing) {
      Serial.println("📢 [BUZZER] NOW SERVING: Ticket #" + String(nowServing));
      beepActiveBuzzerQueueCall();
    }
    // 3. Order Completed -> Passive Buzzer Completed Chime
    if (completedCount > lastCompletedCount && lastCompletedCount >= 0) {
      Serial.println("✅ [BUZZER] ORDER COMPLETED: Total served = " + String(completedCount));
      playPassiveBuzzerCompletedChime();
    }
    // 4. Low Stock Alert -> Active Buzzer triple-beep
    if (lowStockCount > 0 && lowStockCount != lastLowStock) {
      Serial.println("⚠️ [BUZZER] LOW STOCK ALERT: " + String(lowStockItem));
      beepActiveBuzzerLowStock();
    }
  }

  lastNowServing     = nowServing;
  lastLatestTicket   = latestTicket;
  lastCompletedCount = completedCount;
  lastLowStock       = lowStockCount;
  firstPoll          = false;

  // Render both OLED screens
  renderCustomerOLED(nowServing, activeCount, servingStatus);
  renderKitchenOLED(pendingCount, preparingCount, readyCount, latestTicket, latestCust, latestTotal, lowStockCount, lowStockItem);

  return true;
}

// ================= 7. SETUP ================================
void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n--- KEVS SIOMAI ESP32 CONTROLLER STARTING ---");

  // Setup Buzzer Pins
  pinMode(ACTIVE_BUZZER_PIN, OUTPUT);
  writeActiveBuzzer(false);
  pinMode(PASSIVE_BUZZER_PIN, OUTPUT);
  digitalWrite(PASSIVE_BUZZER_PIN, LOW);

  // Initialize Dual I2C Busses
  I2C_1.begin(OLED1_SDA, OLED1_SCL, 400000);
  I2C_2.begin(OLED2_SDA, OLED2_SCL, 400000);

  // Initialize OLED #1 (Customer)
  if (!oledCustomer.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
    Serial.println("[ERROR] OLED Customer not detected at 0x3C!");
  } else {
    oledCustomer.clearDisplay();
    oledCustomer.display();
  }

  // Initialize OLED #2 (Kitchen)
  if (!oledKitchen.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
    Serial.println("[ERROR] OLED Kitchen not detected at 0x3C!");
  } else {
    oledKitchen.clearDisplay();
    oledKitchen.display();
  }

  // Play startup sound test
  playStartupSound();

  // Connect to WiFi
  showStatus("KEVS SIOMAI BOOT", "Connecting WiFi...", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 25) {
    delay(500);
    Serial.print(".");
    attempts++;
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\nWiFi Connected! IP: " + WiFi.localIP().toString());
    showStatus("KEVS SIOMAI ONLINE", "WiFi Connected!", WiFi.localIP().toString().c_str());
    delay(1000);
  } else {
    Serial.println("\nWiFi Connection Failed! Running in Offline Mode...");
    showStatus("KEVS SIOMAI OFFLINE", "WiFi Failed!", "Retrying in loop...");
  }
}

// ================= 8. MAIN LOOP ============================
void loop() {
  // Reconnect WiFi if disconnected
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WIFI] Reconnecting...");
    WiFi.reconnect();
    delay(1500);
    return;
  }

  // Periodic poll of Render Cloud Backend
  if (millis() - lastPollTime >= POLL_INTERVAL_MS) {
    lastPollTime = millis();
    bool success = fetchQueueData();
    if (!success) {
      Serial.println("[HTTP] Fetch failed, retrying on next cycle...");
    }
  }
}

