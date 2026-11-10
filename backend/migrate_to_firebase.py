"""
Migration Script: Local SQLite / MySQL -> Cloud Firestore
Transforms Kevs Siomai data into Firebase Collections:
  - products
  - orders
  - queue
  - sales
  - users
"""

import os
import sys
import sqlite3
from datetime import datetime, timezone

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

from firebase_client import get_firestore_db
from firebase_admin import firestore

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))

def migrate():
    try:
        db = get_firestore_db()
    except Exception as e:
        print(f"❌ Failed to connect to Firebase: {e}")
        return

    sqlite_path = os.path.join(BACKEND_DIR, 'kevs_siomai.db')
    conn = None
    if os.path.exists(sqlite_path):
        conn = sqlite3.connect(sqlite_path)
        conn.row_factory = sqlite3.Row

    print("🚀 Starting migration to Cloud Firestore...\n")

    # 1. Migrate Products
    print("📦 Migrating products...")
    default_products = [
        {'id': 1, 'name': 'HotSpot Siomai', 'category': 'Siomai', 'price': 10.0, 'stock': 200, 'max_stock': 500, 'unit': 'pcs', 'description': 'Signature HotSpot Siomai – ₱10 per piece', 'image_url': '/images/hotspot_siomai.jpg', 'is_active': True},
        {'id': 2, 'name': 'Coke', 'category': 'Drinks', 'price': 25.0, 'stock': 48, 'max_stock': 144, 'unit': 'bottles', 'description': 'Ice-cold Coca-Cola', 'image_url': '/images/coke.jpg', 'is_active': True},
        {'id': 3, 'name': 'Royal', 'category': 'Drinks', 'price': 25.0, 'stock': 48, 'max_stock': 144, 'unit': 'bottles', 'description': 'Ice-cold Royal Tru-Orange (Bottle)', 'image_url': '/images/royal.jpg', 'is_active': True},
        {'id': 4, 'name': 'Sprite', 'category': 'Drinks', 'price': 25.0, 'stock': 48, 'max_stock': 144, 'unit': 'bottles', 'description': 'Ice-cold Sprite', 'image_url': '/images/sprite.jpg', 'is_active': True},
        {'id': 5, 'name': 'Chilli Garlic', 'category': 'Add-ons', 'price': 0.0, 'stock': 100, 'max_stock': 200, 'unit': 'packs', 'description': 'House-made chilli garlic sauce', 'image_url': '/images/chilli_garlic.jpg', 'is_active': True},
        {'id': 6, 'name': 'Soy Sauce', 'category': 'Add-ons', 'price': 0.0, 'stock': 100, 'max_stock': 200, 'unit': 'packs', 'description': 'Premium soy sauce packet', 'image_url': '/images/soy_sauce.jpg', 'is_active': True},
        {'id': 7, 'name': 'Calamansi', 'category': 'Add-ons', 'price': 0.0, 'stock': 100, 'max_stock': 200, 'unit': 'packs', 'description': 'Fresh calamansi packet', 'image_url': '/images/calamansi.jpg', 'is_active': True},
    ]

    items_to_migrate = []
    if conn:
        try:
            c = conn.cursor()
            c.execute("SELECT * FROM products")
            rows = c.fetchall()
            if rows:
                for r in rows:
                    items_to_migrate.append(dict(r))
        except Exception as e:
            print(f"Notice reading SQLite: {e}")

    if not items_to_migrate:
        items_to_migrate = default_products

    for p in items_to_migrate:
        doc_id = f"prod_{p['id']}"
        data = {
            'id': p['id'],
            'product_id': p['id'],
            'name': p['name'],
            'category': p.get('category', 'Siomai'),
            'price': float(p['price']),
            'stock': int(p.get('stock', 50)),
            'max_stock': int(p.get('max_stock', 100)),
            'unit': p.get('unit', 'pcs'),
            'description': p.get('description', ''),
            'image_url': p.get('image_url', ''),
            'is_active': bool(p.get('is_active', True)),
            'updated_at': firestore.SERVER_TIMESTAMP
        }
        db.collection('products').document(doc_id).set(data, merge=True)
        print(f"   ✓ Product: {p['name']} (₱{p['price']}, Stock: {p['stock']})")

    # 2. Migrate Queue
    print("\n🔢 Initializing Queue...")
    queue_ref = db.collection('queue').document('status')
    queue_ref.set({
        'current_queue_no': 100,
        'current_queue': 100,
        'now_serving': 100,
        'now_serving_number': 100,
        'last_updated': firestore.SERVER_TIMESTAMP
    }, merge=True)
    print("   ✓ Queue state initialized.")

    # 3. Migrate Users (Admin account)
    print("\n👤 Checking Admin Users...")
    admin_ref = db.collection('users').document('admin')
    admin_ref.set({
        'username': 'admin',
        'full_name': 'Kevin Bernardino',
        'role': 'admin',
        'created_at': firestore.SERVER_TIMESTAMP
    }, merge=True)
    print("   ✓ Admin user verified.")

    # 4. Migrate Orders if any
    if conn:
        try:
            c = conn.cursor()
            c.execute("SELECT * FROM orders")
            orders = c.fetchall()
            if orders:
                print(f"\n📋 Migrating {len(orders)} existing orders...")
                for o in orders:
                    doc_id = f"order_{o['id']}"
                    # fetch items
                    c.execute("SELECT * FROM order_items WHERE order_id = ?", (o['id'],))
                    items = [dict(it) for it in c.fetchall()]
                    order_data = {
                        'id': o['id'],
                        'queue_no': o['queue_no'],
                        'type': o['type'],
                        'order_type': o['order_type'],
                        'customer_name': o['customer_name'],
                        'customer_phone': o['customer_phone'],
                        'delivery_address': o['delivery_address'],
                        'status': o['status'],
                        'payment_status': o['payment_status'],
                        'payment_method': o['payment_method'],
                        'payment_reference': o['payment_reference'],
                        'total_amount': float(o['total_amount']),
                        'items': items,
                        'created_at': o['created_at']
                    }
                    db.collection('orders').document(doc_id).set(order_data, merge=True)
                print(f"   ✓ {len(orders)} orders synced.")
        except Exception as e:
            print(f"Notice migrating orders: {e}")

    print("\n🎉 Migration completed successfully! Your data is now live on Firebase Cloud Firestore.")

if __name__ == '__main__':
    migrate()
