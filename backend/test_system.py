"""
==============================================================================
  🧪 KEVS SIOMAI — FULL SYSTEM VERIFICATION SUITE
==============================================================================
Tests all endpoints, database operations, business logic, analytics,
and Web Application Firewall (WAF) intrusion prevention.
"""

import json
import pytest
from app import create_app
from models import db, User, Product, Order, Queue
from firewall import waf


@pytest.fixture
def app_instance():
    app = create_app(test_config={
        'TESTING': True,
        'SQLALCHEMY_DATABASE_URI': 'sqlite:///:memory:'
    })
    with app.app_context():
        # Ensure test queue exists
        if not Queue.query.first():
            db.session.add(Queue(current_queue_no=0, now_serving=0))
        # Ensure test product exists
        if not Product.query.first():
            p = Product(name='Hotspot Siomai', price=45.0, stock=50, max_stock=100)
            db.session.add(p)
        db.session.commit()
        yield app
        db.session.remove()
        db.drop_all()


@pytest.fixture
def client(app_instance):
    return app_instance.test_client()


# ─────────────────────────────────────────────────────────────────────────────
# 1. AUTHENTICATION TESTS
# ─────────────────────────────────────────────────────────────────────────────
def test_login_success(client):
    res = client.post('/api/auth/login', json={'username': 'admin', 'password': 'kevs2024'})
    assert res.status_code == 200
    data = res.get_json()
    assert 'token' in data
    assert data['user']['username'] == 'admin'


def test_login_failure(client):
    res = client.post('/api/auth/login', json={'username': 'admin', 'password': 'wrongpassword'})
    assert res.status_code == 401
    assert 'error' in res.get_json()


# ─────────────────────────────────────────────────────────────────────────────
# 2. QUEUE & ORDER TESTS
# ─────────────────────────────────────────────────────────────────────────────
def test_queue_add_and_call_next(client):
    # Add order to queue
    payload = {
        'type': 'walk-in',
        'order_type': 'pickup',
        'customer_name': 'Test Juan',
        'items': [{'product_id': 1, 'quantity': 2}],
        'payment_method': 'Cash'
    }
    res = client.post('/api/queue/add', json=payload)
    assert res.status_code == 201
    data = res.get_json()
    new_q_no = data['order']['queue_no']
    assert new_q_no > 0
    assert data['order']['customer_name'] == 'Test Juan'

    # Call next customer
    call_res = client.post('/api/queue/call-next')
    assert call_res.status_code == 200
    call_data = call_res.get_json()
    assert call_data['now_serving'] > 0

    # Verify queue display
    disp = client.get('/api/queue/display')
    assert disp.status_code == 200
    assert disp.get_json()['now_serving'] == call_data['now_serving']


def test_queue_reset(client):
    res = client.post('/api/queue/reset')
    assert res.status_code == 200
    data = res.get_json()
    assert data['queue']['current_queue_no'] == 0
    assert data['queue']['now_serving'] == 0


# ─────────────────────────────────────────────────────────────────────────────
# 3. INVENTORY TESTS
# ─────────────────────────────────────────────────────────────────────────────
def test_inventory_stock_adjustment(client):
    # Check initial stock
    prod_res = client.get('/api/products')
    assert prod_res.status_code == 200
    products = prod_res.get_json()['products']
    p_id = products[0]['id']
    initial_stock = products[0]['stock']

    # Adjust stock by +10
    adj_res = client.put(f'/api/inventory/{p_id}', json={'adjustment': 10})
    assert adj_res.status_code == 200
    assert adj_res.get_json()['product']['stock'] == initial_stock + 10


def test_create_and_delete_product(client):
    res = client.post('/api/products', json={
        'name': 'Fried Wonton',
        'category': 'Dumplings',
        'price': 40.0,
        'stock': 30,
        'max_stock': 80
    })
    assert res.status_code == 201
    p = res.get_json()['product']
    assert p['name'] == 'Fried Wonton'

    # Deactivate
    del_res = client.delete(f"/api/products/{p['id']}")
    assert del_res.status_code == 200


