import os
import sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

# Ensure 'app' always refers to this exact module instance even when run as '__main__'
if __name__ == '__main__':
    sys.modules['app'] = sys.modules[__name__]

import threading
import time
from flask import Flask, send_from_directory, request, Response
from flask_cors import CORS
from flask_socketio import SocketIO
from models import db
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

socketio = SocketIO()
_app_instance = None

# ──────────────────────────────────────────────────────────────
# PRODUCT CATALOGUE  (single source of truth)
# ──────────────────────────────────────────────────────────────
PRODUCT_CATALOGUE = [
    # Main item
    dict(name='HotSpot Siomai',   category='Siomai',  price=10.0,  stock=200, max_stock=500, unit='pcs',
         description='Signature HotSpot Siomai – ₱10 per piece',
         image_url='/images/hotspot_siomai.jpg'),
    # Drinks
    dict(name='Coke',             category='Drinks',  price=25.0,  stock=48,  max_stock=144, unit='cans',
         description='Ice-cold Coca-Cola',
         image_url='/images/coke.jpg'),
    dict(name='Royal',            category='Drinks',  price=25.0,  stock=48,  max_stock=144, unit='bottles',
         description='Ice-cold Royal Tru-Orange (Bottle)',
         image_url='/images/royal.jpg'),
    dict(name='Sprite',           category='Drinks',  price=25.0,  stock=48,  max_stock=144, unit='cans',
         description='Ice-cold Sprite',
         image_url='/images/sprite.jpg'),
    # Add-ons (condiments – charged separately only if you want)
    dict(name='Chilli Garlic',    category='Add-ons', price=0.0,   stock=100, max_stock=200, unit='packs',
         description='House-made chilli garlic sauce',
         image_url='/images/chilli_garlic.jpg'),
    dict(name='Soy Sauce',        category='Add-ons', price=0.0,   stock=100, max_stock=200, unit='packs',
         description='Premium soy sauce packet',
         image_url='/images/soy_sauce.jpg'),
    dict(name='Calamansi',        category='Add-ons', price=0.0,   stock=100, max_stock=200, unit='packs',
         description='Fresh calamansi packet',
         image_url='/images/calamansi.jpg'),
]


def _configure_database(app):
    """Configure SQLAlchemy for Aiven (MySQL / PostgreSQL) or local SQLite fallback."""
    from urllib.parse import urlparse, parse_qs, urlencode, urlunparse

    default_sqlite = f"sqlite:///{os.path.join(os.path.dirname(__file__), 'kevs_siomai.db')}"
    raw_uri = (os.getenv('DATABASE_URL') or '').strip()

    if not raw_uri:
        app.config['SQLALCHEMY_DATABASE_URI'] = default_sqlite
        return

    # Normalize scheme for SQLAlchemy drivers
    if raw_uri.startswith('mysql://'):
        raw_uri = 'mysql+pymysql://' + raw_uri[len('mysql://'):]
    elif raw_uri.startswith('postgres://'):
        raw_uri = 'postgresql://' + raw_uri[len('postgres://'):]

    engine_options = {
        'pool_pre_ping': True,
        'pool_recycle': 280,
    }

    # Handle Aiven MySQL ?ssl-mode=REQUIRED query param for PyMySQL compatibility
    if raw_uri.startswith('mysql+pymysql://'):
        parsed = urlparse(raw_uri)
        query_params = parse_qs(parsed.query)
        ssl_mode = query_params.pop('ssl-mode', query_params.pop('ssl_mode', None))
        clean_query = urlencode(query_params, doseq=True)
        raw_uri = urlunparse(parsed._replace(query=clean_query))

        if ssl_mode or 'aivencloud.com' in (parsed.hostname or ''):
            import ssl
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            engine_options['connect_args'] = {'ssl': ctx}

    app.config['SQLALCHEMY_DATABASE_URI'] = raw_uri
    app.config['SQLALCHEMY_ENGINE_OPTIONS'] = engine_options


