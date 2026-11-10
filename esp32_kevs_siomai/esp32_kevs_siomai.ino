/*
 * =====================================================================
 *  KEVS SIOMAI - ESP32 DUAL OLED + DUAL BUZZER (FIXED HTTP & BUZZER)
 * =====================================================================
 *  Hardware Pinout:
 *   - OLED #1 (Customer Display) -> SDA: GPIO 21, SCL: GPIO 22
 *   - OLED #2 (Kitchen Monitor)  -> SDA: GPIO 16, SCL: GPIO 17
 *   - Active Buzzer              -> GPIO 32
 *   - Passive Buzzer             -> GPIO 23
 * =====================================================================
 */

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
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

// Set to true kung ang active buzzer mo ay tumutunog sa LOW (active-low module)
const bool ACTIVE_BUZZER_INVERTED = false; 

// ================= 2. PIN DEFINITIONS ======================
#define OLED1_SDA 21
#define OLED1_SCL 22

#define OLED2_SDA 16
#define OLED2_SCL 17

#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT 64
#define OLED_ADDR     0x3C

#define ACTIVE_BUZZER_PIN  32
#define PASSIVE_BUZZER_PIN 23

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
const unsigned long POLL_INTERVAL_MS = 1500; // Poll every 1.5 seconds

// ================= 4. BUZZER FUNCTIONS =====================
void writeActiveBuzzer(bool state) {
  if (ACTIVE_BUZZER_INVERTED) {
    digitalWrite(ACTIVE_BUZZER_PIN, state ? LOW : HIGH);
  } else {
    digitalWrite(ACTIVE_BUZZER_PIN, state ? HIGH : LOW);
  }
}

// Passive Buzzer: Generates sound tone
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

// Tunog kapag may DUMATING NA BAGONG ORDER
void soundNewOrder() {
  Serial.println("🔔 [BUZZER] SOUND: New Order Alert!");
  // Active buzzer beep
  writeActiveBuzzer(true);
  delay(120);
  writeActiveBuzzer(false);
  delay(60);
  // Passive buzzer chime (B5 -> E6)
  playPassiveTone(988, 140);
  delay(40);
  playPassiveTone(1319, 280);
}

// Tunog kapag may ORDER NA NATAPOS (COMPLETED)
void soundOrderCompleted() {
  Serial.println("✅ [BUZZER] SOUND: Order Completed Chime!");
  // Active buzzer single confirmation beep
  writeActiveBuzzer(true);
  delay(100);
  writeActiveBuzzer(false);
  delay(50);
  // Passive buzzer victory melody (C6 -> E6 -> G6)
  playPassiveTone(1047, 100);
  delay(30);
  playPassiveTone(1319, 120);
  delay(30);
  playPassiveTone(1568, 220);
}

// Tunog kapag TINATAWAG ANG TICKET (NOW SERVING)
void soundQueueCall() {
  Serial.println("📢 [BUZZER] SOUND: Now Serving Call!");
  for (int i = 0; i < 2; i++) {
    writeActiveBuzzer(true);
    playPassiveTone(1200, 150);
    writeActiveBuzzer(false);
    delay(100);
  }
}

// Tunog kapag LOW STOCK ALERT
void soundLowStock() {
  Serial.println("⚠️ [BUZZER] SOUND: Low Stock Alert!");
  for (int i = 0; i < 3; i++) {
    writeActiveBuzzer(true);
    delay(70);
    writeActiveBuzzer(false);
    delay(70);
  }
}

