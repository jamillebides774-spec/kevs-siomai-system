from app import app
import json

client = app.test_client()

# Products
r = client.get('/api/products')
d = json.loads(r.data)
print('\n=== NEW PRODUCTS ===')
for p in d.get('products', []):
    name = p['name']
    cat = p['category']
    price = p['price']
    print(f'  {name} ({cat}) - P{price}')

# Orders
r2 = client.get('/api/queue')
d2 = json.loads(r2.data)
print(f'\nTotal seeded orders shown: {len(d2.get("orders", []))}')

# Analytics
r3 = client.get('/api/analytics/descriptive')
d3 = json.loads(r3.data)
print(f'Total sales revenue: P{d3.get("total_sales", 0):.2f}')
print(f'Total orders: {d3.get("total_orders", 0)}')

# Login test
r4 = client.post('/api/auth/login', json={'username': 'admin', 'password': 'kevs2024'},
                 content_type='application/json')
print('Login:', r4.status_code, json.loads(r4.data).get('message', ''))

print('\n=== ALL OK ===')