# ─────────────────────────────────────────────────────────────────────────────
# 4. ANALYTICS TESTS
# ─────────────────────────────────────────────────────────────────────────────
def test_analytics_endpoints(client):
    res_desc = client.get('/api/analytics/descriptive')
    assert res_desc.status_code == 200
    desc = res_desc.get_json()
    assert 'summary' in desc
    assert 'top_products' in desc

    res_pred = client.get('/api/analytics/predictive')
    assert res_pred.status_code == 200
    pred = res_pred.get_json()
    assert 'next_day_forecast' in pred

    res_presc = client.get('/api/analytics/prescriptive')
    assert res_presc.status_code == 200


def test_analytics_export_csv(client):
    # Test basic export
    res = client.get('/api/analytics/export-csv')
    assert res.status_code == 200
    assert 'text/csv' in res.content_type
    assert 'Content-Disposition' in res.headers
    assert 'filename="kevs_siomai_sales_' in res.headers['Content-Disposition']
    assert 'X-Record-Count' in res.headers
    assert 'X-Total-Revenue' in res.headers
    csv_text = res.get_data(as_text=True)
    assert csv_text.startswith('\ufeffOrder ID,Transaction Date,Customer Name')
    lines = csv_text.splitlines()
    assert len(lines) >= 1  # Header row present

    # Test filtering by status
    res_status = client.get('/api/analytics/export-csv?status=pending')
    assert res_status.status_code == 200

    # Test filtering by custom date
    res_date = client.get('/api/analytics/export-csv?range=custom&start_date=2026-10-01&end_date=2026-10-31')
    assert res_date.status_code == 200



# ─────────────────────────────────────────────────────────────────────────────
# 5. OFFLINE SYNC TESTS
# ─────────────────────────────────────────────────────────────────────────────
def test_offline_sync(client):
    batch = {
        'batch_id': 'test-batch-uuid-001',
        'orders': [{
            'customer_name': 'Offline Maria',
            'type': 'walk-in',
            'order_type': 'pickup',
            'total': 90.0,
            'status': 'completed',
            'payment_status': 'confirmed',
            'created_at': '2026-09-27T10:00:00'
        }]
    }
    res = client.post('/api/offline/sync', json=batch)
    assert res.status_code == 200
    assert res.get_json()['orders_synced'] == 1


# ─────────────────────────────────────────────────────────────────────────────
# 6. WEB APPLICATION FIREWALL (WAF) TESTS
# ─────────────────────────────────────────────────────────────────────────────
def test_firewall_blocks_sqli(client):
    res = client.get("/api/products?search=' OR 1=1 --")
    assert res.status_code == 403
    data = res.get_json()
    assert data['waf_status'] == 'blocked'
    assert data['threat_type'] == 'SQL_INJECTION'


def test_firewall_blocks_xss(client):
    res = client.get("/api/products?filter=<script>alert('xss')</script>")
    assert res.status_code == 403
    data = res.get_json()
    assert data['waf_status'] == 'blocked'
    assert data['threat_type'] == 'XSS_ATTACK'


def test_firewall_blocks_path_traversal(client):
    res = client.get("/api/products?file=../../../../etc/passwd")
    assert res.status_code == 403
    data = res.get_json()
    assert data['waf_status'] == 'blocked'
    assert data['threat_type'] == 'PATH_TRAVERSAL'


def test_firewall_security_headers(client):
    res = client.get("/api/products")
    assert res.status_code == 200
    assert res.headers.get('X-Content-Type-Options') == 'nosniff'
    assert res.headers.get('X-Frame-Options') == 'SAMEORIGIN'
    assert res.headers.get('X-XSS-Protection') == '1; mode=block'
    assert 'Content-Security-Policy' in res.headers


def test_firewall_test_simulator_and_logs(client):
    res = client.post('/api/firewall/test', json={'threat_type': 'sqli'})
    assert res.status_code == 200
    assert 'result' in res.get_json()

    logs_res = client.get('/api/firewall/logs')
    assert logs_res.status_code == 200
    logs = logs_res.get_json()['logs']
    assert len(logs) > 0