def create_app(test_config=None):
    global _app_instance
    if test_config is None and _app_instance is not None:
        return _app_instance

    # Always serve frontend directly (the exact dashboard UI seen in the user's screenshot)
    frontend_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'frontend'))
    app = Flask(__name__, static_folder=frontend_dir, static_url_path='')

    # ── Config ────────────────────────────────────────────────────────────────
    app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', 'kevs-siomai-secret-2024')
    _configure_database(app)
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

    if test_config:
        app.config.update(test_config)

    # ── Extensions ────────────────────────────────────────────────────────────
    CORS(app, resources={r'/*': {'origins': '*'}})
    db.init_app(app)
    socketio.init_app(app, cors_allowed_origins='*', async_mode='threading')

    # ── Explicit CORS Handler for Mobile & Remote Devices ─────────────────────
    @app.before_request
    def handle_preflight():
        if request.method == 'OPTIONS':
            from flask import Response
            resp = Response()
            origin = request.headers.get('Origin', '*')
            resp.headers['Access-Control-Allow-Origin'] = origin if origin else '*'
            resp.headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS, PATCH'
            resp.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization, X-Requested-With, Accept'
            resp.headers['Access-Control-Allow-Credentials'] = 'true'
            return resp

    @app.after_request
    def add_cors_headers(response):
        origin = request.headers.get('Origin', '*')
        response.headers['Access-Control-Allow-Origin'] = origin if origin else '*'
        response.headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS, PATCH'
        response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization, X-Requested-With, Accept'
        response.headers['Access-Control-Allow-Credentials'] = 'true'

        # Live Terminal Activity Logging
        try:
            p = request.path
            if not p.startswith('/socket.io'):
                is_poll = request.method == 'GET' and (p.endswith('/queue') or p.endswith('/stats') or p == '/favicon.ico')
                if not is_poll:
                    status_icon = "OK" if response.status_code < 400 else "ERR"
                    print(f"  [{status_icon}] [{request.method}] {p} -> {response.status_code}", flush=True)
        except Exception:
            pass

        return response

    # ── Security / WAF ────────────────────────────────────────────────────────
    from firewall import waf, firewall_api
    waf.init_app(app)
    app.register_blueprint(firewall_api)

    # ── API Routes ────────────────────────────────────────────────────────────
    from routes import api
    app.register_blueprint(api)

    # ── Product Images Server ─────────────────────────────────────────────────
    @app.route('/images/<path:filename>')
    def serve_product_images(filename):
        img_dir = os.path.join(os.path.dirname(__file__), 'static', 'images')
        resp = send_from_directory(img_dir, filename)
        resp.headers['Cache-Control'] = 'no-cache, must-revalidate, max-age=0'
        return resp

    # ── Mobile App Static File Server (/mobile) ───────────────────────────────
    mobile_build_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'mobile_app', 'build', 'web'))

    @app.route('/mobile', defaults={'path': ''})
    @app.route('/mobile/', defaults={'path': ''})
    @app.route('/mobile/<path:path>')
    def serve_mobile_app(path):
        try:
            if os.path.isdir(mobile_build_dir):
                if path:
                    fp = os.path.join(mobile_build_dir, path)
                    if os.path.isfile(fp):
                        return send_from_directory(mobile_build_dir, path)
                index = os.path.join(mobile_build_dir, 'index.html')
                if os.path.isfile(index):
                    return send_from_directory(mobile_build_dir, 'index.html')
            return '<h2>Mobile build not found. Please build the mobile web app first.</h2>', 404
        except Exception as e:
            import traceback
            traceback.print_exc()
            return f'Server Error in serve_mobile_app: {e}', 500

    # ── SPA Static File Server (Admin / Cashier Dashboard) ────────────────────
    @app.route('/', defaults={'path': ''})
    @app.route('/<path:path>')
    def serve_frontend(path):
        if path.startswith('api/') or path == 'api' or path.startswith('mobile/') or path == 'mobile':
            return {'error': 'Route not found'}, 404
        sf = app.static_folder
        if sf and os.path.isdir(sf):
            if path:
                fp = os.path.join(sf, path)
                if os.path.isfile(fp):
                    return send_from_directory(sf, path)
                public_fp = os.path.join(sf, 'public', path)
                if os.path.isfile(public_fp):
                    return send_from_directory(os.path.join(sf, 'public'), path)
            index = os.path.join(sf, 'index.html')
            if os.path.isfile(index):
                return send_from_directory(sf, 'index.html')
        return '<h2>🥟 KEVS Siomai – backend running. Build the frontend first.</h2>', 200

    # ── Socket.IO Events ──────────────────────────────────────────────────────
    @socketio.on('connect')
    def _on_connect():
        try:
            from routes import _get_queue_data
            socketio.emit('queue_updated', _get_queue_data(), to=request.sid)
        except Exception as e:
            print(f'[SocketIO] connect error: {e}')

    @socketio.on('disconnect')
    def _on_disconnect():
        pass  # Silently accept disconnects

    @socketio.on('request_queue_update')
    def _on_request_update():
        try:
            from routes import _get_queue_data
            socketio.emit('queue_updated', _get_queue_data(), to=request.sid)
        except Exception as e:
            print(f'[SocketIO] update error: {e}')

    # ── DB Init & Seed ────────────────────────────────────────────────────────
    with app.app_context():
        try:
            db.create_all()
        except Exception as dbe:
            print(f"⚠️ [Database Notice] Remote DB not reachable ({dbe}). Using local SQLite store...")
            sqlite_uri = f"sqlite:///{os.path.join(os.path.dirname(__file__), 'kevs_siomai.db')}"
            app.config['SQLALCHEMY_DATABASE_URI'] = sqlite_uri
            app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {}
            db._app_engines.get(app, {}).clear()
            db.create_all()
        _seed_initial_data()

    # ── Firebase Cloud Firestore ──────────────────────────────────────────────
    try:
        from firebase_client import (
            get_firestore_db,
            start_cloud_order_sync_listener,
            hydrate_orders_from_firestore,
            hydrate_payment_accounts_from_firestore,
            hydrate_products_from_firestore,
        )
        try:
            get_firestore_db()
            print("🔥 [Firebase] Cloud Firestore Admin SDK is ACTIVE and connected to project 'boss-kevs'!")
        except Exception as fe:
            print(f"ℹ️ [Firebase] Service account key not detected ({fe}). Operating via Cloud Firestore REST API!")
        
        # Hydrate existing historical records, products, and payment accounts from Firestore on startup
        hydrate_products_from_firestore(app)
        hydrate_payment_accounts_from_firestore(app)
        hydrate_orders_from_firestore(app)
        start_cloud_order_sync_listener(app, socketio)
    except Exception as fe:
        print(f"⚠️ [Firebase] Could not initialize Firestore listener: {fe}")

    _app_instance = app
    return app


