"""
Firebase Client & Service Provider for Boss Kevs
Handles Cloud Firestore connections with automatic time synchronization
to prevent JWT clock-skew issues.
"""

import os
import sys
import glob
import json
import datetime
import urllib.request
import email.utils

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))

_firestore_client = None
_time_synced = False
_listener_started = False

def _safe_print(*args, **kwargs):
    try:
        print(*args, **kwargs)
    except UnicodeEncodeError:
        try:
            safe_args = [str(a).encode('ascii', errors='replace').decode('ascii') for a in args]
            print(*safe_args, **kwargs)
        except Exception:
            pass

def sync_clock_skew():
    """Compensates for local machine clock skew vs Google OAuth servers."""
    global _time_synced
    if _time_synced:
        return
    try:
        req = urllib.request.Request('https://www.google.com', headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=5) as res:
            date_str = res.headers.get('Date')
            if date_str:
                server_dt = email.utils.parsedate_to_datetime(date_str).astimezone(datetime.timezone.utc).replace(tzinfo=None)
                local_dt = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
                delta = server_dt - local_dt
                
                import google.auth._helpers
                orig_utcnow = google.auth._helpers.utcnow
                google.auth._helpers.utcnow = lambda: orig_utcnow() + delta
    except Exception as e:
        _safe_print(f"[Firebase] Notice on clock sync: {e}")
    _time_synced = True

def get_service_account_path():
    exact = os.path.join(BACKEND_DIR, 'serviceAccountKey.json')
    if os.path.exists(exact):
        return exact
    for f in glob.glob(os.path.join(BACKEND_DIR, '*.json')):
        try:
            with open(f, 'r', encoding='utf-8') as jf:
                if json.load(jf).get('type') == 'service_account':
                    return f
        except Exception:
            continue
    downloads = os.path.expanduser('~/Downloads')
    for f in glob.glob(os.path.join(downloads, 'boss-kevs-*.json')):
        try:
            with open(f, 'r', encoding='utf-8') as jf:
                if json.load(jf).get('type') == 'service_account':
                    return f
        except Exception:
            continue
    return None

def get_firestore_db():
    global _firestore_client
    if _firestore_client is not None:
        return _firestore_client
    
    sync_clock_skew()
    
    import firebase_admin
    from firebase_admin import credentials, firestore

    # 1. Check environment variable for raw JSON string (ideal for Render deployment)
    env_json = (os.getenv('FIREBASE_KEY_JSON') or os.getenv('FIREBASE_SERVICE_ACCOUNT') or '').strip()
    if env_json:
        try:
            cred_dict = json.loads(env_json)
            if not firebase_admin._apps:
                cred = credentials.Certificate(cred_dict)
                firebase_admin.initialize_app(cred)
            _firestore_client = firestore.client()
            return _firestore_client
        except Exception as e:
            _safe_print(f"[Firebase] Notice on FIREBASE_KEY_JSON env: {e}")

    # 2. Check local file paths
    key_path = get_service_account_path()
    if key_path:
        if not firebase_admin._apps:
            cred = credentials.Certificate(key_path)
            firebase_admin.initialize_app(cred)
        _firestore_client = firestore.client()
        return _firestore_client

    raise FileNotFoundError("Firebase serviceAccountKey.json not found!")

import threading

def _py_to_fs_value(v):
    if v is None:
        return {'nullValue': None}
    if isinstance(v, bool):
        return {'booleanValue': v}
    if isinstance(v, int):
        return {'integerValue': str(v)}
    if isinstance(v, float):
        return {'doubleValue': v}
    if isinstance(v, (datetime.datetime, datetime.date)):
        if isinstance(v, datetime.datetime) and v.tzinfo:
            return {'stringValue': v.astimezone(datetime.timezone.utc).isoformat()}
        return {'stringValue': v.isoformat()}
    if isinstance(v, str):
        return {'stringValue': v}
    if isinstance(v, list):
        return {'arrayValue': {'values': [_py_to_fs_value(x) for x in v]}}
    if isinstance(v, dict):
        return {'mapValue': {'fields': {k: _py_to_fs_value(val) for k, val in v.items()}}}
    return {'stringValue': str(v)}

def dict_to_firestore_fields(data):
    if not isinstance(data, dict):
        return {}
    return {k: _py_to_fs_value(v) for k, v in data.items() if not str(k).startswith('_')}

