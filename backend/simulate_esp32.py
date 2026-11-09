"""
simulate_esp32.py
─────────────────────────────────────────────────────────
Simulates an ESP32 device pressing its walk-in queue button.
Run: python simulate_esp32.py
"""
import requests
import time
import sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

BASE_URL = "http://localhost:5000/api"

def press_button():
    """Simulate a walk-in customer pressing the ESP32 queue button."""
    print("\n🔴 [ESP32 SIMULATOR] Queue button pressed!")
    payload = {
        "type": "walk-in",
        "order_type": "pickup",
        "customer_name": "Walk-in Customer",
        "payment_method": "Cash",
        "items": [
            {"product_id": 1, "quantity": 1},  # Hotspot Siomai
        ],
        "notes": "From ESP32 button"
    }
    try:
        resp = requests.post(f"{BASE_URL}/queue/add", json=payload, timeout=5)
        if resp.status_code == 201:
            data = resp.json()
            queue_no = data['order']['queue_no']
            print(f"✅ Queue ticket #{queue_no} issued!")
            print(f"   Now Serving: {data['queue']['now_serving']}")
            print(f"   Current Queue: {data['queue']['current_queue_no']}")
            print(f"   → OLED Display would show: QUEUE #{queue_no}")
        else:
            print(f"❌ Error: {resp.status_code} - {resp.text}")
    except requests.exceptions.ConnectionError:
        print("❌ Cannot connect to Flask server. Is it running on localhost:5000?")

def check_display():
    """Simulate ESP32 polling the OLED display data."""
    try:
        resp = requests.get(f"{BASE_URL}/queue/display", timeout=5)
        if resp.status_code == 200:
            data = resp.json()
            print(f"\n📟 [OLED DISPLAY STATE]")
            print(f"   NOW SERVING: #{data['now_serving']}")
            print(f"   NEXT QUEUE:  #{data['next_queue']}")
            print(f"   STATUS: {data['now_serving_status'].upper()}")
        else:
            print(f"❌ Display fetch error: {resp.status_code}")
    except requests.exceptions.ConnectionError:
        print("❌ Cannot connect to Flask server.")

def interactive():
    """Interactive ESP32 simulation loop."""
    print("=" * 50)
    print("  🥟 KEVS Siomai - ESP32 Button Simulator")
    print("=" * 50)
    print("Commands:")
    print("  [ENTER] → Press queue button (new walk-in)")
    print("  [d]     → Check OLED display state")
    print("  [q]     → Quit")
    print("-" * 50)

    while True:
        cmd = input("\nCommand: ").strip().lower()
        if cmd == '' or cmd == 'b':
            press_button()
        elif cmd == 'd':
            check_display()
        elif cmd == 'q':
            print("👋 ESP32 Simulator stopped.")
            break
        else:
            print("Unknown command. Press ENTER to simulate button press, [d] for display, [q] to quit.")

def auto_demo(count=5, delay=2.0):
    """Automatically press button N times for demo."""
    print(f"🤖 Auto-pressing button {count} times (every {delay}s)...")
    for i in range(count):
        press_button()
        if i < count - 1:
            time.sleep(delay)
    print("\n✅ Auto-demo complete!")

if __name__ == '__main__':
    if '--auto' in sys.argv:
        count = int(sys.argv[sys.argv.index('--auto') + 1]) if len(sys.argv) > sys.argv.index('--auto') + 1 else 5
        auto_demo(count)
    else:
        interactive()