# ─────────────────────────────────────────────────────────────────────────────
# 7. INPUT VALIDATION TESTS
# ─────────────────────────────────────────────────────────────────────────────
def test_customer_name_validation_rejects_repeated_chars(client):
    """Ensure invalid names like 'jammmm' or 'aaaa' are rejected with 400 Bad Request."""
    invalid_names = ['jammmm', 'aaaa', 'Johnnnn', 'Maaaaaria', '!!!', 'A']
    for bad_name in invalid_names:
        res = client.post('/api/queue/add', json={
            'customer_name': bad_name,
            'order_type': 'pickup',
            'items': [{'product_id': 1, 'quantity': 1}]
        })
        assert res.status_code == 400, f"Expected 400 for '{bad_name}', got {res.status_code}"
        assert 'error' in res.get_json()


def test_customer_name_validation_accepts_legitimate_names(client):
    """Ensure legitimate Filipino, compound, hyphenated, and accented names pass validation."""
    valid_names = [
        'Juan Dela Cruz',
        'Maria Clara',
        'Jose Rizal',
        'John-Paul',
        'Ma. Cristina Santos',
        'Niña Gomez',
        'Bong-Bong',
        'Jam-Jam',
        "O'Connor",
        'Walk-in Customer'
    ]
    for good_name in valid_names:
        res = client.post('/api/queue/add', json={
            'customer_name': good_name,
            'order_type': 'pickup',
            'items': [{'product_id': 1, 'quantity': 1}]
        })
        assert res.status_code == 201, f"Expected 201 for '{good_name}', got {res.status_code}: {res.get_json()}"
        assert res.get_json()['order']['customer_name'] == good_name


def test_product_validation_rules(client):
    """Ensure product name, price, stock, and max_stock are validated."""
    # Reject 3+ repeated characters in product name
    res1 = client.post('/api/products', json={
        'name': 'Siomaiiiii',
        'price': 45.0,
        'stock': 10,
        'max_stock': 100
    })
    assert res1.status_code == 400
    assert 'error' in res1.get_json()

    # Reject negative price
    res2 = client.post('/api/products', json={
        'name': 'Beef Siomai',
        'price': -10.0,
        'stock': 10,
        'max_stock': 100
    })
    assert res2.status_code == 400

    # Reject negative stock
    res3 = client.post('/api/products', json={
        'name': 'Pork Siomai Special',
        'price': 50.0,
        'stock': -5,
        'max_stock': 100
    })
    assert res3.status_code == 400

    # Accept valid product
    res4 = client.post('/api/products', json={
        'name': 'Pork & Shrimp Siomai',
        'category': 'Siomai',
        'price': 55.0,
        'stock': 25,
        'max_stock': 100,
        'unit': 'pcs'
    })
    assert res4.status_code == 201


def test_order_date_validation(client):
    """Ensure malformed date strings return 400 Bad Request."""
    res_bad = client.get('/api/orders?start_date=not-a-valid-date')
    assert res_bad.status_code == 400
    assert 'error' in res_bad.get_json()

    res_good = client.get('/api/orders?start_date=2026-10-01')
    assert res_good.status_code == 200


def test_review_validation(client):
    """Ensure review rating, name, and comment limits are strictly validated."""
    # Invalid rating (> 5)
    res_rating = client.post('/api/reviews', json={'rating': 6, 'comment': 'Good'})
    assert res_rating.status_code == 400

    # Invalid repeated characters in reviewer name
    res_name = client.post('/api/reviews', json={'rating': 5, 'customer_name': 'jammmm'})
    assert res_name.status_code == 400

    # Valid review
    res_ok = client.post('/api/reviews', json={
        'rating': 5,
        'customer_name': 'Maria Cristina',
        'comment': 'Napakasarap ng siomai!'
    })
    assert res_ok.status_code == 201


def test_login_validation_rules(client):
    """Ensure empty or excessively short username/password are rejected with 400."""
    res_short_user = client.post('/api/auth/login', json={'username': 'a', 'password': 'kevs2024'})
    assert res_short_user.status_code == 400

    res_short_pass = client.post('/api/auth/login', json={'username': 'admin', 'password': '1'})
    assert res_short_pass.status_code == 400

