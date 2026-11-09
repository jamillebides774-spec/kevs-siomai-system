"""
simulate_mobile.py
─────────────────────────────────────────────────────────
Simulates a customer placing an online order via the Mobile App
and a mock GCash payment callback.
Run: python simulate_mobile.py
"""
import requests
import json
import random
import time
import sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

BASE_URL = "http://localhost:5000/api"

SAMPLE_CUSTOMERS = [
    {"name": "Maria Santos", "phone": "09171234567"},
    {"name": "Juan dela Cruz", "phone": "09281234567"},
    {"name": "Ana Reyes", "phone": "09391234567"},
    {"name": "Pedro Garcia", "phone": "09451234567"},
]

def get_products():
    """Fetch available products from backend."""
    try:
        resp = requests.get(f"{BASE_URL}/products", timeout=5)
        if resp.status_code == 200:
            return resp.json()['products']
        return []
    except:
        return []

def place_order(order_type='pickup', payment_method='GCash'):
    """Simulate a customer placing an online order."""
    products = get_products()
    if not products:
        print("❌ No products available. Is the server running?")
        return None

    customer = random.choice(SAMPLE_CUSTOMERS)
    # Pick 1-3 random products
    chosen = random.sample(products[:8], random.randint(1, 3))
    items = [{"product_id": p['id'], "quantity": random.randint(1, 2)} for p in chosen]

    payload = {
        "customer_name": customer['name'],
        "customer_phone": customer['phone'],
        "order_type": order_type,
        "delivery_address": "123 Rizal St., Brgy. San Antonio, Makati" if order_type == 'delivery' else "",
        "payment_method": payment_method,
        "items": items,
        "notes": "Extra chili garlic sauce please!"
    }

    print(f"\n📱 [MOBILE APP] {customer['name']} placing {order_type} order via {payment_method}...")
    print(f"   Items: {', '.join([p['name'] for p in chosen])}")

    try:
        resp = requests.post(f"{BASE_URL}/orders", json=payload, timeout=5)
        if resp.status_code == 201:
            data = resp.json()
            order = data['order']
            print(f"✅ Order #{order['queue_no']} placed! (Order ID: {order['id']})")
            print(f"   Total: ₱{order['total']:.2f}")
            print(f"   Status: {order['status']}")
            return order
        else:
            print(f"❌ Order failed: {resp.status_code} - {resp.text}")
    except requests.exceptions.ConnectionError:
        print("❌ Cannot connect to Flask server.")
    return None

def simulate_gcash_payment(order_id, reference=None):
    """Simulate GCash payment webhook callback."""
    import uuid
    ref = reference or f"GC-{uuid.uuid4().hex[:10].upper()}"

    print(f"\n💳 [GCASH MOCK] Simulating payment callback for Order #{order_id}...")
    print(f"   Reference: {ref}")

    payload = {
        "order_id": order_id,
        "reference": ref,
        "status": "paid",
        "amount": 100.00,
        "data": {
            "attributes": {
                "status": "paid",
                "reference_number": ref,
                "description": f"KEVS Siomai Order #{order_id}"
            }
        }
    }

    try:
        resp = requests.post(f"{BASE_URL}/payments/gcash/callback", json=payload, timeout=5)
        if resp.status_code == 200:
            data = resp.json()
            print(f"✅ Payment confirmed! Status: {data['order']['payment_status']}")
            return True
        else:
            print(f"❌ Payment callback failed: {resp.status_code} - {resp.text}")
    except requests.exceptions.ConnectionError:
        print("❌ Cannot connect to Flask server.")
    return False

def full_flow_demo():
    """Complete demo: place order + pay via GCash."""
    print("\n" + "=" * 55)
    print("  📱 KEVS Siomai - Mobile Customer App Simulator")
    print("=" * 55)

    # 1. Place online pickup order
    print("\n[Step 1] Placing online order...")
    order = place_order(order_type='pickup', payment_method='GCash')
    if not order:
        return

    time.sleep(1)

    # 2. Simulate GCash payment
    print("\n[Step 2] Processing GCash payment...")
    simulate_gcash_payment(order['id'])

    time.sleep(0.5)
    print("\n✅ Full customer flow completed!")
    print(f"   Queue #{order['queue_no']} is now in the admin dashboard.")

def interactive():
    print("\n" + "=" * 55)
    print("  📱 KEVS Siomai - Mobile App Simulator")
    print("=" * 55)
    print("Commands:")
    print("  [1] Place pickup order (GCash)")
    print("  [2] Place delivery order (GCash)")
    print("  [3] Place pickup order (Cash)")
    print("  [4] Full flow: Order + GCash callback")
    print("  [q] Quit")
    print("-" * 55)

    while True:
        cmd = input("\nCommand: ").strip().lower()
        if cmd == '1':
            place_order('pickup', 'GCash')
        elif cmd == '2':
            place_order('delivery', 'GCash')
        elif cmd == '3':
            place_order('pickup', 'Cash')
        elif cmd == '4':
            full_flow_demo()
        elif cmd == 'q':
            print("👋 Mobile simulator stopped.")
            break
        else:
            print("Unknown command.")

if __name__ == '__main__':
    if '--demo' in sys.argv:
        full_flow_demo()
    else:
        interactive()