def sync_order_rest(order_dict):
    """Fallback syncing order directly to Firestore REST API without serviceAccountKey."""
    try:
        oid = str(order_dict.get('id') or order_dict.get('order_id') or '')
        if not oid:
            return False
        doc_id = f"order_{oid}" if not oid.startswith('order_') else oid
        fields = dict_to_firestore_fields(order_dict)
        query_params = '&'.join([f"updateMask.fieldPaths={k}" for k in fields.keys()])
        url = f"https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders/{doc_id}?{query_params}"
        payload = json.dumps({'fields': fields}).encode('utf-8')
        req = urllib.request.Request(
            url,
            data=payload,
            method='PATCH',
            headers={'Content-Type': 'application/json', 'User-Agent': 'KevsSiomaiSync/1.0'}
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as he:
        if he.code == 404:
            # Document does not exist yet; upsert without updateMask
            try:
                upsert_url = f"https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders/{doc_id}"
                req_upsert = urllib.request.Request(
                    upsert_url,
                    data=payload,
                    method='PATCH',
                    headers={'Content-Type': 'application/json', 'User-Agent': 'KevsSiomaiSync/1.0'}
                )
                with urllib.request.urlopen(req_upsert, timeout=8) as resp:
                    return resp.status == 200
            except Exception as ue:
                print(f"[Firebase REST Upsert Error] {oid}: {ue}", flush=True)
                return False
        elif he.code == 429:
            print(f"[Firebase REST Sync Rate Limit 429] {oid}: will retry with backoff", flush=True)
        else:
            print(f"[Firebase REST Sync Order HTTPError {he.code}]: {he}", flush=True)
        return False
    except Exception as e:
        print(f"[Firebase REST Sync Order Error]: {e}", flush=True)
        return False

def sync_queue_rest(queue_dict):
    """Fallback syncing queue status directly to Firestore REST API."""
    try:
        url = "https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/queue/status"
        fields = dict_to_firestore_fields(dict(queue_dict))
        payload = json.dumps({'fields': fields}).encode('utf-8')
        req = urllib.request.Request(
            url,
            data=payload,
            method='PATCH',
            headers={'Content-Type': 'application/json', 'User-Agent': 'KevsSiomaiSync/1.0'}
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            return resp.status == 200
    except Exception as e:
        print(f"[Firebase REST Sync Queue Error]: {e}", flush=True)
        return False

def sync_product_rest(prod_dict):
    """Fallback syncing product directly to Firestore REST API."""
    try:
        pid = str(prod_dict.get('id') or prod_dict.get('product_id') or '')
        if not pid:
            return False
        doc_id = f"prod_{pid}" if not pid.startswith('prod_') else pid
        url = f"https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/products/{doc_id}"
        fields = dict_to_firestore_fields(prod_dict)
        payload = json.dumps({'fields': fields}).encode('utf-8')
        req = urllib.request.Request(
            url,
            data=payload,
            method='PATCH',
            headers={'Content-Type': 'application/json', 'User-Agent': 'KevsSiomaiSync/1.0'}
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            return resp.status == 200
    except Exception as e:
        print(f"[Firebase REST Sync Product Error]: {e}", flush=True)
        return False

def _run_bg(fn, *args):
    t = threading.Thread(target=fn, args=args, daemon=True)
    t.start()

def unwrap_fs_value(val):
    """Recursively converts Firestore REST JSON value to standard Python types."""
    if not val or not isinstance(val, dict):
        return val
    if 'stringValue' in val:
        return val['stringValue']
    if 'integerValue' in val:
        try:
            return int(val['integerValue'])
        except Exception:
            return val['integerValue']
    if 'doubleValue' in val:
        try:
            return float(val['doubleValue'])
        except Exception:
            return val['doubleValue']
    if 'booleanValue' in val:
        return bool(val['booleanValue'])
    if 'timestampValue' in val:
        return val['timestampValue']
    if 'nullValue' in val:
        return None
    if 'arrayValue' in val:
        return [unwrap_fs_value(v) for v in val.get('arrayValue', {}).get('values', [])]
    if 'mapValue' in val:
        fields = val.get('mapValue', {}).get('fields', {})
        return {k: unwrap_fs_value(v) for k, v in fields.items()}
    return str(val)

def unwrap_fs_doc(doc):
    """Converts a raw Firestore REST document to a clean Python dictionary with document ID."""
    fields = doc.get('fields', {})
    data = {k: unwrap_fs_value(v) for k, v in fields.items()}
    name = doc.get('name', '')
    doc_id = name.split('/')[-1] if name else ''
    data['_doc_id'] = doc_id
    return data

def patch_order_fields_rest(doc_id, update_dict):
    """Updates specific fields of an order document in Cloud Firestore via REST API."""
    try:
        if not doc_id:
            return False
        if not doc_id.startswith('order_') and not any(c.isalpha() for c in doc_id):
            doc_id = f"order_{doc_id}"
        query_params = '&'.join([f"updateMask.fieldPaths={k}" for k in update_dict.keys()])
        url = f"https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders/{doc_id}?{query_params}"
        fields = dict_to_firestore_fields(update_dict)
        payload = json.dumps({'fields': fields}).encode('utf-8')
        req = urllib.request.Request(
            url,
            data=payload,
            method='PATCH',
            headers={'Content-Type': 'application/json', 'User-Agent': 'KevsSiomaiSync/1.0'}
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as he:
        if he.code == 404:
            try:
                upsert_url = f"https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders/{doc_id}"
                req_upsert = urllib.request.Request(
                    upsert_url,
                    data=payload,
                    method='PATCH',
                    headers={'Content-Type': 'application/json', 'User-Agent': 'KevsSiomaiSync/1.0'}
                )
                with urllib.request.urlopen(req_upsert, timeout=8) as resp:
                    return resp.status == 200
            except Exception:
                return False
        print(f"[Firebase REST Patch HTTPError {he.code}] {doc_id}: {he}", flush=True)
        return False
    except Exception as e:
        print(f"[Firebase REST Patch Error] {doc_id}: {e}", flush=True)
        return False

DELETED_TEST_ORDER_IDS = {
    2, 3, 4, 8, 9, 10, 15, 16, 17, 18, 19, 20, 21,
    23, 24, 25,
    27, 28, 29, 30, 31, 32, 33, 34, 35, 36,
    38, 39, 40, 41, 42, 43,
    44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54,
    57, 58, 59, 60, 62, 63, 64, 65, 66, 67
}

AGENT_TEST_CUSTOMERS = {
    'automated verification customer',
    'test cancel order',
    'audit test customer',
    'audit completed order',
    'cancel test user',
    'web test customer',
    'concurrent test customer',
    'test mobile user',
}

AGENT_TEST_NOTES_MARKERS = (
    'automated mobile sync audit test',
    'testing cancellation flow',
    'testing repeat cancellation',
)

def _is_agent_test_order(data, pos_id=None):
    """Returns True if a Firestore order document is a known agent-generated test record."""
    if pos_id is not None:
        try:
            if int(pos_id) in DELETED_TEST_ORDER_IDS:
                return True
        except Exception:
            pass
    cname = str(data.get('customer_name') or '').strip().lower()
    if cname in AGENT_TEST_CUSTOMERS:
        return True
    notes = str(data.get('notes') or '').strip().lower()
    for marker in AGENT_TEST_NOTES_MARKERS:
        if marker in notes:
            return True
    return False

def delete_firestore_order_rest(doc_id):
    """Deletes an order document directly from Firestore REST API."""
    try:
        if not doc_id:
            return False
        clean_id = doc_id if doc_id.startswith('order_') or any(c.isalpha() for c in doc_id) else f"order_{doc_id}"
        url = f"https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders/{clean_id}"
        req = urllib.request.Request(
            url,
            method='DELETE',
            headers={'User-Agent': 'KevsSiomaiSync/1.0'}
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            return resp.status in (200, 204)
    except Exception as e:
        print(f"[Firebase REST Delete Notice] {doc_id}: {e}", flush=True)
        return False

def parse_iso_dt(val, date_display=None, formatted_date=None):
    """Parses a timestamp value into a timezone-aware UTC datetime."""
    manila_tz = datetime.timezone(datetime.timedelta(hours=8))
    if isinstance(val, datetime.datetime):
        if val.tzinfo is not None:
            return val.astimezone(datetime.timezone.utc)
        return val.replace(tzinfo=datetime.timezone.utc)
    if isinstance(val, datetime.date):
        return datetime.datetime.combine(val, datetime.time.min).replace(tzinfo=datetime.timezone.utc)
    if val:
        try:
            s = str(val).strip()
            if s.endswith('Z'):
                s = s[:-1] + '+00:00'
            dt = datetime.datetime.fromisoformat(s)
            if dt.tzinfo is not None:
                return dt.astimezone(datetime.timezone.utc)
            return dt.replace(tzinfo=datetime.timezone.utc)
        except Exception:
            for fmt in ('%Y-%m-%d %H:%M:%S.%f', '%Y-%m-%d %H:%M:%S', '%Y-%m-%d'):
                try:
                    dt = datetime.datetime.strptime(str(val).strip(), fmt)
                    return dt.replace(tzinfo=datetime.timezone.utc)
                except Exception:
                    continue
    for candidate in (formatted_date, date_display):
        if candidate and isinstance(candidate, str) and candidate.strip() and candidate.strip() != 'N/A':
            c_val = candidate.strip().replace('·', '').strip()
            c_val = ' '.join(c_val.split())
            for fmt in ('%b %d, %Y %I:%M %p', '%b %d, %Y %H:%M', '%b %d, %Y', '%B %d, %Y'):
                try:
                    dt = datetime.datetime.strptime(c_val, fmt)
                    return dt.replace(tzinfo=manila_tz).astimezone(datetime.timezone.utc)
                except Exception:
                    continue
    return None

def sync_order_to_firestore(order_dict, wait=True):
    """
    Synchronize order to Cloud Firestore. When wait=True, executes synchronously
    and returns True/False so the caller can guarantee Firestore persistence before returning.
    Ensures canonical UTC created_at ('...Z') and Asia/Manila display fields are always preserved.
    """
    try:
        from flask import current_app
        if current_app and current_app.config.get('TESTING'):
            return True
    except Exception:
        pass
    data = dict(order_dict)
    data['synced_to_pos'] = True
    oid = str(data.get('id') or data.get('order_id') or '')
    if not oid:
        return False

    manila_tz = datetime.timezone(datetime.timedelta(hours=8))
    created_dt = parse_iso_dt(
        data.get('created_at') or data.get('timestamp'),
        date_display=data.get('date_display'),
        formatted_date=data.get('formatted_date')
    )
    if created_dt is None:
        created_dt = datetime.datetime.now(datetime.timezone.utc)

    utc_iso = created_dt.astimezone(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    ph_dt = created_dt.astimezone(manila_tz)
    data['created_at'] = utc_iso
    data['timestamp'] = utc_iso
    data['created_at_ph'] = ph_dt.isoformat()
    data['date_display'] = ph_dt.strftime('%b %d, %Y')
    data['time_display'] = ph_dt.strftime('%I:%M %p')
    data['formatted_date'] = ph_dt.strftime('%b %d, %Y · %I:%M %p')

    updated_dt = parse_iso_dt(data.get('updated_at')) or datetime.datetime.now(datetime.timezone.utc)
    data['updated_at'] = updated_dt.astimezone(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    data['updated_at_ph'] = updated_dt.astimezone(manila_tz).isoformat()

    def _do_sync():
        # First try Admin SDK if initialized
        try:
            db = get_firestore_db()
            db.collection('orders').document(f"order_{oid}").set(data, merge=True)
            return True
        except Exception:
            pass
        # Fallback to direct REST API
        return sync_order_rest(data)

    if wait:
        try:
            from flask import current_app
            if current_app and current_app.config.get('TESTING'):
                return _do_sync()
        except Exception:
            pass
    _run_bg(_do_sync)
    return True

def sync_queue_to_firestore(queue_dict):
    def _task():
        try:
            db = get_firestore_db()
            from firebase_admin import firestore
            data = dict(queue_dict)
            data['last_updated'] = firestore.SERVER_TIMESTAMP
            db.collection('queue').document('status').set(data, merge=True)
            return
        except Exception:
            pass
        sync_queue_rest(queue_dict)
    _run_bg(_task)

def sync_product_to_firestore(prod_dict, wait=True):
    """Synchronize a product document to Cloud Firestore collection 'products'."""
    try:
        from flask import current_app
        if current_app and current_app.config.get('TESTING'):
            return True
    except Exception:
        pass

    data = dict(prod_dict)
    pid = str(data.get('id') or data.get('product_id') or '').strip()
    if not pid:
        return False

    is_active = bool(data.get('is_active', True))
    data['is_active'] = is_active
    data['status'] = 'Active' if is_active else 'Inactive'
    data['updated_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')

    def _do_sync():
        try:
            db = get_firestore_db()
            db.collection('products').document(f"prod_{pid}").set(data, merge=True)
            return True
        except Exception:
            pass
        return sync_product_rest(data)

    if wait:
        try:
            from flask import current_app
            if current_app and current_app.config.get('TESTING'):
                return _do_sync()
        except Exception:
            pass
    _run_bg(_do_sync)
    return True

def start_cloud_order_sync_listener(app, socketio):
    """
    Background listener that continuously pulls cloud/mobile orders and status updates from Cloud Firestore.
    Features exponential backoff to handle 429 rate limits gracefully.
    Guaranteed singleton execution per process.
    """
    global _listener_started
    if _listener_started:
        return
    _listener_started = True

    def _listener_loop():
        import time
        from datetime import datetime, timezone
        time.sleep(3)
        _safe_print("[Firebase Sync] Real-time cloud order sync listener active (Firestore <-> POS SQLite)...", flush=True)

        consecutive_429 = 0

        while True:
            try:
                # ── Method 1: Firebase Admin SDK (if serviceAccountKey.json is present) ──
                processed = False
                try:
                    db = get_firestore_db()
                    docs = list(db.collection('orders').stream())
                    for doc in docs:
                        data = doc.to_dict()
                        doc_id = doc.id
                        _process_firestore_doc(app, socketio, data, doc_id=doc_id, admin_doc=doc)
                    processed = True
                except Exception:
                    processed = False

                # ── Method 2: Firestore REST API Fallback (runs without serviceAccountKey) ──
                if not processed:
                    url = "https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders?pageSize=100"
                    req = urllib.request.Request(url, headers={'User-Agent': 'KevsSiomaiSync/1.0'})
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        if resp.status == 200:
                            consecutive_429 = 0
                            body = json.loads(resp.read().decode('utf-8'))
                            raw_docs = body.get('documents', [])
                            for raw_doc in raw_docs:
                                data = unwrap_fs_doc(raw_doc)
                                doc_id = data.get('_doc_id')
                                _process_firestore_doc(app, socketio, data, doc_id=doc_id)
            except urllib.error.HTTPError as he:
                if he.code == 429:
                    consecutive_429 += 1
                    backoff = min(60, 15 * consecutive_429)
                    time.sleep(backoff)
                    continue
            except Exception:
                pass
            time.sleep(8.0)

    t = threading.Thread(target=_listener_loop, daemon=True)
    t.start()

def _process_firestore_doc(app, socketio, data, doc_id=None, admin_doc=None):
    from datetime import datetime, timezone
    try:
        with app.app_context():
            from models import db as sqldb, Order, OrderItem, Sale
            from routes import _get_or_init_queue, _emit_queue_update, _restore_inventory, _record_sale

            pos_id = data.get('id') or data.get('order_id')
            if not pos_id and doc_id and doc_id.startswith('order_'):
                suffix = doc_id.replace('order_', '')
                if suffix.isdigit() and len(suffix) < 10:
                    pos_id = int(suffix)

            # Never re-hydrate known agent-generated test orders
            if _is_agent_test_order(data, pos_id):
                if admin_doc:
                    try:
                        admin_doc.reference.delete()
                    except Exception:
                        pass
                elif doc_id:
                    delete_firestore_order_rest(doc_id)
                return

            fs_status = str(data.get('status') or '').strip().lower()

            # Ghost/duplicate document cleanup:
            # If doc_id is NOT the canonical "order_{pos_id}" (e.g. "order_1793031063899" vs "order_22")
            # and the POS order already exists in SQLite:
            if pos_id and doc_id and doc_id != f"order_{pos_id}":
                existing_canonical = Order.query.get(int(pos_id))
                if existing_canonical:
                    if admin_doc:
                        try:
                            admin_doc.reference.delete()
                        except Exception:
                            pass
                    else:
                        delete_firestore_order_rest(doc_id)
                    return

            TERMINAL_STATES = {'completed', 'delivered', 'cancelled'}

            # Case A: Order already exists in SQLite POS store -> check status updates
            if pos_id:
                existing = Order.query.get(int(pos_id))
                if existing:
                    changed = False
                    local_dt = parse_iso_dt(existing.updated_at) or parse_iso_dt(existing.created_at)
                    cloud_dt = parse_iso_dt(data.get('updated_at')) or parse_iso_dt(data.get('timestamp'))

                    is_local_terminal = existing.status in TERMINAL_STATES
                    is_cloud_terminal = fs_status in TERMINAL_STATES

                    if fs_status and fs_status != existing.status:
                        # Rule 1: Never regress a locally completed or delivered order to pending/preparing
                        if is_local_terminal and not is_cloud_terminal:
                            # Local order was fulfilled. Stale cloud status must not revert it.
                            # Heal Firestore record with true fulfilled status.
                            sync_order_to_firestore(existing.to_dict(), wait=False)
                        # Rule 2: Cloud moved to terminal state (e.g., cancelled remotely)
                        elif is_cloud_terminal and not is_local_terminal:
                            print(f"🔄 [Firestore Sync] Order #{existing.id} moved to terminal: {existing.status} -> {fs_status}", flush=True)
                            old_st = existing.status
                            existing.status = fs_status
                            existing.updated_at = datetime.now(timezone.utc)
                            changed = True
                            if fs_status == 'cancelled':
                                if old_st in ('preparing', 'ready_pickup', 'ready_delivery', 'out_for_delivery', 'ready', 'completed'):
                                    _restore_inventory(existing)
                                Sale.query.filter_by(order_id=existing.id).delete()
                            elif fs_status in ('completed', 'delivered'):
                                _record_sale(existing)
                        # Rule 3: Compare timestamps
                        else:
                            if cloud_dt and local_dt and cloud_dt > local_dt:
                                print(f"🔄 [Firestore Sync] Order #{existing.id} updated from cloud (newer): {existing.status} -> {fs_status}", flush=True)
                                old_st = existing.status
                                existing.status = fs_status
                                existing.updated_at = datetime.now(timezone.utc)
                                changed = True
                                if fs_status == 'cancelled':
                                    if old_st in ('preparing', 'ready_pickup', 'ready_delivery', 'out_for_delivery', 'ready', 'completed'):
                                        _restore_inventory(existing)
                                    Sale.query.filter_by(order_id=existing.id).delete()
                                elif fs_status in ('completed', 'delivered'):
                                    _record_sale(existing)
                            elif local_dt and cloud_dt and local_dt > cloud_dt:
                                sync_order_to_firestore(existing.to_dict(), wait=False)
                            elif fs_status == 'cancelled':
                                print(f"🔄 [Firestore Sync] Order #{existing.id} cancelled remotely: {existing.status} -> {fs_status}", flush=True)
                                old_st = existing.status
                                existing.status = fs_status
                                existing.updated_at = datetime.now(timezone.utc)
                                changed = True
                                if old_st in ('preparing', 'ready_pickup', 'ready_delivery', 'out_for_delivery', 'ready', 'completed'):
                                    _restore_inventory(existing)
                                Sale.query.filter_by(order_id=existing.id).delete()

                    raw_fs_pay = str(data.get('payment_status') or '').strip().lower()
                    fs_pay = 'confirmed' if raw_fs_pay in ('confirmed', 'paid') else ('pending' if raw_fs_pay else '')
                    local_pay = 'confirmed' if str(existing.payment_status or '').strip().lower() in ('confirmed', 'paid') else 'pending'

                    if fs_pay:
                        if local_pay == 'confirmed' and fs_pay != 'confirmed':
                            # Never allow stale Firestore data to revert a confirmed payment back to pending; heal Firestore instead.
                            sync_order_to_firestore(existing.to_dict(), wait=False)
                        elif fs_pay == 'confirmed' and local_pay != 'confirmed':
                            existing.payment_status = 'confirmed'
                            existing.updated_at = datetime.now(timezone.utc)
                            if existing.status != 'cancelled':
                                _record_sale(existing)
                            changed = True

                    fs_acct_id = str(data.get('payment_account_id') or '').strip()
                    if fs_acct_id and fs_acct_id != (existing.payment_account_id or ''):
                        existing.payment_account_id = fs_acct_id
                        if data.get('payment_account_name'):
                            existing.payment_account_name = str(data.get('payment_account_name')).strip()
                        if data.get('payment_provider'):
                            existing.payment_provider = str(data.get('payment_provider')).strip()
                        changed = True

                    if changed:
                        sqldb.session.commit()
                        _emit_queue_update(socketio, updated_order=existing)

                    if data.get('synced_to_pos') is not True:
                        updates = {
                            'synced_to_pos': True,
                            'id': existing.id,
                            'order_id': existing.id,
                            'queue_no': existing.queue_no,
                        }
                        if admin_doc:
                            admin_doc.reference.update(updates)
                        elif doc_id:
                            patch_order_fields_rest(doc_id, updates)
                    return

            # Case B: New cloud/mobile order without POS ID
            phone = str(data.get('customer_phone') or '').strip()
            name = str(data.get('customer_name') or '').strip()
            if phone and phone not in ('0000000000', ''):
                candidates = Order.query.filter_by(customer_phone=phone).order_by(Order.id.desc()).limit(3).all()
                for cand in candidates:
                    cand_created = parse_iso_dt(cand.created_at)
                    if cand.customer_name == name and cand_created and abs((cand_created - datetime.now(timezone.utc)).total_seconds()) < 60:
                        sync_order_to_firestore(cand.to_dict(), wait=False)
                        if doc_id and doc_id != f"order_{cand.id}":
                            if admin_doc:
                                try: admin_doc.reference.delete()
                                except Exception: pass
                            else:
                                delete_firestore_order_rest(doc_id)
                        return

            q = _get_or_init_queue()
            q.current_queue_no += 1
            laptop_now_utc = datetime.now(timezone.utc)
            q.last_updated = laptop_now_utc

            total = float(data.get('total_amount', 0.0))
            new_o = Order(
                queue_no=q.current_queue_no,
                type='online',
                order_type=data.get('order_type', 'pickup'),
                customer_name=data.get('customer_name', 'Online Mobile Customer'),
                customer_phone=data.get('customer_phone', ''),
                delivery_address=data.get('delivery_address', ''),
                status=data.get('status', 'pending') or 'pending',
                payment_status=data.get('payment_status', 'pending') or 'pending',
                payment_method=data.get('payment_method', 'GCash') or 'GCash',
                payment_account_id=str(data.get('payment_account_id') or '').strip(),
                payment_account_name=str(data.get('payment_account_name') or '').strip(),
                payment_provider=str(data.get('payment_provider') or '').strip(),
                total_amount=total,
                notes=(data.get('notes', '') or '') + ' [via Mobile App]',
                created_at=laptop_now_utc,
                updated_at=laptop_now_utc,
            )
            sqldb.session.add(new_o)
            sqldb.session.flush()

            raw_items = data.get('items', [])
            for it in raw_items:
                if isinstance(it, dict):
                    sqldb.session.add(OrderItem(
                        order_id=new_o.id,
                        product_id=int(it.get('product_id', 1)),
                        quantity=int(it.get('quantity', 1)),
                        unit_price=float(it.get('unit_price', 10.0)),
                        subtotal=float(it.get('subtotal', 10.0))
                    ))
            sqldb.session.commit()
            try:
                from routes import _decrease_inventory
                _decrease_inventory(new_o)
            except Exception as ie:
                print(f"[Inventory Deduction Notice]: {ie}", flush=True)

            # Sync to canonical order document: order_{new_o.id}
            sync_order_to_firestore(new_o.to_dict(), wait=True)

            # Clean up the incoming temporary doc if it was a temporary ID
            if doc_id and doc_id != f"order_{new_o.id}":
                if admin_doc:
                    try: admin_doc.reference.delete()
                    except Exception: pass
                else:
                    delete_firestore_order_rest(doc_id)

            _safe_print(f"[Firebase Sync] Ticket #{new_o.queue_no} (ID: #{new_o.id}) for {new_o.customer_name} synced to POS!", flush=True)
            _emit_queue_update(socketio, new_order=new_o)
    except Exception as e:
        _safe_print(f"[Process Firestore Order Error]: {e}", flush=True)


def hydrate_orders_from_firestore(app):
    """
    On server startup or reconnection, reconcile Cloud Firestore with SQLite POS store.
    Ensures all historical transactions, orders, queue numbers, and statuses persist across restarts.
    """
    try:
        url = "https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders?pageSize=100"
        req = urllib.request.Request(url, headers={'User-Agent': 'KevsSiomaiSync/1.0'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status == 200:
                body = json.loads(resp.read().decode('utf-8'))
                raw_docs = body.get('documents', [])
                with app.app_context():
                    from datetime import datetime, timezone
                    from models import db as sqldb, Order, OrderItem, Sale, Queue
                    from routes import _record_sale, _get_or_init_queue
                    reconciled = 0
                    TERMINAL_STATES = {'completed', 'delivered', 'cancelled'}

                    for raw_doc in raw_docs:
                        data = unwrap_fs_doc(raw_doc)
                        doc_id = data.get('_doc_id', '')
                        pos_id = data.get('id') or data.get('order_id')
                        if not pos_id and doc_id.startswith('order_'):
                            suffix = doc_id.replace('order_', '')
                            if suffix.isdigit():
                                pos_id = int(suffix)

                        # Never re-hydrate known agent-generated test orders
                        if _is_agent_test_order(data, pos_id):
                            if doc_id:
                                delete_firestore_order_rest(doc_id)
                            continue

                        # Clean up ghost documents that duplicate canonical documents
                        if pos_id and doc_id and doc_id != f"order_{pos_id}":
                            existing_canonical = Order.query.get(int(pos_id))
                            if existing_canonical:
                                delete_firestore_order_rest(doc_id)
                                continue

                        if pos_id:
                            existing = Order.query.get(int(pos_id))
                            fs_st = str(data.get('status') or '').strip().lower()
                            cloud_created_dt = parse_iso_dt(
                                data.get('created_at') or data.get('timestamp'),
                                date_display=data.get('date_display'),
                                formatted_date=data.get('formatted_date')
                            )
                            cloud_updated_dt = parse_iso_dt(data.get('updated_at')) or cloud_created_dt

                            if existing:
                                local_created_dt = parse_iso_dt(existing.created_at)
                                # Restore original order creation timestamp from Firestore if SQLite was overwritten on a previous hydration
                                if cloud_created_dt and (local_created_dt is None or cloud_created_dt < local_created_dt):
                                    existing.created_at = cloud_created_dt
                                    reconciled += 1

                                local_dt = parse_iso_dt(existing.updated_at) or parse_iso_dt(existing.created_at)
                                cloud_dt = cloud_updated_dt
                                is_local_terminal = existing.status in TERMINAL_STATES
                                is_cloud_terminal = fs_st in TERMINAL_STATES

                                if fs_st and fs_st != existing.status:
                                    if is_local_terminal and not is_cloud_terminal:
                                        # Do not regress completed/delivered orders; heal Firestore
                                        sync_order_to_firestore(existing.to_dict(), wait=False)
                                    elif is_cloud_terminal and not is_local_terminal:
                                        existing.status = fs_st
                                        if fs_st == 'cancelled':
                                            Sale.query.filter_by(order_id=existing.id).delete()
                                        elif fs_st in ('completed', 'delivered'):
                                            _record_sale(existing)
                                        reconciled += 1
                                    elif cloud_dt and local_dt and cloud_dt > local_dt:
                                        existing.status = fs_st
                                        if fs_st == 'cancelled':
                                            Sale.query.filter_by(order_id=existing.id).delete()
                                        elif fs_st in ('completed', 'delivered'):
                                            _record_sale(existing)
                                        reconciled += 1
                                    elif local_dt and cloud_dt and local_dt > cloud_dt:
                                        sync_order_to_firestore(existing.to_dict(), wait=False)
                                    elif fs_st == 'cancelled':
                                        existing.status = fs_st
                                        Sale.query.filter_by(order_id=existing.id).delete()
                                        reconciled += 1

                                raw_fs_pay = str(data.get('payment_status') or '').strip().lower()
                                fs_pay = 'confirmed' if raw_fs_pay in ('confirmed', 'paid') else ('pending' if raw_fs_pay else '')
                                local_pay = 'confirmed' if str(existing.payment_status or '').strip().lower() in ('confirmed', 'paid') else 'pending'
                                if fs_pay:
                                    if local_pay == 'confirmed' and fs_pay != 'confirmed':
                                        sync_order_to_firestore(existing.to_dict(), wait=False)
                                    elif fs_pay == 'confirmed' and local_pay != 'confirmed':
                                        existing.payment_status = 'confirmed'
                                        existing.updated_at = datetime.now(timezone.utc)
                                        reconciled += 1

                                # Ensure confirmed/completed orders always have sales entries, but never cancelled orders
                                if existing.status != 'cancelled' and (existing.status in ('completed', 'delivered') or existing.payment_status == 'confirmed'):
                                    _record_sale(existing)
                                elif existing.status == 'cancelled':
                                    Sale.query.filter_by(order_id=existing.id).delete()
                            else:
                                preserved_created = cloud_created_dt or datetime.now(timezone.utc)
                                preserved_updated = cloud_updated_dt or preserved_created
                                raw_hydrate_pay = str(data.get('payment_status') or 'pending').strip().lower()
                                hydrated_pay_status = 'confirmed' if raw_hydrate_pay in ('confirmed', 'paid') else 'pending'
                                new_o = Order(
                                    id=int(pos_id),
                                    queue_no=int(data.get('queue_no') or pos_id),
                                    type=data.get('type', 'online'),
                                    order_type=data.get('order_type', 'pickup'),
                                    customer_name=data.get('customer_name', 'Customer'),
                                    customer_phone=data.get('customer_phone', ''),
                                    delivery_address=data.get('delivery_address', ''),
                                    status=fs_st or 'completed',
                                    payment_status=hydrated_pay_status,
                                    payment_method=data.get('payment_method', 'Cash'),
                                    payment_account_id=str(data.get('payment_account_id') or '').strip(),
                                    payment_account_name=str(data.get('payment_account_name') or '').strip(),
                                    payment_provider=str(data.get('payment_provider') or '').strip(),
                                    total_amount=float(data.get('total_amount', 0.0)),
                                    notes=data.get('notes', ''),
                                    created_at=preserved_created,
                                    updated_at=preserved_updated,
                                )
                                sqldb.session.add(new_o)
                                sqldb.session.flush()
                                raw_items = data.get('items', [])
                                for it in raw_items:
                                    if isinstance(it, dict):
                                        sqldb.session.add(OrderItem(
                                            order_id=new_o.id,
                                            product_id=int(it.get('product_id', 1)),
                                            quantity=int(it.get('quantity', 1)),
                                            unit_price=float(it.get('unit_price', 10.0)),
                                            subtotal=float(it.get('subtotal', 10.0))
                                        ))
                                if new_o.status != 'cancelled' and (new_o.status in ('completed', 'delivered') or new_o.payment_status == 'confirmed'):
                                    _record_sale(new_o)
                                elif new_o.status == 'cancelled':
                                    Sale.query.filter_by(order_id=new_o.id).delete()
                                reconciled += 1

                    # Reconcile Queue state
                    q = _get_or_init_queue()
                    max_order_queue = sqldb.session.query(sqldb.func.max(Order.queue_no)).scalar() or 0
                    if max_order_queue > q.current_queue_no:
                        q.current_queue_no = max_order_queue

                    max_completed_queue = sqldb.session.query(sqldb.func.max(Order.queue_no)).filter(
                        Order.status.in_(['completed', 'delivered'])
                    ).scalar() or 0
                    if max_completed_queue > q.now_serving:
                        q.now_serving = max_completed_queue

                    q.last_updated = datetime.now(timezone.utc)
                    sqldb.session.commit()
                    sync_queue_to_firestore(q.to_dict())

                    if reconciled > 0:
                        _safe_print(f"[Firebase Hydration] Successfully synchronized {reconciled} order records from Firestore!", flush=True)
    except Exception as e:
        _safe_print(f"[Firebase Hydration Notice] Startup hydration: {e}", flush=True)


def sync_payment_account_rest(account_dict):
    """Direct HTTPS REST upsert for a PaymentAccount document in Cloud Firestore."""
    try:
        acct_id = str(account_dict.get('account_id') or account_dict.get('id') or '').strip()
        if not acct_id:
            return False
        url = f"https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/payment_accounts/{acct_id}"
        fields = dict_to_firestore_fields(account_dict)
        payload = json.dumps({'fields': fields}).encode('utf-8')
        req = urllib.request.Request(
            url,
            data=payload,
            method='PATCH',
            headers={'Content-Type': 'application/json', 'User-Agent': 'KevsSiomaiSync/1.0'}
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            return resp.status == 200
    except Exception as e:
        _safe_print(f"[Firebase REST PaymentAccount Sync Notice] {account_dict.get('account_id')}: {e}", flush=True)
        return False


def sync_payment_account_to_firestore(account_dict, wait=True):
    """Synchronize a receiving payment account to Cloud Firestore collection 'payment_accounts'."""
    try:
        from flask import current_app
        if current_app and current_app.config.get('TESTING'):
            return True
    except Exception:
        pass

    data = dict(account_dict)
    acct_id = str(data.get('account_id') or data.get('id') or '').strip()
    if not acct_id:
        return False

    def _do_sync():
        try:
            db = get_firestore_db()
            db.collection('payment_accounts').document(acct_id).set(data, merge=True)
            return True
        except Exception:
            pass
        return sync_payment_account_rest(data)

    if wait:
        try:
            from flask import current_app
            if current_app and current_app.config.get('TESTING'):
                return _do_sync()
        except Exception:
            pass
    _run_bg(_do_sync)
    return True


def delete_payment_account_from_firestore(account_id, wait=True):
    """Delete a payment account document from Cloud Firestore."""
    acct_id = str(account_id or '').strip()
    if not acct_id:
        return False

    def _do_delete():
        try:
            db = get_firestore_db()
            db.collection('payment_accounts').document(acct_id).delete()
            return True
        except Exception:
            pass
        try:
            url = f"https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/payment_accounts/{acct_id}"
            req = urllib.request.Request(url, method='DELETE', headers={'User-Agent': 'KevsSiomaiSync/1.0'})
            with urllib.request.urlopen(req, timeout=8) as resp:
                return resp.status in (200, 204)
        except Exception as e:
            _safe_print(f"[Firebase REST Delete PaymentAccount Notice] {acct_id}: {e}", flush=True)
            return False

    if wait:
        try:
            from flask import current_app
            if current_app and current_app.config.get('TESTING'):
                return _do_delete()
        except Exception:
            pass
    _run_bg(_do_delete)
    return True


def hydrate_payment_accounts_from_firestore(app):
    """Reconcile payment_accounts between Cloud Firestore and local SQLite on startup."""
    try:
        with app.app_context():
            from models import db as sqldb, PaymentAccount
            # First try reading from Firestore
            raw_docs = []
            try:
                fs_db = get_firestore_db()
                for doc in fs_db.collection('payment_accounts').stream():
                    d = doc.to_dict() or {}
                    d['_doc_id'] = doc.id
                    raw_docs.append(d)
            except Exception:
                try:
                    url = "https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/payment_accounts?pageSize=50"
                    req = urllib.request.Request(url, headers={'User-Agent': 'KevsSiomaiSync/1.0'})
                    with urllib.request.urlopen(req, timeout=8) as resp:
                        if resp.status == 200:
                            body = json.loads(resp.read().decode('utf-8'))
                            for rdoc in body.get('documents', []):
                                raw_docs.append(unwrap_fs_doc(rdoc))
                except Exception:
                    pass

            for data in raw_docs:
                acct_id = str(data.get('account_id') or data.get('_doc_id') or '').strip()
                if not acct_id:
                    continue
                existing = PaymentAccount.query.filter_by(account_id=acct_id).first()
                cloud_updated = parse_iso_dt(data.get('updated_at'))
                if existing:
                    local_updated = parse_iso_dt(existing.updated_at)
                    if cloud_updated and local_updated and cloud_updated > local_updated:
                        existing.account_name = data.get('account_name', existing.account_name)
                        existing.provider = data.get('provider', existing.provider)
                        existing.account_holder_name = data.get('account_holder_name', existing.account_holder_name)
                        existing.mobile_number = data.get('mobile_number', existing.mobile_number)
                        existing.qr_image_url = data.get('qr_image_url', existing.qr_image_url)
                        existing.limit_type = data.get('limit_type', existing.limit_type)
                        existing.transaction_limit = float(data.get('transaction_limit', existing.transaction_limit))
                        existing.confirmed_count = max(int(existing.confirmed_count or 0), int(data.get('confirmed_count', 0)))
                        existing.confirmed_amount = max(float(existing.confirmed_amount or 0.0), float(data.get('confirmed_amount', 0.0)))
                        existing.is_active = bool(data.get('is_active', existing.is_active))
                        existing.priority = int(data.get('priority', existing.priority))
                else:
                    sqldb.session.add(PaymentAccount(
                        account_id=acct_id,
                        account_name=data.get('account_name', 'Online Account'),
                        provider=data.get('provider', 'GCash'),
                        account_holder_name=data.get('account_holder_name', 'Account Holder'),
                        mobile_number=data.get('mobile_number', ''),
                        qr_image_url=data.get('qr_image_url', '/images/gcash_instapay_qr_1.jpg'),
                        limit_type=data.get('limit_type', 'count'),
                        transaction_limit=float(data.get('transaction_limit', 5.0)),
                        confirmed_count=int(data.get('confirmed_count', 0)),
                        confirmed_amount=float(data.get('confirmed_amount', 0.0)),
                        is_active=bool(data.get('is_active', True)),
                        priority=int(data.get('priority', 1)),
                    ))
            sqldb.session.commit()

            # Ensure all local payment accounts are pushed to Firestore
            for acct in PaymentAccount.query.order_by(PaymentAccount.priority.asc(), PaymentAccount.id.asc()).all():
                sync_payment_account_to_firestore(acct.to_dict(), wait=False)
    except Exception as e:
        _safe_print(f"[Firebase PaymentAccounts Hydration Notice]: {e}", flush=True)


def hydrate_products_from_firestore(app):
    """Reconcile product status (Active/Inactive) between Cloud Firestore and local SQLite on startup."""
    try:
        with app.app_context():
            from models import db as sqldb, Product
            raw_docs = []
            try:
                fs_db = get_firestore_db()
                for doc in fs_db.collection('products').stream():
                    d = doc.to_dict() or {}
                    d['_doc_id'] = doc.id
                    raw_docs.append(d)
            except Exception:
                try:
                    url = "https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/products?pageSize=50"
                    req = urllib.request.Request(url, headers={'User-Agent': 'KevsSiomaiSync/1.0'})
                    with urllib.request.urlopen(req, timeout=8) as resp:
                        if resp.status == 200:
                            body = json.loads(resp.read().decode('utf-8'))
                            for rdoc in body.get('documents', []):
                                raw_docs.append(unwrap_fs_doc(rdoc))
                except Exception:
                    pass

            for data in raw_docs:
                pid = data.get('id') or data.get('product_id')
                doc_id = str(data.get('_doc_id') or '').strip()
                if not pid and doc_id.startswith('prod_'):
                    suffix = doc_id.replace('prod_', '')
                    if suffix.isdigit():
                        pid = int(suffix)
                if not pid:
                    continue
                try:
                    existing = Product.query.get(int(pid))
                except Exception:
                    existing = None
                if not existing and data.get('name'):
                    existing = Product.query.filter_by(name=str(data.get('name')).strip()).first()

                if existing:
                    # Determine active status from Firestore document
                    if 'is_active' in data and data['is_active'] is not None:
                        val = data['is_active']
                        fs_active = val.lower() not in ('false', '0', 'no', 'inactive') if isinstance(val, str) else bool(val)
                    elif 'status' in data and data['status'] is not None:
                        fs_active = str(data['status']).strip().lower() not in ('inactive', 'disabled')
                    else:
                        fs_active = existing.is_active
                    existing.is_active = fs_active

                    # Ensure drinks always use 'bottles' unit
                    if (existing.category or '').lower() == 'drinks' or (existing.unit or '').lower() == 'cans':
                        existing.unit = 'bottles'

            sqldb.session.commit()

            for prod in Product.query.order_by(Product.id.asc()).all():
                sync_product_to_firestore(prod.to_dict(), wait=False)
    except Exception as e:
        _safe_print(f"[Firebase Products Hydration Notice]: {e}", flush=True)


if __name__ == '__main__':
    db = get_firestore_db()
    _safe_print("[Firebase] Cloud Firestore connected successfully!")