// Startup Sound: Papatugtugin agad pagkakasaksak ng ESP32
void playStartupSound() {
  Serial.println("🔊 Testing Buzzers on boot...");
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

void renderKitchenOLED(int pending, int preparing, int ready, int lowStock, const char* item) {
  oledKitchen.clearDisplay();
  oledKitchen.setTextColor(SSD1306_WHITE);

  // 1. Header Bar
  oledKitchen.fillRect(0, 0, 128, 13, SSD1306_WHITE);
  oledKitchen.setTextColor(SSD1306_BLACK);
  oledKitchen.setTextSize(1);
  oledKitchen.setCursor(18, 3);
  oledKitchen.print("KITCHEN MONITOR");

  // 2. Order Counts (Pending, Preparing, Ready)
  oledKitchen.setTextColor(SSD1306_WHITE);
  oledKitchen.setTextSize(1);
  oledKitchen.setCursor(2, 17);
  oledKitchen.print("PND:"); oledKitchen.print(pending);
  oledKitchen.print("  PRP:"); oledKitchen.print(preparing);
  oledKitchen.print("  RDY:"); oledKitchen.print(ready);

  oledKitchen.drawFastHLine(0, 27, 128, SSD1306_WHITE);

  // 3. Stock Status (Itinaas ayon sa gusto mo)
  oledKitchen.setCursor(2, 31);
  if (lowStock > 0) {
    oledKitchen.print("LOW: ");
    oledKitchen.print(item);
  } else {
    oledKitchen.print("STOCK: ALL OK");
  }

  oledKitchen.drawFastHLine(0, 42, 128, SSD1306_WHITE);

  // 4. Paalala sa Ilalim: "BAWAL UTANG / MAHIYAIN KAMI"
  oledKitchen.setTextSize(1);
  oledKitchen.setCursor(31, 46);
  oledKitchen.print("BAWAL UTANG");
  oledKitchen.setCursor(25, 56);
  oledKitchen.print("MAHIYAIN KAMI");

  oledKitchen.display();
}

// ================= 6. ROBUST HTTPS VIA HTTPCLIENT ==========
bool fetchQueueData() {
  WiFiClientSecure client;
  client.setInsecure(); // Bypass cert verification for cloud Render
  client.setTimeout(4000);

  HTTPClient https;
  String url = "https://" + String(SERVER_HOST) + String(API_PATH);

  if (!https.begin(client, url)) {
    Serial.println("[HTTPS] Cannot initialize HTTPClient!");
    return false;
  }

  https.setUserAgent("ESP32-DualOLED-KevsSiomai");
  https.setTimeout(4000);

  int httpCode = https.GET();
  if (httpCode != HTTP_CODE_OK) {
    Serial.printf("[HTTPS] GET failed! HTTP Status: %d\n", httpCode);
    https.end();
    return false;
  }

  String jsonBody = https.getString();
  https.end();

  if (jsonBody.length() == 0) {
    Serial.println("[HTTPS] Empty body received");
    return false;
  }

  StaticJsonDocument<1024> doc;
  DeserializationError err = deserializeJson(doc, jsonBody);
  if (err) {
    Serial.print("[JSON] Parse error: ");
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
  int lowStockCount         = doc["low_stock_count"] | 0;
  const char* lowStockItem  = doc["low_stock_item"] | "";

  // Kapag walang aktibong order, ipakita ang "---" (0)
  if (!hasActive) {
    nowServing = 0;
  }

  // SOUND TRIGGERS SA MGA PAGBABAGO NG ORDER AT PILA
  if (!firstPoll) {
    // 1. May DUMATING NA BAGONG ORDER -> Bagong order chime + beep
    if (latestTicket > 0 && latestTicket != lastLatestTicket && latestTicket > lastLatestTicket) {
      Serial.println("🔔 [EVENT] New Order Arrived! Ticket #" + String(latestTicket));
      soundNewOrder();
    }
    // 2. May NATAPOS NA ORDER (Completed) -> Completed victory chime
    if (completedCount > lastCompletedCount && lastCompletedCount >= 0) {
      Serial.println("✅ [EVENT] Order Marked Completed! Total served = " + String(completedCount));
      soundOrderCompleted();
    }
    // 3. Tinawag ang ticket (Now Serving) -> Queue call double-beep
    if (nowServing > 0 && nowServing != lastNowServing) {
      Serial.println("📢 [EVENT] Now Serving Ticket #" + String(nowServing));
      soundQueueCall();
    }
    // 4. Low Stock Alert
    if (lowStockCount > 0 && lowStockCount != lastLowStock) {
      Serial.println("⚠️ [EVENT] Low Stock Warning: " + String(lowStockItem));
      soundLowStock();
    }
  }

  lastNowServing     = nowServing;
  lastLatestTicket   = latestTicket;
  lastCompletedCount = completedCount;
  lastLowStock       = lowStockCount;
  firstPoll          = false;

  // I-update ang dalawang OLED Screen
  renderCustomerOLED(nowServing, activeCount, servingStatus);
  renderKitchenOLED(pendingCount, preparingCount, readyCount, lowStockCount, lowStockItem);

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

  // Initialize Dual I2C Busses at stable 100kHz
  I2C_1.begin(OLED1_SDA, OLED1_SCL, 100000);
  I2C_2.begin(OLED2_SDA, OLED2_SCL, 100000);

  // Initialize OLED #1 (Customer - GPIO 21/22)
  if (!oledCustomer.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
    Serial.println("[ERROR] OLED Customer not detected at 0x3C (GPIO 21/22)!");
  } else {
    oledCustomer.clearDisplay();
    oledCustomer.display();
  }

  // Initialize OLED #2 (Kitchen - GPIO 16/17)
  if (!oledKitchen.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
    Serial.println("[ERROR] OLED Kitchen not detected at 0x3C (GPIO 16/17)!");
  } else {
    oledKitchen.clearDisplay();
    oledKitchen.display();
  }

  // Subukan agad ang sound ng buzzers pagkakasaksak
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
    delay(800);
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