def _seed_initial_data():
    """Seed admin, new product catalogue, payment accounts, and non-destructive schema migrations."""
    import hashlib
    from sqlalchemy import text
    from models import User, Product, Order, OrderItem, Sale, Queue, PaymentAccount
    from datetime import datetime, timezone

    # ── Safe non-destructive SQLite column migrations for existing databases ───
    order_columns = [
        ("payment_account_id", "VARCHAR(64) DEFAULT ''"),
        ("payment_account_name", "VARCHAR(120) DEFAULT ''"),
        ("payment_provider", "VARCHAR(60) DEFAULT ''"),
        ("payment_confirmed_at", "DATETIME NULL"),
    ]
    for col_name, col_def in order_columns:
        try:
            db.session.execute(text(f"ALTER TABLE orders ADD COLUMN {col_name} {col_def}"))
            db.session.commit()
        except Exception:
            db.session.rollback()

    # ── Admin user ─────────────────────────────────────────────────────────────
    if not User.query.first():
        db.session.add(User(
            username='admin',
            password_hash=hashlib.sha256('kevs2024'.encode()).hexdigest(),
            full_name='Kevin Bernardino',
            role='admin'
        ))

    # ── Queue row ──────────────────────────────────────────────────────────────
    if not Queue.query.first():
        db.session.add(Queue(current_queue_no=0, now_serving=0))

    # ── Products — ensure catalogue items exist ────────────────────────────────
    for cat_item in PRODUCT_CATALOGUE:
        if not Product.query.filter_by(name=cat_item['name']).first():
            db.session.add(Product(**cat_item))
    db.session.flush()

    # ── Default Online Receiving Payment Accounts ──────────────────────────────
    if PaymentAccount.query.count() == 0:
        db.session.add(PaymentAccount(
            account_id='acct_gcash_1',
            account_name='GCash Primary (InstaPay)',
            provider='GCash / InstaPay',
            account_holder_name='JA****E B.',
            mobile_number='+63 993 104 ••••',
            qr_image_url='/images/gcash_instapay_qr_1.jpg',
            limit_type='count',
            transaction_limit=5.0,
            confirmed_count=0,
            confirmed_amount=0.0,
            is_active=True,
            priority=1,
        ))
        db.session.add(PaymentAccount(
            account_id='acct_gcash_2',
            account_name='GCash Backup Account',
            provider='GCash',
            account_holder_name='JO*N LL**D C.',
            mobile_number='+63 921 296 ••••',
            qr_image_url='/images/gcash_qr.png',
            limit_type='count',
            transaction_limit=10.0,
            confirmed_count=0,
            confirmed_amount=0.0,
            is_active=True,
            priority=2,
        ))
        db.session.flush()

    # Reviews start empty (submitted by users via app)
    db.session.commit()
    print('[Init] Database ready. Admin: admin / kevs2024')


app = create_app()


def _open_browser(url, delay=1.5):
    """Open browser after server starts. Only called when launched directly (not via root app.py)."""
    def _run():
        time.sleep(delay)
        try:
            import webbrowser
            webbrowser.open(url)
        except Exception:
            pass
    threading.Thread(target=_run, daemon=True).start()


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')

    port = int(os.getenv('PORT', 5000))
    url  = f'http://localhost:{port}'

    print('\n' + '=' * 65)
    print('  🥟  KEVS SIOMAI — INTEGRATED ORDER MANAGEMENT SYSTEM')
    print('=' * 65)
    print(f'  ➜ Website:    {url}/')
    print(f'  ➜ API Health: {url}/api/products')
    print(f'  ➜ Login:      admin  /  kevs2024')
    print('=' * 65 + '\n')

    # Only open browser when launched directly (not via root app.py launcher or cloud host)
    # Root app.py sets KEVS_LAUNCHED env var to prevent duplicate tabs
    if not os.environ.get('KEVS_LAUNCHED') and not os.environ.get('RENDER'):
        _open_browser(url)

    socketio.run(app, host='0.0.0.0', port=port, debug=False, allow_unsafe_werkzeug=True)
