import base64
import csv
import hashlib
import io
import json
import os
import re
import threading
import urllib.request
import uuid
from datetime import datetime, timezone, timedelta
try:
    from zoneinfo import ZoneInfo
    MANILA_TZ = ZoneInfo('Asia/Manila')
except Exception:
    MANILA_TZ = timezone(timedelta(hours=8))
from flask import Blueprint, request, jsonify, Response
from models import db, User, Product, Order, OrderItem, Sale, Queue, OfflineSyncLog, Review, PaymentAccount
from analytics import get_descriptive_analytics, get_predictive_analytics, get_prescriptive_analytics

api = Blueprint('api', __name__, url_prefix='/api')

_PAYMENT_CONFIRM_LOCK = threading.Lock()


def _require_admin():
    """Enforce access permissions so customer clients cannot modify account limits or confirm payments."""
    role = (request.headers.get('X-Client-Role') or request.args.get('role') or '').strip().lower()
    if role == 'customer':
        return False, (jsonify({
            'error': 'Access denied: Only authorized administrators can modify payment accounts or confirm payments.'
        }), 403)
    return True, None


def _is_online_payment_method(method):
    if not method:
        return False
    return str(method).strip().lower() not in ('cash', 'cod', 'cash on delivery', '')


def _find_payment_account(account_ref):
    if account_ref is None or str(account_ref).strip() == '':
        return None
    ref_str = str(account_ref).strip()
    acct = PaymentAccount.query.filter_by(account_id=ref_str).first()
    if acct:
        return acct
    if ref_str.isdigit():
        return PaymentAccount.query.get(int(ref_str))
    return None


def _get_payment_accounts_payload():
    accounts = PaymentAccount.query.order_by(PaymentAccount.priority.asc(), PaymentAccount.id.asc()).all()
    accounts_list = [a.to_dict() for a in accounts]
    available_list = [a for a in accounts_list if a.get('is_available')]
    return {
        'accounts': accounts_list,
        'available_accounts': available_list,
        'has_available': len(available_list) > 0,
        'active_account': available_list[0] if available_list else None
    }


def _emit_payment_accounts_update(socketio=None):
    try:
        if socketio is None:
            from app import socketio as app_socketio
            socketio = app_socketio
        payload = _get_payment_accounts_payload()
        socketio.emit('payment_accounts_updated', payload)
    except Exception as e:
        print(f"[SocketIO payment_accounts_updated error]: {e}")


def _save_qr_image_if_base64(qr_data, account_id):
    if not qr_data or not isinstance(qr_data, str):
        return '/images/gcash_instapay_qr_1.jpg'
    val = qr_data.strip()
    if val.startswith('data:image/') and ';base64,' in val:
        try:
            header, b64_part = val.split(';base64,', 1)
            mime = header.split(':', 1)[1].lower()
            ext = 'png'
            if 'jpeg' in mime or 'jpg' in mime:
                ext = 'jpg'
            elif 'webp' in mime:
                ext = 'webp'
            raw_bytes = base64.b64decode(b64_part)
            safe_id = re.sub(r'[^a-zA-Z0-9_-]', '', str(account_id)) or 'acct'
            filename = f"qr_{safe_id}_{int(datetime.now(timezone.utc).timestamp())}.{ext}"
            base_dir = os.path.dirname(os.path.abspath(__file__))
            target_dirs = [
                os.path.join(base_dir, 'static', 'images'),
                os.path.normpath(os.path.join(base_dir, '..', 'frontend', 'images')),
                os.path.normpath(os.path.join(base_dir, '..', 'frontend', 'public', 'images')),
            ]
            for d in target_dirs:
                try:
                    os.makedirs(d, exist_ok=True)
                    with open(os.path.join(d, filename), 'wb') as f:
                        f.write(raw_bytes)
                except Exception as write_err:
                    print(f"[QR Save Warning] ({d}): {write_err}")
            return f"/images/{filename}"
        except Exception as e:
            print(f"[QR Base64 Decode Error]: {e}")
            return '/images/gcash_instapay_qr_1.jpg'
    return val


def _resolve_online_account_for_new_order(payment_method, requested_account_id=None):
    """Select and validate an available online payment account for a new order without consuming capacity yet."""
    if not _is_online_payment_method(payment_method):
        return True, None, None
    if requested_account_id:
        acct = _find_payment_account(requested_account_id)
        if not acct:
            return False, None, "Ang napiling online payment account ay hindi nahanap. Mangyaring pumili ng ibang available account."
        if not acct.is_available:
            return False, None, f"Ang payment account na '{acct.account_name}' ay hindi na available ({acct.status_label}). Mangyaring pumili ng ibang available account."
        return True, acct, None
    accounts = PaymentAccount.query.order_by(PaymentAccount.priority.asc(), PaymentAccount.id.asc()).all()
    avail = [a for a in accounts if a.is_available]
    if not avail:
        return False, None, "Online payment is temporarily unavailable dahil naabot na ng lahat ng receiving accounts ang kanilang transaction limit o naka-deactivate. Mangyaring piliin ang Cash o makipag-ugnayan sa kahera."
    return True, avail[0], None


# ─────────────────────────────────────────────
# INPUT VALIDATION HELPERS
# ─────────────────────────────────────────────
def _validate_person_name(name, field_name="Pangalan", min_len=2, max_len=60, allow_default=True):
    """
    Validate person/customer names:
    - Rejects invalid repeated-character strings (e.g., 'jammmm', 'aaaa', 'Johnnnn')
    - Accepts legitimate names: compound names ('Juan Dela Cruz', 'Maria Clara'),
      hyphens ('John-Paul', 'Bong-Bong', 'Jam-Jam'), apostrophes ("O'Connor", "D'Angelo"),
      abbreviations/periods ('Ma. Cristina', 'Jr.', 'Sr.'), Filipino characters ('Niña Gomez', 'José'),
      and system default labels ('Walk-in Customer', 'Online Customer', 'Offline Walk-in', etc.)
    """
    if not name or not isinstance(name, str) or not name.strip():
        return False, f"Kailangan ilagay ang {field_name}."

    cleaned = name.strip()

    if allow_default and cleaned in ("Walk-in Customer", "Online Customer", "Offline Walk-in", "Anonymous Customer", "Walk-in (ESP32 Button)"):
        return True, cleaned

    if len(cleaned) < min_len or len(cleaned) > max_len:
        return False, f"Ang {field_name} ay dapat nasa pagitan ng {min_len} hanggang {max_len} characters."

    # Reject 3 or more consecutive identical letters (e.g. 'jammmm', 'aaaa', 'Johnnnn')
    if re.search(r'([a-zA-Z\u00C0-\u024F\u1E00-\u1EFF])\1{2,}', cleaned, re.IGNORECASE):
        return False, f"Hindi wastong pangalan: Huwag gumamit ng paulit-ulit na mga titik tulad ng '{cleaned}'."

    # Cannot start or end with hyphen, apostrophe, or space
    if re.search(r"^[-'\s]|[-'\s]$", cleaned):
        return False, f"Ang {field_name} ay hindi maaaring magsimula o magtapos sa gitling, kudlit, o espasyo."

    # Cannot have consecutive punctuation (e.g., '--', "..", "''") or multiple consecutive spaces
    if re.search(r"[\'\-\.]{2,}", cleaned) or re.search(r"\s{2,}", cleaned):
        return False, f"Ang {field_name} ay hindi maaaring magkaroon ng sunod-sunod na bantas o espasyo."

    # Allowed characters: Latin & accented letters, spaces, hyphens, periods, apostrophes
    pattern = r"^[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF\s.'-]+$"
    if not re.match(pattern, cleaned):
        return False, f"Ang {field_name} ay maaari lamang maglaman ng mga titik, espasyo, gitling (-), tuldok (.), o kudlit (')."

    # Must contain at least 2 alphabetic letters
    letters = re.findall(r'[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF]', cleaned)
    if len(letters) < 2:
        return False, f"Ang {field_name} ay dapat magkaroon ng hindi bababa sa 2 titik."

    return True, cleaned

def _validate_product_name(name, min_len=2, max_len=80):
    """
    Validate product/item name:
    - Rejects excessive repeated characters (e.g. 'siomaiiiii', 'jammmm')
    - Allows alphanumeric, spaces, hyphens, periods, parentheses, ampersands, slashes, commas
    """
    if not name or not isinstance(name, str) or not name.strip():
        return False, "Kailangan ilagay ang pangalan ng produkto."

    cleaned = name.strip()
    if len(cleaned) < min_len or len(cleaned) > max_len:
        return False, f"Ang pangalan ng produkto ay dapat nasa pagitan ng {min_len} hanggang {max_len} characters."

    # Reject 3 or more consecutive identical characters
    if re.search(r'([a-zA-Z0-9])\1{2,}', cleaned, re.IGNORECASE):
        return False, f"Hindi wastong pangalan ng produkto: Huwag gumamit ng paulit-ulit na characters tulad ng '{cleaned}'."

    pattern = r"^[a-zA-Z0-9\u00C0-\u024F\u1E00-\u1EFF\s\-.,()&/]+$"
    if not re.match(pattern, cleaned):
        return False, "Ang pangalan ng produkto ay naglalaman ng mga hindi wastong character."

    letters = re.findall(r'[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF]', cleaned)
    if len(letters) < 2:
        return False, "Kailangan ng hindi bababa sa 2 titik para sa pangalan ng produkto."

    return True, cleaned

def _validate_phone_number(phone, required=False):
    """
    Validate contact phone numbers (Philippine mobile formats or general contact digits).
    """
    if not phone or not isinstance(phone, str) or not phone.strip():
        if required:
            return False, "Kailangan ilagay ang contact number."
        return True, ""

    cleaned = re.sub(r'[\s\-\(\)\.]', '', phone.strip())
    # Reject repeated identical digits (e.g. 0000000000, 1111111111)
    digits = re.sub(r'\D', '', cleaned)
    if digits and len(set(digits)) <= 1:
        return False, "Hindi wastong numero ng telepono. Huwag gumamit ng iisang paulit-ulit na numero tulad ng 0000000000."

    # Philippine formats: 09XXXXXXXXX, +639XXXXXXXXX, 9XXXXXXXXX, or 7-13 digits
    if not (re.match(r"^(\+639\d{9}|09\d{9}|9\d{9})$", cleaned) or (cleaned.isdigit() and 7 <= len(cleaned) <= 13)):
        return False, "Hindi wastong numero ng telepono. Gamitin ang format tulad ng 09XXXXXXXXX o +639XXXXXXXXX."

    return True, phone.strip()

def _validate_date_string(date_str, field_name="Petsa"):
    """
    Validate date strings in YYYY-MM-DD or ISO 8601 format.
    """
    if not date_str or not isinstance(date_str, str) or not date_str.strip():
        return True, None

    val = date_str.strip()
    for fmt in ('%Y-%m-%d', '%Y-%m-%d %H:%M:%S', '%Y-%m-%dT%H:%M:%S', '%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%S%z'):
        try:
            parsed = datetime.strptime(val.split('.')[0] if '.' in val and 'Z' not in val else val, fmt)
            return True, parsed
        except ValueError:
            pass

    try:
        parsed = datetime.fromisoformat(val.replace('Z', '+00:00'))
        return True, parsed
    except Exception:
        return False, f"Hindi wastong format ng {field_name} ('{date_str}'). Gamitin ang YYYY-MM-DD o ISO format."

# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────
def _hash_password(pw):
    return hashlib.sha256(pw.encode()).hexdigest()

def _get_or_init_queue():
    q = Queue.query.first()
    if not q:
        q = Queue(current_queue_no=0, now_serving=0)
        db.session.add(q)
        db.session.commit()
    return q

def _get_queue_data():
    """Build unified queue payload including active orders and today's completed orders."""
    queue = _get_or_init_queue()
    now = datetime.now(timezone.utc)
    # Philippines local day boundary (UTC+8)
    ph_offset = timedelta(hours=8)
    now_ph = now + ph_offset
    today_start_ph = now_ph.replace(hour=0, minute=0, second=0, microsecond=0)
    today_start_utc = (today_start_ph - ph_offset).replace(tzinfo=None)

    # Active orders (pending, accepted, preparing, ready_pickup, ready_delivery, out_for_delivery) - newest first so incoming orders display immediately
    active_orders = Order.query.filter(
        Order.status.notin_(['completed', 'delivered', 'cancelled'])
    ).order_by(Order.created_at.desc(), Order.id.desc()).all()

    # Completed and delivered orders from today (using actual order creation timestamp in Asia/Manila)
    completed_today = Order.query.filter(
        Order.status.in_(['completed', 'delivered']),
        Order.created_at >= today_start_utc
    ).order_by(Order.created_at.desc(), Order.id.desc()).all()

    # Also include recent completed orders for historical viewing in 'Completed' tab
    past_completed = Order.query.filter(
        Order.status.in_(['completed', 'delivered']),
        Order.created_at < today_start_utc
    ).order_by(Order.created_at.desc(), Order.id.desc()).limit(30).all()

    # Include recent cancelled orders for display in 'Cancelled' tab and status tracking
    cancelled_orders = Order.query.filter(
        Order.status == 'cancelled'
    ).order_by(Order.created_at.desc(), Order.id.desc()).limit(50).all()

    # Merge: active orders first, then completed today, then past completed, then cancelled
    seen_ids = set()
    all_orders = []
    for o in active_orders:
        if o.id not in seen_ids:
            all_orders.append(o)
            seen_ids.add(o.id)
    for o in completed_today:
        if o.id not in seen_ids:
            all_orders.append(o)
            seen_ids.add(o.id)
    for o in past_completed:
        if o.id not in seen_ids:
            all_orders.append(o)
            seen_ids.add(o.id)
    for o in cancelled_orders:
        if o.id not in seen_ids:
            all_orders.append(o)
            seen_ids.add(o.id)

    counts = {
        'all': len(active_orders),
        'pending': sum(1 for o in active_orders if o.status == 'pending'),
        'preparing': sum(1 for o in active_orders if o.status in ('accepted', 'preparing')),
        'ready': sum(1 for o in active_orders if o.status in ('ready_pickup', 'ready_delivery', 'out_for_delivery')),
        'completed': len(completed_today),
        'cancelled': len(cancelled_orders)
    }

    # Revenue strictly excludes cancelled orders
    today_sales_q = db.session.query(db.func.sum(Sale.total_amount)).join(
        Order, Sale.order_id == Order.id
    ).filter(
        Sale.timestamp >= today_start_utc,
        Order.status.notin_(['cancelled'])
    ).scalar()

    low_stock = Product.query.filter(
        Product.is_active == True,
        Product.stock <= (Product.max_stock * 0.20)
    ).count()

    has_active = len(active_orders) > 0
    now_serving_ticket = queue.now_serving if has_active else 0

    stats = {
        'queue': queue.to_dict(),
        'has_active': has_active,
        'now_serving': now_serving_ticket,
        'active_orders': len(active_orders),
        'pending_orders': counts['pending'],
        'today_completed': len(completed_today),
        'today_revenue': float(today_sales_q or 0.0),
        'low_stock_alerts': low_stock
    }

    q_dict = queue.to_dict()
    q_dict['has_active'] = has_active
    acct_payload = _get_payment_accounts_payload()
    all_products = Product.query.order_by(Product.id.asc()).all()

    return {
        'queue': q_dict,
        'orders': [o.to_dict() for o in all_orders],
        'products': [p.to_dict() for p in all_products],
        'counts': counts,
        'stats': stats,
        'payment_accounts': acct_payload['accounts'],
        'available_payment_accounts': acct_payload['available_accounts'],
        'total': len(all_orders),
        'timestamp': now.isoformat()
    }

def _emit_queue_update(socketio, new_order=None, updated_order=None):
    """Broadcast updated queue state and sales updates to all connected admin clients in real time."""
    try:
        payload = _get_queue_data()
        socketio.emit('queue_updated', payload)
        if new_order:
            order_dict = new_order.to_dict() if hasattr(new_order, 'to_dict') else new_order
            socketio.emit('new_order', order_dict)
            try:
                from firebase_client import sync_order_to_firestore
                sync_order_to_firestore(order_dict)
            except Exception as fe:
                print(f"[Firebase Sync Notice]: {fe}")
        elif updated_order:
            order_dict = updated_order.to_dict() if hasattr(updated_order, 'to_dict') else updated_order
            socketio.emit('order_updated', order_dict)
            try:
                from firebase_client import sync_order_to_firestore
                sync_order_to_firestore(order_dict)
            except Exception as fe:
                print(f"[Firebase Sync Notice]: {fe}")
        if 'queue' in payload:
            try:
                from firebase_client import sync_queue_to_firestore
                sync_queue_to_firestore(payload['queue'])
            except Exception as fe:
                print(f"[Firebase Sync Notice]: {fe}")
        socketio.emit('sales_updated', {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'stats': payload.get('stats', {})
        })
        socketio.emit('analytics_updated', {
            'timestamp': datetime.now(timezone.utc).isoformat()
        })
    except Exception as e:
        print(f"[SocketIO emit error] {e}")

def _emit_review_event(event_name, data):
    """Broadcast review events to connected clients in real time."""
    try:
        from app import socketio
        socketio.emit(event_name, data)
    except Exception as e:
        print(f"[SocketIO review emit error] {e}")

def _decrease_inventory(order):
    """Decrease product stock for each item in an order."""
    alerts = []
    updated_products = []
    for item in order.items:
        product = Product.query.get(item.product_id)
        if product:
            product.stock = max(0, product.stock - item.quantity)
            updated_products.append(product)
            if product.stock_status in ('critical', 'out_of_stock'):
                alerts.append({
                    'product': product.name,
                    'stock': product.stock,
                    'status': product.stock_status,
                    'message': f"⚠️ {product.name} stock is critically low: {product.stock} remaining!"
                })
            elif product.stock_status == 'warning':
                alerts.append({
                    'product': product.name,
                    'stock': product.stock,
                    'status': product.stock_status,
                    'message': f"🟡 {product.name} stock is low: {product.stock} remaining."
                })
            try:
                from firebase_client import sync_product_to_firestore
                sync_product_to_firestore(product.to_dict())
            except Exception:
                pass
    db.session.commit()
    try:
        from app import socketio
        all_prods = [p.to_dict() for p in Product.query.order_by(Product.id.asc()).all()]
        socketio.emit('inventory_updated', {'products': all_prods})
    except Exception:
        pass
    return alerts

def _restore_inventory(order):
    """Restore product stock when an order is cancelled."""
    try:
        for item in order.items:
            product = Product.query.get(item.product_id)
            if product:
                product.stock = min(product.max_stock, product.stock + item.quantity)
                try:
                    from firebase_client import sync_product_to_firestore
                    sync_product_to_firestore(product.to_dict())
                except Exception:
                    pass
        db.session.commit()
        try:
            from app import socketio
            all_prods = [p.to_dict() for p in Product.query.order_by(Product.id.asc()).all()]
            socketio.emit('inventory_updated', {'products': all_prods})
        except Exception:
            pass
    except Exception as e:
        db.session.rollback()
        print(f"[Restore Inventory Error]: {e}", flush=True)

def _record_sale(order):
    """Record or update a sale entry when order is completed or confirmed.
    Always preserves the order's original creation timestamp (order.created_at).
    Cancelled orders never have sales."""
    if not order:
        return
    if order.status == 'cancelled':
        Sale.query.filter_by(order_id=order.id).delete()
        try:
            db.session.commit()
        except Exception:
            db.session.rollback()
        return

    sale_ts = order.created_at or datetime.now(timezone.utc)
    existing = Sale.query.filter_by(order_id=order.id).first()
    if not existing:
        sale = Sale(
            order_id=order.id,
            total_amount=float(order.total_amount or 0.0),
            payment_method=order.payment_method or 'Cash',
            timestamp=sale_ts
        )
        db.session.add(sale)
    else:
        existing.total_amount = float(order.total_amount or 0.0)
        existing.payment_method = order.payment_method or 'Cash'
        if order.created_at:
            existing.timestamp = order.created_at
    try:
        db.session.commit()
    except Exception:
        db.session.rollback()


def _validate_delivery_coverage(order_type, delivery_address):
    """
    Ensure delivery orders are strictly restricted to Barangay Gatid, Santa Cruz, Laguna.
    Outside Gatid or outside Santa Cruz Laguna, delivery is not accepted (customer must use Store Pickup).
    """
    if str(order_type).lower() != 'delivery':
        return True, None
    if not delivery_address or not str(delivery_address).strip():
        return False, "Kailangan ng delivery address para sa delivery order."

    addr_lower = str(delivery_address).lower()
    # Accept Gatid or Batisan (sitio where Boss KEVS is located in Brgy. Gatid, Santa Cruz, Laguna)
    is_in_gatid = ('gatid' in addr_lower) or ('batisan' in addr_lower)
    if not is_in_gatid:
        return False, "Ang delivery ay para lamang sa Barangay Gatid, Santa Cruz, Laguna. Kapag wala sa Gatid, mangyaring piliin ang Store Pickup."

    return True, None


def _validate_addon_restrictions(items_data):
    """
    Enforce quantity-based add-on restrictions based on the total number of HotSpot Siomai pieces:
    | Add-on       | 1–10 Siomai pcs | 11+ Siomai pcs |
    | Calamansi    | Max 3 pcs       | Max 5 pcs      |
    | Soy Sauce    | Max 2 packs     | Max 3 packs    |
    | Chili Garlic | Max 2 packs     | Max 3 packs    |
    """
    if not items_data or not isinstance(items_data, list):
        return True, None

    total_siomai = 0
    addon_counts = {
        'calamansi': 0,
        'soy_sauce': 0,
        'chili_garlic': 0
    }

    for it in items_data:
        if not isinstance(it, dict):
            continue
        prod_id = it.get('product_id')
        if not prod_id:
            continue
        try:
            qty = int(it.get('quantity', 0))
        except (ValueError, TypeError):
            qty = 0
        if qty <= 0:
            continue

        prod = Product.query.get(prod_id)
        if not prod:
            continue

        p_name = (prod.name or '').lower()
        p_cat = (prod.category or '').lower()

        if 'siomai' in p_name or p_cat == 'siomai':
            total_siomai += qty
        elif 'calamansi' in p_name:
            addon_counts['calamansi'] += qty
        elif 'soy' in p_name:
            addon_counts['soy_sauce'] += qty
        elif 'chili' in p_name or 'chilli' in p_name:
            addon_counts['chili_garlic'] += qty

    if total_siomai <= 0:
        limits = {
            'calamansi': (0, 'pcs'),
            'soy_sauce': (0, 'packs'),
            'chili_garlic': (0, 'packs')
        }
    elif total_siomai <= 10:
        limits = {
            'calamansi': (3, 'pcs'),
            'soy_sauce': (2, 'packs'),
            'chili_garlic': (2, 'packs')
        }
    else:  # 11+
        limits = {
            'calamansi': (5, 'pcs'),
            'soy_sauce': (3, 'packs'),
            'chili_garlic': (3, 'packs')
        }

    display_names = {
        'calamansi': 'Calamansi',
        'soy_sauce': 'Soy Sauce',
        'chili_garlic': 'Chili Garlic'
    }

    errors = []
    for k, selected_qty in addon_counts.items():
        max_allowed, unit = limits[k]
        if selected_qty > max_allowed:
            d_name = display_names[k]
            if total_siomai == 0:
                errors.append(f"Kailangan ng kahit isang HotSpot Siomai para sa {d_name} (Max: 0 {unit}).")
            else:
                errors.append(
                    f"Ang dami ng {d_name} ({selected_qty} {unit}) ay lumagpas sa limitasyon "
                    f"para sa {total_siomai} pcs HotSpot Siomai (Max: {max_allowed} {unit})."
                )

    if errors:
        return False, " ".join(errors)

    return True, None


# ─────────────────────────────────────────────
# DELIVERY COVERAGE INFO
# ─────────────────────────────────────────────
@api.route('/delivery/coverage', methods=['GET'])
def get_delivery_coverage():
    """Return official store delivery coverage limits."""
    return jsonify({
        'status': 'active',
        'coverage_area': 'Barangay Gatid, Santa Cruz, Laguna',
        'hub_address': '070 Batisan, Gatid, Santa Cruz, Laguna',
        'allowed_barangay': 'Gatid',
        'municipality': 'Santa Cruz',
        'province': 'Laguna',
        'delivery_fee': 30.0,
        'message': 'Ang delivery ay para lamang sa Barangay Gatid, Santa Cruz, Laguna. Kapag wala sa Gatid, piliin ang Store Pickup.'
    }), 200


# ─────────────────────────────────────────────
# AUTH
# ─────────────────────────────────────────────
@api.route('/auth/login', methods=['POST'])
def auth_login():
    data = request.get_json() or {}
    username = str(data.get('username', '')).strip()
    password = str(data.get('password', '')).strip()

    if not username:
        return jsonify({'error': 'Username is required.'}), 400
    if len(username) < 3 or len(username) > 50:
        return jsonify({'error': 'Username must be between 3 and 50 characters.'}), 400
    if not password:
        return jsonify({'error': 'Password is required.'}), 400
    if len(password) < 4 or len(password) > 100:
        return jsonify({'error': 'Password must be at least 4 characters.'}), 400

    user = User.query.filter_by(username=username).first()
    if not user or user.password_hash != _hash_password(password):
        return jsonify({'error': 'Invalid username or password.'}), 401
    return jsonify({
        'message': 'Login successful',
        'user': user.to_dict(),
        'token': f"mock-jwt-{user.id}-{uuid.uuid4().hex[:8]}"
    }), 200

@api.route('/auth/me', methods=['GET'])
def auth_me():
    user = User.query.first()
    if not user:
        return jsonify({'error': 'No admin user found'}), 404
    return jsonify({'user': user.to_dict()}), 200


# ─────────────────────────────────────────────
# QUEUE
# ─────────────────────────────────────────────
@api.route('/queue', methods=['GET'])
def get_queue():
    payload = _get_queue_data()
    return jsonify(payload), 200

@api.route('/queue/all', methods=['GET'])
def get_all_orders():
    """Get all orders including completed ones for history view."""
    page = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 50, type=int)
    status_filter = request.args.get('status', '')
    query = Order.query.order_by(Order.created_at.desc())
    if status_filter:
        query = query.filter(Order.status == status_filter)
    orders = query.limit(per_page).offset((page - 1) * per_page).all()
    total = Order.query.count()
    return jsonify({'orders': [o.to_dict() for o in orders], 'total': total}), 200

@api.route('/queue/add', methods=['POST'])
def queue_add():
    """ESP32 button press or mobile app adds to queue."""
    from app import socketio
    data = request.get_json() or {}

    order_type = str(data.get('order_type', 'pickup')).strip().lower()
    if order_type not in ('pickup', 'delivery', 'dine_in', 'dine-in'):
        return jsonify({'error': 'Invalid order type. Must be pickup, delivery, or dine_in.'}), 400

    order_source = str(data.get('type', 'walk-in')).strip().lower()
    delivery_address = str(data.get('delivery_address', '')).strip()

    # Validate customer name
    raw_name = str(data.get('customer_name', '')).strip() or 'Walk-in Customer'
    is_valid_name, name_res = _validate_person_name(raw_name, "Pangalan ng kostumer", allow_default=True)
    if not is_valid_name:
        return jsonify({'error': name_res}), 400
    customer_name = name_res

    # Validate customer phone
    raw_phone = str(data.get('customer_phone', '')).strip()
    is_valid_phone, phone_res = _validate_phone_number(raw_phone, required=(order_type == 'delivery'))
    if not is_valid_phone:
        return jsonify({'error': phone_res}), 400
    customer_phone = phone_res

    # Validate delivery coverage (Barangay Gatid, Santa Cruz, Laguna only)
    is_valid_delivery, delivery_error = _validate_delivery_coverage(order_type, delivery_address)
    if not is_valid_delivery:
        return jsonify({'error': delivery_error}), 400

    # Build order items with validation
    items_data = data.get('items', [])

    is_valid_addons, addon_err = _validate_addon_restrictions(items_data)
    if not is_valid_addons:
        return jsonify({'error': addon_err}), 400

    total_amount = 0.0
    order_items_to_add = []

    for it in items_data:
        prod_id = it.get('product_id')
        if not prod_id:
            return jsonify({'error': 'Kailangan ng product_id para sa bawat aytem.'}), 400
        try:
            qty = int(it.get('quantity', 1))
        except (ValueError, TypeError):
            return jsonify({'error': 'Ang dami ng aytem ay dapat isang wastong numero.'}), 400
        if qty <= 0 or qty > 500:
            return jsonify({'error': 'Ang dami ng order ay dapat nasa pagitan ng 1 hanggang 500.'}), 400

        product = Product.query.get(prod_id)
        if not product:
            return jsonify({'error': f'Ang produkto (ID: {prod_id}) ay hindi matagpuan.'}), 400
        if not product.is_active:
            return jsonify({'error': f"Ang produktong '{product.name}' ay kasalukuyang hindi available (Inactive) at hindi maaaring i-order."}), 400
        if product.stock < qty:
            return jsonify({'error': f'Kulang ang stock para sa {product.name}. Kasalukuyang natitira: {product.stock} {product.unit}.'}), 400

        subtotal = product.price * qty
        total_amount += subtotal
        order_items_to_add.append(OrderItem(
            product_id=product.id,
            quantity=qty,
            unit_price=product.price,
            subtotal=subtotal
        ))

    if not items_data:
        try:
            total_amount = max(0.0, float(data.get('total', 0.0)))
        except (ValueError, TypeError):
            total_amount = 0.0

    payment_method = str(data.get('payment_method', 'Cash')).strip()
    requested_account_id = data.get('payment_account_id')
    ok_acct, selected_acct, acct_err = _resolve_online_account_for_new_order(payment_method, requested_account_id)
    if not ok_acct:
        return jsonify({
            'error': acct_err,
            'online_payment_unavailable': True,
            'available_accounts': _get_payment_accounts_payload()['available_accounts']
        }), 409

    queue = _get_or_init_queue()
    queue.current_queue_no += 1
    laptop_now_utc = datetime.now(timezone.utc)
    queue.last_updated = laptop_now_utc

    # Online payments must remain 'pending' until an authorized administrator confirms payment
    raw_pay_status = str(data.get('payment_status', 'pending')).strip().lower()
    if _is_online_payment_method(payment_method):
        payment_status = 'pending'
    else:
        payment_status = 'confirmed' if raw_pay_status in ('confirmed', 'paid') else 'pending'

    new_order = Order(
        queue_no=queue.current_queue_no,
        type=order_source,
        order_type=order_type,
        customer_name=customer_name,
        customer_phone=customer_phone,
        delivery_address=data.get('delivery_address', ''),
        status='pending',
        payment_status=payment_status,
        payment_method=payment_method,
        payment_account_id=selected_acct.account_id if selected_acct else None,
        payment_account_name=(
            data.get('payment_account_name')
            or f"{selected_acct.account_name} ({selected_acct.account_holder_name})"
        ) if selected_acct else None,
        payment_provider=(
            data.get('payment_provider') or selected_acct.provider
        ) if selected_acct else ('Cash' if not _is_online_payment_method(payment_method) else payment_method),
        total_amount=total_amount,
        notes=data.get('notes', ''),
        is_offline=data.get('is_offline', False),
        created_at=laptop_now_utc,
        updated_at=laptop_now_utc,
    )
    db.session.add(new_order)
    db.session.flush()  # get ID
    for item in order_items_to_add:
        item.order_id = new_order.id
        db.session.add(item)

    db.session.commit()
    _decrease_inventory(new_order)
    print(f"[NEW WALK-IN ORDER] Ticket #{new_order.queue_no} | {new_order.customer_name} | PHP {new_order.total_amount:.2f} ({new_order.payment_method})", flush=True)
    _emit_queue_update(socketio, new_order)

    return jsonify({
        'message': 'Order added to queue',
        'order': new_order.to_dict(),
        'queue': queue.to_dict()
    }), 201

@api.route('/queue/remove', methods=['POST'])
def queue_remove():
    """Mark order as completed and decrement now_serving."""
    from app import socketio
    data = request.get_json() or {}
    order_id = data.get('order_id')
    if not order_id:
        return jsonify({'error': 'order_id required'}), 400
    order = Order.query.get(order_id)
    if not order:
        return jsonify({'error': 'Order not found'}), 404

    order.status = 'completed'
    order.updated_at = datetime.now(timezone.utc)
    queue = _get_or_init_queue()
    if queue.now_serving < queue.current_queue_no:
        queue.now_serving += 1
    _record_sale(order)
    db.session.commit()
    print(f"✅ [ORDER COMPLETED] Order #{order.id} | Ticket #{order.queue_no} served & recorded in sales!", flush=True)
    _emit_queue_update(socketio, updated_order=order)
    return jsonify({'message': 'Order completed and queue updated', 'order': order.to_dict()}), 200

@api.route('/queue/call-next', methods=['POST'])
def queue_call_next():
    """Advance to next order in queue, mark preparing, and notify clients."""
    from app import socketio
    queue = _get_or_init_queue()

    # Find the next order waiting in line
    next_order = Order.query.filter(
        Order.queue_no > queue.now_serving,
        Order.status.notin_(['completed', 'delivered', 'cancelled'])
    ).order_by(Order.queue_no.asc()).first()

    if not next_order:
        next_order = Order.query.filter(
            Order.status.in_(['pending', 'accepted', 'preparing'])
        ).order_by(Order.queue_no.asc()).first()

    if next_order:
        queue.now_serving = next_order.queue_no
        if next_order.status == 'pending':
            next_order.status = 'preparing'
            next_order.updated_at = datetime.now(timezone.utc)
            _decrease_inventory(next_order)
    else:
        if queue.now_serving < queue.current_queue_no:
            queue.now_serving += 1

    queue.last_updated = datetime.now(timezone.utc)
    db.session.commit()
    print(f"📢 [CALL NEXT] Now Serving Ticket #{queue.now_serving}", flush=True)
    _emit_queue_update(socketio)

    return jsonify({
        'message': f'Now calling ticket #{queue.now_serving}',
        'now_serving': queue.now_serving,
        'queue': queue.to_dict(),
        'order': next_order.to_dict() if next_order else None
    }), 200

@api.route('/queue/display', methods=['GET'])
def queue_display():
    """Endpoint for ESP32 dual-OLED + dual-buzzer hardware to poll current queue & kitchen state."""
    queue = _get_or_init_queue()
    active_orders = Order.query.filter(
        Order.status.notin_(['completed', 'delivered', 'cancelled'])
    ).order_by(Order.created_at.desc(), Order.id.desc()).all()

    now_serving_order = Order.query.filter(
        Order.queue_no == queue.now_serving,
        Order.status.notin_(['completed', 'delivered', 'cancelled'])
    ).first()

    pending_count = sum(1 for o in active_orders if o.status == 'pending')
    preparing_count = sum(1 for o in active_orders if o.status in ('accepted', 'preparing'))
    ready_count = sum(1 for o in active_orders if o.status in ('ready_pickup', 'ready_delivery', 'out_for_delivery'))

    low_stock_products = Product.query.filter(
        Product.is_active == True,
        Product.stock <= (Product.max_stock * 0.20)
    ).all()

    # Track latest issued order ticket even when completed
    latest_order = Order.query.order_by(Order.id.desc()).first()
    completed_count = Order.query.filter(Order.status.in_(['completed', 'delivered'])).count()

    return jsonify({
        'now_serving': queue.now_serving,
        'next_queue': queue.current_queue_no,
        'now_serving_status': now_serving_order.status if now_serving_order else ('idle' if not active_orders else 'serving'),
        'now_serving_customer': (now_serving_order.customer_name or 'Guest')[:14] if now_serving_order else '-',
        'active_count': len(active_orders),
        'pending_count': pending_count,
        'preparing_count': preparing_count,
        'ready_count': ready_count,
        'completed_count': completed_count,
        'latest_ticket': latest_order.queue_no if latest_order else 0,
        'latest_customer': (latest_order.customer_name or 'Guest')[:12] if latest_order else '-',
        'latest_total': float(latest_order.total_amount) if latest_order else 0.0,
        'low_stock_count': len(low_stock_products),
        'low_stock_item': low_stock_products[0].name[:14] if low_stock_products else ''
    }), 200

@api.route('/queue/reset', methods=['POST'])
def queue_reset():
    from app import socketio
    queue = _get_or_init_queue()
    queue.current_queue_no = 0
    queue.now_serving = 0
    queue.last_updated = datetime.now(timezone.utc)
    db.session.commit()
    _emit_queue_update(socketio)
    return jsonify({'message': 'Queue reset successfully', 'queue': queue.to_dict()}), 200

@api.route('/orders/clear', methods=['POST'])
def clear_all_orders():
    """Clear all orders, items, and sales from database, resetting queue to 0."""
    from app import socketio
    try:
        Sale.query.delete()
        OrderItem.query.delete()
        Order.query.delete()
        queue = _get_or_init_queue()
        queue.current_queue_no = 0
        queue.now_serving = 0
        queue.last_updated = datetime.now(timezone.utc)
        db.session.commit()
        _emit_queue_update(socketio)
        return jsonify({
            'message': 'All orders and sales database records cleared successfully.',
            'queue': queue.to_dict()
        }), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


# ─────────────────────────────────────────────
# PRODUCTS / INVENTORY
# ─────────────────────────────────────────────
@api.route('/products', methods=['GET'])
def get_products():
    include_inactive = request.args.get('all', 'false').lower() == 'true'
    query = Product.query if include_inactive else Product.query.filter_by(is_active=True)
    products = query.all()

    def _cat_priority(p):
        c = (p.category or '').lower()
        if 'siomai' in c:
            return 1
        if 'drink' in c or 'beverage' in c:
            return 2
        if 'add' in c or 'sauce' in c or 'condiment' in c:
            return 3
        return 4

    products.sort(key=lambda p: (_cat_priority(p), p.id))
    return jsonify({'products': [p.to_dict() for p in products]}), 200

@api.route('/products', methods=['POST'])
def create_product():
    data = request.get_json() or {}
    raw_name = data.get('name')
    is_valid_name, name_res = _validate_product_name(raw_name)
    if not is_valid_name:
        return jsonify({'error': name_res}), 400
    name = name_res

    try:
        price = float(data.get('price', 0))
    except (ValueError, TypeError):
        return jsonify({'error': 'Ang presyo ay dapat isang wastong numero.'}), 400
    if price < 0.0 or price > 100000.0:
        return jsonify({'error': 'Ang presyo ay dapat nasa pagitan ng ₱0.00 hanggang ₱100,000.00.'}), 400

    try:
        stock = int(data.get('stock', 50))
    except (ValueError, TypeError):
        return jsonify({'error': 'Ang stock ay dapat isang wastong buong numero (integer).'}), 400
    if stock < 0 or stock > 50000:
        return jsonify({'error': 'Ang stock ay dapat nasa pagitan ng 0 hanggang 50,000.'}), 400

    try:
        max_stock = int(data.get('max_stock', max(100, stock)))
    except (ValueError, TypeError):
        return jsonify({'error': 'Ang maximum stock ay dapat isang wastong integer.'}), 400
    if max_stock < 1 or max_stock > 50000:
        return jsonify({'error': 'Ang maximum stock ay dapat nasa pagitan ng 1 hanggang 50,000.'}), 400

    category = str(data.get('category', 'Siomai')).strip()
    if len(category) > 50:
        return jsonify({'error': 'Ang kategorya ay hindi maaaring lumampas sa 50 characters.'}), 400

    unit = str(data.get('unit', 'servings')).strip()
    if len(unit) > 30:
        return jsonify({'error': 'Ang unit ay hindi maaaring lumampas sa 30 characters.'}), 400

    is_active = data.get('is_active', True)
    if isinstance(is_active, str):
        is_active = is_active.lower() in ('true', '1', 'yes')
    else:
        is_active = bool(is_active)

    product = Product(
        name=name,
        category=category,
        price=price,
        stock=stock,
        max_stock=max_stock,
        unit=unit,
        description=str(data.get('description', '')).strip()[:500],
        image_url=str(data.get('image_url', '')).strip()[:300],
        is_active=is_active
    )
    db.session.add(product)
    db.session.commit()
    try:
        from firebase_client import sync_product_to_firestore
        sync_product_to_firestore(product.to_dict())
    except Exception as fe:
        print(f"[Firebase Product Sync]: {fe}")
    try:
        from app import socketio
        socketio.emit('inventory_updated', product.to_dict())
    except Exception:
        pass
    return jsonify({'message': 'Product created', 'product': product.to_dict()}), 201

@api.route('/products/<int:product_id>', methods=['PUT'])
def update_product(product_id):
    is_admin, deny_resp = _require_admin()
    if not is_admin:
        return deny_resp

    product = Product.query.get_or_404(product_id)
    data = request.get_json() or {}

    prev_state = {
        'name': product.name,
        'price': product.price,
        'stock': product.stock,
        'max_stock': product.max_stock,
        'category': product.category,
        'unit': product.unit,
        'description': product.description,
        'image_url': product.image_url,
        'is_active': product.is_active,
    }

    if 'name' in data:
        is_valid_name, name_res = _validate_product_name(data['name'])
        if not is_valid_name:
            return jsonify({'error': name_res}), 400
        product.name = name_res

    if 'price' in data:
        try:
            p = float(data['price'])
        except (ValueError, TypeError):
            return jsonify({'error': 'Ang presyo ay dapat isang wastong numero.'}), 400
        if p < 0.0 or p > 100000.0:
            return jsonify({'error': 'Ang presyo ay dapat nasa pagitan ng ₱0.00 hanggang ₱100,000.00.'}), 400
        product.price = p

    if 'stock' in data:
        try:
            s = int(data['stock'])
        except (ValueError, TypeError):
            return jsonify({'error': 'Ang stock ay dapat isang integer.'}), 400
        if s < 0 or s > 50000:
            return jsonify({'error': 'Ang stock ay dapat nasa pagitan ng 0 hanggang 50,000.'}), 400
        product.stock = s

    if 'max_stock' in data:
        try:
            ms = int(data['max_stock'])
        except (ValueError, TypeError):
            return jsonify({'error': 'Ang maximum stock ay dapat isang integer.'}), 400
        if ms < 1 or ms > 50000:
            return jsonify({'error': 'Ang maximum stock ay dapat nasa pagitan ng 1 hanggang 50,000.'}), 400
        product.max_stock = ms

    if 'category' in data:
        c = str(data['category']).strip()
        if len(c) > 50:
            return jsonify({'error': 'Ang kategorya ay hindi maaaring lumampas sa 50 characters.'}), 400
        product.category = c

    if 'unit' in data:
        u = str(data['unit']).strip()
        if len(u) > 30:
            return jsonify({'error': 'Ang unit ay hindi maaaring lumampas sa 30 characters.'}), 400
        product.unit = u

    if 'description' in data:
        product.description = str(data['description']).strip()[:500]

    if 'image_url' in data:
        product.image_url = str(data['image_url']).strip()[:300]

    if 'is_active' in data:
        val = data['is_active']
        if isinstance(val, str):
            product.is_active = val.lower() in ('true', '1', 'yes', 'active')
        else:
            product.is_active = bool(val)
    elif 'status' in data:
        st_val = str(data['status']).strip().lower()
        if st_val in ('active', 'enabled', 'true'):
            product.is_active = True
        elif st_val in ('inactive', 'disabled', 'false'):
            product.is_active = False

    db.session.commit()

    firebase_synced = False
    firebase_err = None
    try:
        from firebase_client import sync_product_to_firestore
        firebase_synced = bool(sync_product_to_firestore(product.to_dict(), wait=True))
    except Exception as fe:
        firebase_err = str(fe)
        print(f"[Firebase Product Sync]: {fe}")

    if not firebase_synced:
        for k, v in prev_state.items():
            setattr(product, k, v)
        db.session.commit()
        return jsonify({
            'error': firebase_err or 'Failed to update product status in Firebase Firestore.',
            'firebase_synced': False,
            'product': product.to_dict()
        }), 500

    try:
        from app import socketio
        socketio.emit('inventory_updated', product.to_dict())
        _emit_queue_update(socketio)
    except Exception:
        pass
    return jsonify({
        'message': 'Product updated',
        'firebase_synced': True,
        'product': product.to_dict()
    }), 200

@api.route('/products/<int:product_id>', methods=['DELETE'])
def delete_product(product_id):
    is_admin, deny_resp = _require_admin()
    if not is_admin:
        return deny_resp

    product = Product.query.get_or_404(product_id)
    prev_active = bool(product.is_active)
    product.is_active = False
    db.session.commit()

    firebase_synced = False
    firebase_err = None
    try:
        from firebase_client import sync_product_to_firestore
        firebase_synced = bool(sync_product_to_firestore(product.to_dict(), wait=True))
    except Exception as fe:
        firebase_err = str(fe)
        print(f"[Firebase Product Sync]: {fe}")

    if not firebase_synced:
        product.is_active = prev_active
        db.session.commit()
        return jsonify({
            'error': firebase_err or 'Failed to update product status in Firebase Firestore.',
            'firebase_synced': False,
            'product': product.to_dict()
        }), 500

    try:
        from app import socketio
        socketio.emit('inventory_updated', product.to_dict())
        _emit_queue_update(socketio)
    except Exception:
        pass
    return jsonify({
        'message': 'Product deactivated',
        'firebase_synced': True,
        'product': product.to_dict()
    }), 200

@api.route('/inventory/<int:product_id>', methods=['PUT'])
def update_stock(product_id):
    product = Product.query.get_or_404(product_id)
    data = request.get_json() or {}

    if 'stock' in data:
        try:
            s = int(data['stock'])
        except (ValueError, TypeError):
            return jsonify({'error': 'Ang stock ay dapat isang integer.'}), 400
        if s < 0 or s > 50000:
            return jsonify({'error': 'Ang stock ay dapat nasa pagitan ng 0 hanggang 50,000.'}), 400
        product.stock = s

    if 'add_stock' in data:
        try:
            a = int(data['add_stock'])
        except (ValueError, TypeError):
            return jsonify({'error': 'Ang idadagdag na stock ay dapat isang integer.'}), 400
        if a < -50000 or a > 50000:
            return jsonify({'error': 'Hindi wastong dami ng stock adjustment.'}), 400
        product.stock = max(0, product.stock + a)

    if 'adjustment' in data:
        try:
            adj = int(data['adjustment'])
        except (ValueError, TypeError):
            return jsonify({'error': 'Ang adjustment ay dapat isang integer.'}), 400
        if adj < -50000 or adj > 50000:
            return jsonify({'error': 'Hindi wastong dami ng stock adjustment.'}), 400
        product.stock = max(0, product.stock + adj)

    if 'max_stock' in data:
        try:
            ms = int(data['max_stock'])
        except (ValueError, TypeError):
            return jsonify({'error': 'Ang maximum stock ay dapat isang integer.'}), 400
        if ms < 1 or ms > 50000:
            return jsonify({'error': 'Ang maximum stock ay dapat nasa pagitan ng 1 hanggang 50,000.'}), 400
        product.max_stock = ms

    db.session.commit()
    try:
        from firebase_client import sync_product_to_firestore
        sync_product_to_firestore(product.to_dict())
    except Exception as fe:
        print(f"[Firebase Product Sync]: {fe}")
    try:
        from app import socketio
        socketio.emit('inventory_updated', product.to_dict())
    except Exception:
        pass
    return jsonify({'message': 'Stock updated', 'product': product.to_dict()}), 200


# ─────────────────────────────────────────────
# ORDERS
# ─────────────────────────────────────────────
@api.route('/orders', methods=['GET'])
def get_orders():
    status = request.args.get('status')
    limit = request.args.get('limit', default=500, type=int)
    if limit is not None and (limit < 1 or limit > 2000):
        return jsonify({'error': 'Limit must be between 1 and 2000'}), 400

    start_date_str = request.args.get('start_date')
    end_date_str = request.args.get('end_date')

    q = Order.query.order_by(Order.created_at.desc())
    if status:
        if status == 'completed':
            q = q.filter(Order.status.in_(['completed', 'delivered']))
        elif status == 'active':
            q = q.filter(Order.status.notin_(['completed', 'delivered', 'cancelled']))
        else:
            q = q.filter(Order.status == status)

    if start_date_str:
        is_valid_start, start_dt = _validate_date_string(start_date_str, "start_date")
        if not is_valid_start:
            return jsonify({'error': start_dt}), 400
        q = q.filter(Order.created_at >= start_dt)

    if end_date_str:
        is_valid_end, end_dt = _validate_date_string(end_date_str, "end_date")
        if not is_valid_end:
            return jsonify({'error': end_dt}), 400
        q = q.filter(Order.created_at <= end_dt)

    orders = q.limit(limit).all()
    return jsonify({'orders': [o.to_dict() for o in orders]}), 200

@api.route('/orders', methods=['POST'])
def create_order():
    """Mobile app places order."""
    try:
        from app import socketio
        data = request.get_json() or {}
        order_type = str(data.get('order_type', 'pickup')).strip().lower()
        if order_type not in ('pickup', 'delivery', 'dine_in', 'dine-in'):
            return jsonify({'error': 'Invalid order type. Must be pickup, delivery, or dine_in.'}), 400

        delivery_address = str(data.get('delivery_address', '')).strip()

        # Validate delivery coverage (Barangay Gatid, Santa Cruz, Laguna only)
        is_valid_delivery, delivery_error = _validate_delivery_coverage(order_type, delivery_address)
        if not is_valid_delivery:
            return jsonify({'error': delivery_error}), 400

        # Validate customer name
        raw_name = str(data.get('customer_name', '')).strip() or 'Online Customer'
        is_valid_name, name_res = _validate_person_name(raw_name, "Pangalan ng kostumer", allow_default=True)
        if not is_valid_name:
            return jsonify({'error': name_res}), 400
        customer_name = name_res

        # Validate customer phone
        raw_phone = str(data.get('customer_phone', '')).strip()
        is_valid_phone, phone_res = _validate_phone_number(raw_phone, required=(order_type == 'delivery'))
        if not is_valid_phone:
            return jsonify({'error': phone_res}), 400
        customer_phone = phone_res

        items_data = data.get('items', [])
        if not items_data:
            return jsonify({'error': 'Kailangan ng kahit isang aytem para sa order.'}), 400

        is_valid_addons, addon_err = _validate_addon_restrictions(items_data)
        if not is_valid_addons:
            return jsonify({'error': addon_err}), 400

        total_amount = 0.0
        order_items_to_add = []
        for it in items_data:
            prod_id = it.get('product_id')
            if not prod_id:
                return jsonify({'error': 'Kailangan ng product_id para sa bawat aytem.'}), 400
            try:
                qty = int(it.get('quantity', 1))
            except (ValueError, TypeError):
                return jsonify({'error': 'Ang dami ng aytem ay dapat isang wastong numero.'}), 400
            if qty <= 0 or qty > 500:
                return jsonify({'error': 'Ang dami ng order ay dapat nasa pagitan ng 1 hanggang 500.'}), 400

            product = Product.query.get(prod_id)
            if not product:
                return jsonify({'error': f'Ang produkto (ID: {prod_id}) ay hindi matagpuan.'}), 400
            if not product.is_active:
                return jsonify({'error': f"Ang produktong '{product.name}' ay kasalukuyang hindi available (Inactive) at hindi maaaring i-order."}), 400
            if product.stock < qty:
                return jsonify({'error': f'Kulang ang stock para sa {product.name}. Kasalukuyang natitira: {product.stock} {product.unit}.'}), 400

            subtotal = product.price * qty
            total_amount += subtotal
            order_items_to_add.append(OrderItem(
                product_id=product.id,
                quantity=qty,
                unit_price=product.price,
                subtotal=subtotal
            ))

        # Add standard delivery fee for Gatid deliveries (₱30.00)
        if order_type == 'delivery':
            total_amount += 30.0

        payment_method = str(data.get('payment_method', 'GCash')).strip()
        requested_account_id = data.get('payment_account_id')
        ok_acct, selected_acct, acct_err = _resolve_online_account_for_new_order(payment_method, requested_account_id)
        if not ok_acct:
            return jsonify({
                'error': acct_err,
                'online_payment_unavailable': True,
                'available_accounts': _get_payment_accounts_payload()['available_accounts']
            }), 409

        queue = _get_or_init_queue()
        queue.current_queue_no += 1
        laptop_now_utc = datetime.now(timezone.utc)
        queue.last_updated = laptop_now_utc

        # Online orders always start as 'pending' payment until confirmed by an authorized administrator
        payment_status = 'pending'

        new_order = Order(
            queue_no=queue.current_queue_no,
            type='online',
            order_type=order_type,
            customer_name=customer_name,
            customer_phone=customer_phone,
            delivery_address=delivery_address if order_type == 'delivery' else '',
            status='pending',
            payment_status=payment_status,
            payment_method=payment_method,
            payment_account_id=selected_acct.account_id if selected_acct else None,
            payment_account_name=(
                data.get('payment_account_name')
                or f"{selected_acct.account_name} ({selected_acct.account_holder_name})"
            ) if selected_acct else None,
            payment_provider=(
                data.get('payment_provider') or selected_acct.provider
            ) if selected_acct else ('Cash' if not _is_online_payment_method(payment_method) else payment_method),
            total_amount=total_amount,
            notes=str(data.get('notes', '')).strip()[:500],
            created_at=laptop_now_utc,
            updated_at=laptop_now_utc,
        )
        db.session.add(new_order)
        db.session.flush()
        for item in order_items_to_add:
            item.order_id = new_order.id
            db.session.add(item)
        db.session.commit()
        _decrease_inventory(new_order)
        print(f"[NEW MOBILE ORDER] Ticket #{new_order.queue_no} | {new_order.customer_name} ({new_order.order_type}) | PHP {new_order.total_amount:.2f} ({new_order.payment_method})", flush=True)
        _emit_queue_update(socketio, new_order)
        return jsonify({'message': 'Order placed', 'order': new_order.to_dict(), 'queue': queue.to_dict()}), 201
    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(e)}), 500

def _find_order_by_ref(order_ref):
    ref_str = str(order_ref).strip()
    clean_id = ref_str[6:] if ref_str.startswith('order_') else ref_str
    if clean_id.isdigit():
        ord_obj = Order.query.get(int(clean_id))
        if ord_obj:
            return ord_obj
    # Fallback: check by notes containing doc_id or customer phone
    ord_obj = Order.query.filter(
        (Order.notes.ilike(f"%{ref_str}%")) | (Order.customer_phone == ref_str)
    ).order_by(Order.id.desc()).first()
    return ord_obj

@api.route('/orders/<int:order_id>', methods=['GET'])
def get_order(order_id):
    order = Order.query.get_or_404(order_id)
    return jsonify({'order': order.to_dict()}), 200

@api.route('/orders/<path:order_ref>', methods=['GET'])
def get_order_by_ref(order_ref):
    order = _find_order_by_ref(order_ref)
    if not order:
        return jsonify({'error': 'Order not found'}), 404
    return jsonify({'order': order.to_dict()}), 200

@api.route('/orders/<int:order_id>', methods=['PUT'])
def update_order(order_id):
    return _process_update_order(order_id)

@api.route('/orders/<path:order_ref>', methods=['PUT'])
def update_order_by_ref(order_ref):
    return _process_update_order(order_ref)

def _process_update_order(order_identifier):
    """Update order status with proper workflow transitions and robust reference handling."""
    from app import socketio
    order = _find_order_by_ref(order_identifier)
    if not order:
        return jsonify({'error': f'Order not found for reference: {order_identifier}'}), 404

    data = request.get_json() or {}
    new_status = data.get('status')
    stock_alerts = []
    released_account = None

    valid_transitions = {
        'pending':          ['accepted', 'preparing', 'ready_pickup', 'completed', 'cancelled'],
        'accepted':         ['preparing', 'ready_pickup', 'completed', 'cancelled'],
        'preparing':        ['ready_pickup', 'ready_delivery', 'completed', 'cancelled'],
        'ready_pickup':     ['completed', 'cancelled'],
        'ready_delivery':   ['out_for_delivery', 'completed', 'cancelled'],
        'out_for_delivery': ['delivered', 'completed', 'cancelled'],
        'delivered':        [],
        'completed':        [],
        'cancelled':        []
    }

    if new_status:
        old_status = order.status

        # Idempotent return if already cancelled
        if new_status == 'cancelled' and old_status == 'cancelled':
            from firebase_client import sync_order_to_firestore
            sync_order_to_firestore(order.to_dict(), wait=False)
            return jsonify({
                'message': 'Order is already cancelled',
                'order': order.to_dict(),
                'firestore_synced': True,
                'stock_alerts': []
            }), 200

        order.status = new_status
        order.updated_at = datetime.now(timezone.utc)

        # Restore inventory, release confirmed online account capacity (if any), and delete sale if order is cancelled
        if new_status == 'cancelled':
            if old_status != 'cancelled':
                _restore_inventory(order)
            if str(order.payment_status or '').lower() in ('confirmed', 'paid') and order.payment_confirmed_at is not None and order.payment_account_id:
                acct = _find_payment_account(order.payment_account_id)
                if acct:
                    acct.confirmed_count = max(0, int(acct.confirmed_count or 0) - 1)
                    acct.confirmed_amount = max(0.0, round(float(acct.confirmed_amount or 0.0) - float(order.total_amount or 0.0), 2))
                    acct.updated_at = datetime.now(timezone.utc)
                    released_account = acct
                order.payment_confirmed_at = None
            Sale.query.filter_by(order_id=order.id).delete()

        # Mark sale & advance queue counter when order is fulfilled (never auto-change payment_status)
        if new_status in ('completed', 'delivered'):
            queue = _get_or_init_queue()
            if queue.now_serving < order.queue_no:
                queue.now_serving = order.queue_no
            elif queue.now_serving < queue.current_queue_no:
                queue.now_serving += 1
            _record_sale(order)

    # Also update other fields when explicitly provided
    if 'payment_status' in data and data['payment_status']:
        incoming_pay = str(data['payment_status']).strip().lower()
        normalized_pay = 'confirmed' if incoming_pay in ('confirmed', 'paid') else 'pending'
        # Prevent stale requests from reverting a confirmed payment back to pending
        if str(order.payment_status or '').lower() in ('confirmed', 'paid') and normalized_pay != 'confirmed':
            pass
        elif normalized_pay == 'confirmed' and str(order.payment_status or '').lower() not in ('confirmed', 'paid'):
            # Payment confirmation must go through _process_confirm_payment to enforce account limits & permissions
            pass
        else:
            order.payment_status = normalized_pay
            order.updated_at = datetime.now(timezone.utc)

    for field in ['payment_method', 'payment_reference', 'notes']:
        if field in data and data[field] is not None:
            setattr(order, field, data[field])

    # Record sale strictly for non-cancelled completed/confirmed orders
    if order.status not in ('cancelled',) and (order.status in ('completed', 'delivered') or order.payment_status == 'confirmed'):
        _record_sale(order)
    elif order.status == 'cancelled':
        Sale.query.filter_by(order_id=order.id).delete()

    db.session.commit()
    print(f"🔄 [ORDER UPDATE] Order #{order.id} (Ticket #{order.queue_no}) -> Status: {order.status} | Payment: {order.payment_status}", flush=True)
    if released_account is not None:
        try:
            from firebase_client import sync_payment_account_to_firestore
            sync_payment_account_to_firestore(released_account.to_dict(), wait=True)
        except Exception as fe:
            print(f"[Firebase Account Release Sync Notice]: {fe}")
        _emit_payment_accounts_update(socketio)
    _emit_queue_update(socketio, updated_order=order)

    # Synchronously commit to Firestore before returning HTTP success
    firestore_synced = False
    try:
        from firebase_client import sync_order_to_firestore
        firestore_synced = sync_order_to_firestore(order.to_dict(), wait=True)
    except Exception as fe:
        print(f"[Firebase Sync Notice]: {fe}")

    return jsonify({
        'message': f'Order updated to {order.status}',
        'order': order.to_dict(),
        'firestore_synced': firestore_synced,
        'stock_alerts': stock_alerts
    }), 200


# ─────────────────────────────────────────────
# DYNAMIC ONLINE PAYMENT ACCOUNT MANAGEMENT
# ─────────────────────────────────────────────
@api.route('/payment-accounts', methods=['GET'])
def get_payment_accounts():
    """Return all configured payment accounts and currently available accounts."""
    payload = _get_payment_accounts_payload()
    return jsonify(payload), 200


@api.route('/payment-accounts', methods=['POST'])
def create_payment_account():
    """Admin registers a new online receiving payment account."""
    is_admin, deny_resp = _require_admin()
    if not is_admin:
        return deny_resp

    from app import socketio
    data = request.get_json() or {}
    account_name = str(data.get('account_name', '')).strip()
    provider = str(data.get('provider', 'GCash / InstaPay')).strip() or 'GCash / InstaPay'
    account_holder_name = str(data.get('account_holder_name', '')).strip()
    mobile_number = str(data.get('mobile_number', '')).strip()
    qr_raw = str(data.get('qr_image_url', '')).strip()
    limit_type = str(data.get('limit_type', 'count')).strip().lower()
    if limit_type not in ('count', 'amount'):
        limit_type = 'count'

    if not account_name:
        return jsonify({'error': 'Account name is required.'}), 400
    if not account_holder_name:
        return jsonify({'error': 'Account holder name is required.'}), 400
    if not mobile_number:
        return jsonify({'error': 'Registered mobile number is required.'}), 400

    try:
        transaction_limit = float(data.get('transaction_limit', 5))
    except (ValueError, TypeError):
        return jsonify({'error': 'Transaction limit must be a valid positive number.'}), 400
    if transaction_limit <= 0 or transaction_limit > 10000000:
        return jsonify({'error': 'Transaction limit must be greater than 0.'}), 400

    try:
        priority = int(data.get('priority') or (PaymentAccount.query.count() + 1))
    except (ValueError, TypeError):
        priority = PaymentAccount.query.count() + 1

    raw_is_active = data.get('is_active', True)
    is_active = raw_is_active.lower() in ('true', '1', 'yes') if isinstance(raw_is_active, str) else bool(raw_is_active)

    requested_id = str(data.get('account_id', '')).strip()
    if requested_id:
        safe_id = re.sub(r'[^a-zA-Z0-9_-]', '_', requested_id)
    else:
        slug = re.sub(r'[^a-z0-9]+', '_', account_name.lower()).strip('_')[:20] or 'gcash'
        safe_id = f"acct_{slug}_{uuid.uuid4().hex[:6]}"

    if PaymentAccount.query.filter_by(account_id=safe_id).first():
        safe_id = f"{safe_id}_{uuid.uuid4().hex[:4]}"

    qr_image_url = _save_qr_image_if_base64(qr_raw, safe_id) if qr_raw else '/images/gcash_instapay_qr_1.jpg'
    now_utc = datetime.now(timezone.utc)

    acct = PaymentAccount(
        account_id=safe_id,
        account_name=account_name,
        provider=provider,
        account_holder_name=account_holder_name,
        mobile_number=mobile_number,
        qr_image_url=qr_image_url,
        limit_type=limit_type,
        transaction_limit=transaction_limit,
        confirmed_count=0,
        confirmed_amount=0.0,
        is_active=is_active,
        priority=priority,
        created_at=now_utc,
        updated_at=now_utc
    )
    db.session.add(acct)
    db.session.commit()

    try:
        from firebase_client import sync_payment_account_to_firestore
        sync_payment_account_to_firestore(acct.to_dict(), wait=True)
    except Exception as fe:
        print(f"[Firebase Payment Account Sync Notice]: {fe}")

    _emit_payment_accounts_update(socketio)
    _emit_queue_update(socketio)
    return jsonify({
        'message': 'Payment account created successfully',
        'account': acct.to_dict(),
        **_get_payment_accounts_payload()
    }), 201


@api.route('/payment-accounts/<path:account_ref>', methods=['PUT'])
def update_payment_account(account_ref):
    """Admin edits an existing receiving payment account, its limit, QR code, or usage reset."""
    is_admin, deny_resp = _require_admin()
    if not is_admin:
        return deny_resp

    from app import socketio
    acct = _find_payment_account(account_ref)
    if not acct:
        return jsonify({'error': 'Payment account not found.'}), 404

    data = request.get_json() or {}
    if 'account_name' in data and str(data['account_name']).strip():
        acct.account_name = str(data['account_name']).strip()
    if 'provider' in data and str(data['provider']).strip():
        acct.provider = str(data['provider']).strip()
    if 'account_holder_name' in data and str(data['account_holder_name']).strip():
        acct.account_holder_name = str(data['account_holder_name']).strip()
    if 'mobile_number' in data and str(data['mobile_number']).strip():
        acct.mobile_number = str(data['mobile_number']).strip()
    if 'qr_image_url' in data and str(data['qr_image_url']).strip():
        acct.qr_image_url = _save_qr_image_if_base64(str(data['qr_image_url']).strip(), acct.account_id)
    if 'limit_type' in data and str(data['limit_type']).strip().lower() in ('count', 'amount'):
        acct.limit_type = str(data['limit_type']).strip().lower()
    if 'transaction_limit' in data:
        try:
            t_lim = float(data['transaction_limit'])
        except (ValueError, TypeError):
            return jsonify({'error': 'Transaction limit must be a valid number.'}), 400
        if t_lim <= 0 or t_lim > 10000000:
            return jsonify({'error': 'Transaction limit must be greater than 0.'}), 400
        acct.transaction_limit = t_lim
    if 'priority' in data:
        try:
            acct.priority = int(data['priority'])
        except (ValueError, TypeError):
            pass
    if 'is_active' in data:
        val = data['is_active']
        acct.is_active = val.lower() in ('true', '1', 'yes') if isinstance(val, str) else bool(val)
    if data.get('reset_usage') is True:
        acct.confirmed_count = 0
        acct.confirmed_amount = 0.0
    if 'confirmed_count' in data and data['confirmed_count'] is not None:
        try:
            acct.confirmed_count = max(0, int(data['confirmed_count']))
        except (ValueError, TypeError):
            pass
    if 'confirmed_amount' in data and data['confirmed_amount'] is not None:
        try:
            acct.confirmed_amount = max(0.0, float(data['confirmed_amount']))
        except (ValueError, TypeError):
            pass

    acct.updated_at = datetime.now(timezone.utc)
    db.session.commit()

    try:
        from firebase_client import sync_payment_account_to_firestore
        sync_payment_account_to_firestore(acct.to_dict(), wait=True)
    except Exception as fe:
        print(f"[Firebase Payment Account Update Sync Notice]: {fe}")

    _emit_payment_accounts_update(socketio)
    _emit_queue_update(socketio)
    return jsonify({
        'message': 'Payment account updated successfully',
        'account': acct.to_dict(),
        **_get_payment_accounts_payload()
    }), 200


@api.route('/payment-accounts/<path:account_ref>/toggle', methods=['PUT'])
def toggle_payment_account(account_ref):
    """Admin manually activates or deactivates a payment account regardless of transaction usage."""
    is_admin, deny_resp = _require_admin()
    if not is_admin:
        return deny_resp

    from app import socketio
    acct = _find_payment_account(account_ref)
    if not acct:
        return jsonify({'error': 'Payment account not found.'}), 404

    prev_active = bool(acct.is_active)
    prev_updated_at = acct.updated_at

    data = request.get_json(silent=True) or {}
    if 'is_active' in data:
        val = data['is_active']
        acct.is_active = val.lower() in ('true', '1', 'yes') if isinstance(val, str) else bool(val)
    else:
        acct.is_active = not bool(acct.is_active)

    acct.updated_at = datetime.now(timezone.utc)
    db.session.commit()

    firebase_synced = False
    firebase_err = None
    try:
        from firebase_client import sync_payment_account_to_firestore
        firebase_synced = bool(sync_payment_account_to_firestore(acct.to_dict(), wait=True))
    except Exception as fe:
        firebase_err = str(fe)
        print(f"[Firebase Payment Account Toggle Sync Error]: {fe}")

    if not firebase_synced:
        acct.is_active = prev_active
        acct.updated_at = prev_updated_at
        db.session.commit()
        return jsonify({
            'error': firebase_err or 'Failed to update payment account status in Firebase Firestore.',
            'firebase_synced': False,
            'account': acct.to_dict(),
            **_get_payment_accounts_payload()
        }), 500

    _emit_payment_accounts_update(socketio)
    _emit_queue_update(socketio)
    return jsonify({
        'message': f"Payment account '{acct.account_name}' {'activated' if acct.is_active else 'deactivated'}",
        'firebase_synced': True,
        'account': acct.to_dict(),
        **_get_payment_accounts_payload()
    }), 200


@api.route('/payment-accounts/<path:account_ref>', methods=['DELETE'])
def delete_payment_account(account_ref):
    """Admin safely removes a payment account while preserving historical order attribution."""
    is_admin, deny_resp = _require_admin()
    if not is_admin:
        return deny_resp

    from app import socketio
    acct = _find_payment_account(account_ref)
    if not acct:
        return jsonify({'error': 'Payment account not found.'}), 404

    deleted_id = acct.account_id
    deleted_name = acct.account_name
    db.session.delete(acct)
    db.session.commit()

    try:
        from firebase_client import delete_payment_account_from_firestore
        delete_payment_account_from_firestore(deleted_id, wait=True)
    except Exception as fe:
        print(f"[Firebase Payment Account Delete Sync Notice]: {fe}")

    _emit_payment_accounts_update(socketio)
    _emit_queue_update(socketio)
    return jsonify({
        'message': f"Payment account '{deleted_name}' removed safely.",
        'deleted_account_id': deleted_id,
        **_get_payment_accounts_payload()
    }), 200


@api.route('/orders/<path:order_ref>/payment-account', methods=['PUT'])
def select_order_payment_account(order_ref):
    """
    Allow customer or staff to select or switch the receiving payment account for an order
    whose payment is still Pending Payment (e.g. if the previously selected account became unavailable).
    """
    from app import socketio
    order = _find_order_by_ref(order_ref)
    if not order:
        return jsonify({'error': f'Order not found for reference: {order_ref}'}), 404

    if str(order.payment_status or '').lower() in ('confirmed', 'paid'):
        return jsonify({'error': 'Payment is already confirmed for this order and its receiving account cannot be changed.'}), 400

    data = request.get_json() or {}
    requested_account_id = data.get('payment_account_id')
    if not requested_account_id:
        return jsonify({'error': 'payment_account_id is required.'}), 400

    acct = _find_payment_account(requested_account_id)
    if not acct:
        return jsonify({
            'error': 'Selected payment account was not found.',
            'account_unavailable': True,
            'available_accounts': _get_payment_accounts_payload()['available_accounts']
        }), 404

    if not acct.is_available:
        return jsonify({
            'error': f"Payment account '{acct.account_name}' is currently unavailable ({acct.status_label}). Please select an available account.",
            'account_unavailable': True,
            'available_accounts': _get_payment_accounts_payload()['available_accounts']
        }), 409

    order.payment_account_id = acct.account_id
    order.payment_account_name = f"{acct.account_name} ({acct.account_holder_name})"
    order.payment_provider = acct.provider
    if not _is_online_payment_method(order.payment_method):
        order.payment_method = 'GCash'
    order.updated_at = datetime.now(timezone.utc)
    db.session.commit()

    firestore_synced = False
    try:
        from firebase_client import sync_order_to_firestore
        firestore_synced = sync_order_to_firestore(order.to_dict(), wait=True)
    except Exception as fe:
        print(f"[Firebase Order Account Select Sync Notice]: {fe}")

    _emit_queue_update(socketio, updated_order=order)
    return jsonify({
        'message': f"Selected payment account '{acct.account_name}' for Ticket #{order.queue_no}",
        'order': order.to_dict(),
        'account': acct.to_dict(),
        'firestore_synced': firestore_synced
    }), 200


# ─────────────────────────────────────────────
# PAYMENTS
# ─────────────────────────────────────────────
@api.route('/payments/gcash', methods=['POST'])
def initiate_gcash():
    """Initiate online payment for an order and record the selected payment account."""
    from app import socketio
    data = request.get_json() or {}
    order_id = data.get('order_id')
    order = _find_order_by_ref(order_id) if order_id is not None else None
    if not order:
        return jsonify({'error': 'Order not found'}), 404

    requested_account_id = data.get('payment_account_id') or order.payment_account_id
    selected_acct = None
    if requested_account_id:
        selected_acct = _find_payment_account(requested_account_id)
        if not selected_acct or not selected_acct.is_available:
            return jsonify({
                'error': 'The selected payment account is no longer available. Please select another available account.',
                'account_unavailable': True,
                'available_accounts': _get_payment_accounts_payload()['available_accounts']
            }), 409
    else:
        ok_acct, selected_acct, acct_err = _resolve_online_account_for_new_order('GCash', None)
        if not ok_acct:
            return jsonify({
                'error': acct_err,
                'online_payment_unavailable': True,
                'available_accounts': _get_payment_accounts_payload()['available_accounts']
            }), 409

    ref = order.payment_reference or f"GC-{uuid.uuid4().hex[:10].upper()}"
    order.payment_reference = ref
    order.payment_method = 'GCash'
    if selected_acct:
        order.payment_account_id = selected_acct.account_id
        order.payment_account_name = f"{selected_acct.account_name} ({selected_acct.account_holder_name})"
        order.payment_provider = selected_acct.provider
    if str(order.payment_status or '').lower() not in ('confirmed', 'paid'):
        order.payment_status = 'pending'
    order.updated_at = datetime.now(timezone.utc)
    db.session.commit()

    try:
        from firebase_client import sync_order_to_firestore
        sync_order_to_firestore(order.to_dict(), wait=True)
    except Exception as fe:
        print(f"[Firebase Initiate GCash Sync Notice]: {fe}")
    _emit_queue_update(socketio, updated_order=order)

    base_url = request.host_url.rstrip('/')
    return jsonify({
        'message': 'Online payment initiated (awaiting admin confirmation)',
        'reference': ref,
        'checkout_url': f"{base_url}/api/payments/gcash/mock-pay?ref={ref}&order_id={order.id}",
        'order_id': order.id,
        'order': order.to_dict(),
        'account': selected_acct.to_dict() if selected_acct else None
    }), 200


@api.route('/payments/gcash/callback', methods=['POST'])
def gcash_callback():
    """
    Record customer QR payment submission / reference without marking the order as Paid.
    Per strict business rules, Payment Status remains 'pending' (Pending Payment) until an
    authorized administrator explicitly confirms the payment via PUT /api/payments/confirm/<id>.
    """
    from app import socketio
    data = request.get_json() or {}
    reference = data.get('reference') or data.get('data', {}).get('attributes', {}).get('reference_number', '')
    order_id = data.get('order_id')
    status = str(data.get('status', 'submitted')).strip().lower()
    requested_account_id = data.get('payment_account_id')

    order = None
    if order_id is not None:
        order = _find_order_by_ref(order_id)
    if not order and reference:
        order = Order.query.filter_by(payment_reference=reference).first()

    if not order:
        return jsonify({'error': 'Order not found'}), 404

    if requested_account_id and str(order.payment_status or '').lower() not in ('confirmed', 'paid'):
        acct = _find_payment_account(requested_account_id)
        if not acct or not acct.is_available:
            return jsonify({
                'error': 'The selected payment account is no longer available. Please select another available payment account.',
                'account_unavailable': True,
                'available_accounts': _get_payment_accounts_payload()['available_accounts']
            }), 409
        order.payment_account_id = acct.account_id
        order.payment_account_name = f"{acct.account_name} ({acct.account_holder_name})"
        order.payment_provider = acct.provider

    if reference:
        order.payment_reference = reference

    if status == 'failed':
        if str(order.payment_status or '').lower() not in ('confirmed', 'paid'):
            order.payment_status = 'failed'
    else:
        # Keep payment_status as 'pending' unless already confirmed by an admin
        if str(order.payment_status or '').lower() not in ('confirmed', 'paid'):
            order.payment_status = 'pending'
        if not _is_online_payment_method(order.payment_method):
            order.payment_method = 'GCash'

    order.updated_at = datetime.now(timezone.utc)
    db.session.commit()
    try:
        from firebase_client import sync_order_to_firestore
        sync_order_to_firestore(order.to_dict(), wait=True)
    except Exception as fe:
        print(f"[Firebase GCash Callback Sync Notice]: {fe}")
    _emit_queue_update(socketio, updated_order=order)

    return jsonify({
        'message': 'Payment reference recorded (Pending Admin Confirmation)',
        'order': order.to_dict()
    }), 200


@api.route('/payments/confirm/<int:order_id>', methods=['PUT'])
def confirm_payment(order_id):
    return _process_confirm_payment(order_id)


@api.route('/payments/confirm/<path:order_ref>', methods=['PUT'])
def confirm_payment_by_ref(order_ref):
    return _process_confirm_payment(order_ref)


def _process_confirm_payment(order_identifier):
    """
    Admin manually confirms payment (Cash or Online) as a separate process from order completion.
    Uses _PAYMENT_CONFIRM_LOCK to prevent simultaneous confirmations from exceeding an account's limit.
    Only successfully verified and confirmed payments consume configured transaction capacity.
    """
    is_admin, deny_resp = _require_admin()
    if not is_admin:
        return deny_resp

    from app import socketio
    data = request.get_json(silent=True) or {}

    with _PAYMENT_CONFIRM_LOCK:
        order = _find_order_by_ref(order_identifier)
        if not order:
            return jsonify({'error': f'Order not found for reference: {order_identifier}'}), 404

        if order.status == 'cancelled':
            return jsonify({'error': 'Cannot confirm payment for a cancelled order.'}), 400

        # Idempotent check: if already confirmed, do not double-count transaction capacity
        if str(order.payment_status or '').lower() in ('confirmed', 'paid') and order.payment_confirmed_at is not None:
            return jsonify({
                'message': 'Payment already confirmed',
                'order': order.to_dict(),
                'already_confirmed': True,
                'firestore_synced': True
            }), 200

        pay_method = str(data.get('payment_method') or order.payment_method or 'Cash').strip()
        requested_account_id = data.get('payment_account_id') or order.payment_account_id
        used_account = None

        if _is_online_payment_method(pay_method) or data.get('payment_account_id'):
            if requested_account_id:
                used_account = _find_payment_account(requested_account_id)
                if not used_account:
                    return jsonify({
                        'error': 'The selected payment account no longer exists. Please select an available receiving account.',
                        'account_unavailable': True,
                        'available_accounts': _get_payment_accounts_payload()['available_accounts']
                    }), 409
            else:
                # Legacy online order without payment_account_id: use first available account
                avail_list = [
                    a for a in PaymentAccount.query.order_by(PaymentAccount.priority.asc(), PaymentAccount.id.asc()).all()
                    if a.is_available
                ]
                if not avail_list:
                    return jsonify({
                        'error': 'All online payment accounts are currently unavailable or have reached their limit.',
                        'account_unavailable': True,
                        'available_accounts': []
                    }), 409
                used_account = avail_list[0]

            # Validate active status and transaction limit atomically inside lock
            if not used_account.is_active:
                return jsonify({
                    'error': f"Payment account '{used_account.account_name}' is currently inactive. Please select an available account before confirming.",
                    'account_unavailable': True,
                    'available_accounts': _get_payment_accounts_payload()['available_accounts']
                }), 409

            order_amt = float(order.total_amount or 0.0)
            l_type = (used_account.limit_type or 'count').lower()
            t_limit = float(used_account.transaction_limit or 0.0)

            if l_type == 'amount':
                new_amt = round(float(used_account.confirmed_amount or 0.0) + order_amt, 2)
                if t_limit > 0 and new_amt > t_limit:
                    return jsonify({
                        'error': f"Confirming ₱{order_amt:.2f} would exceed the limit (₱{t_limit:.2f}) for '{used_account.account_name}' (Remaining: ₱{used_account.remaining_capacity:.2f}).",
                        'account_unavailable': True,
                        'available_accounts': _get_payment_accounts_payload()['available_accounts']
                    }), 409
            else:
                new_cnt = int(used_account.confirmed_count or 0) + 1
                if t_limit > 0 and new_cnt > int(t_limit):
                    return jsonify({
                        'error': f"Payment account '{used_account.account_name}' has reached its transaction limit ({int(t_limit)} confirmed transactions).",
                        'account_unavailable': True,
                        'available_accounts': _get_payment_accounts_payload()['available_accounts']
                    }), 409

            # Consume transaction capacity only upon successful confirmation
            used_account.confirmed_count = int(used_account.confirmed_count or 0) + 1
            used_account.confirmed_amount = round(float(used_account.confirmed_amount or 0.0) + order_amt, 2)
            used_account.updated_at = datetime.now(timezone.utc)

            order.payment_account_id = used_account.account_id
            order.payment_account_name = f"{used_account.account_name} ({used_account.account_holder_name})"
            order.payment_provider = used_account.provider
        else:
            # Cash payment confirmation
            order.payment_account_id = None
            order.payment_account_name = None
            order.payment_provider = 'Cash'

        now_utc = datetime.now(timezone.utc)
        order.payment_status = 'confirmed'
        order.payment_method = pay_method
        order.payment_confirmed_at = now_utc
        order.updated_at = now_utc
        if order.status != 'cancelled':
            _record_sale(order)
        db.session.commit()

    firestore_synced = False
    try:
        from firebase_client import sync_order_to_firestore, sync_payment_account_to_firestore
        if used_account is not None:
            sync_payment_account_to_firestore(used_account.to_dict(), wait=True)
        firestore_synced = sync_order_to_firestore(order.to_dict(), wait=True)
    except Exception as fe:
        print(f"[Firebase Payment Sync Notice]: {fe}")

    print(
        f"💰 [PAYMENT CONFIRMED] Order #{order.id} (Ticket #{order.queue_no}) payment confirmed via {order.payment_method}"
        + (f" [{order.payment_account_name}]" if order.payment_account_name else "")
        + "!",
        flush=True
    )
    if used_account is not None:
        _emit_payment_accounts_update(socketio)
    _emit_queue_update(socketio, updated_order=order)

    return jsonify({
        'message': 'Payment confirmed',
        'order': order.to_dict(),
        'account': used_account.to_dict() if used_account else None,
        'payment_accounts': _get_payment_accounts_payload()['accounts'],
        'available_payment_accounts': _get_payment_accounts_payload()['available_accounts'],
        'firestore_synced': firestore_synced
    }), 200


# ─────────────────────────────────────────────
# ANALYTICS
# ─────────────────────────────────────────────
@api.route('/analytics/descriptive', methods=['GET'])
def analytics_descriptive():
    result = get_descriptive_analytics(db, Sale, Order, OrderItem, Product)
    return jsonify(result), 200

@api.route('/analytics/predictive', methods=['GET'])
def analytics_predictive():
    result = get_predictive_analytics(db, Sale, Order, OrderItem, Product)
    return jsonify(result), 200

@api.route('/analytics/prescriptive', methods=['GET'])
def analytics_prescriptive():
    result = get_prescriptive_analytics(db, Sale, Order, OrderItem, Product)
    return jsonify(result), 200


def _unwrap_firestore_value(val):
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
        return [_unwrap_firestore_value(v) for v in val.get('arrayValue', {}).get('values', [])]
    if 'mapValue' in val:
        fields = val.get('mapValue', {}).get('fields', {})
        return {k: _unwrap_firestore_value(v) for k, v in fields.items()}
    return str(val)


def _parse_order_dt(dt_val, date_display=None, formatted_date=None):
    """
    Standardize transaction date and time parsing to Asia/Manila (UTC+8) timezone.
    Handles datetimes, ISO strings with/without Z offset, SQLite naive UTC timestamps,
    and formatted display strings.
    """
    if not dt_val and not date_display and not formatted_date:
        return None
    
    if isinstance(dt_val, datetime):
        if dt_val.tzinfo is not None:
            return dt_val.astimezone(MANILA_TZ)
        return dt_val.replace(tzinfo=timezone.utc).astimezone(MANILA_TZ)
    
    if isinstance(dt_val, str) and dt_val.strip():
        val = dt_val.strip()
        try:
            cleaned = val.replace('Z', '+00:00')
            dt = datetime.fromisoformat(cleaned)
            if dt.tzinfo is not None:
                return dt.astimezone(MANILA_TZ)
            return dt.replace(tzinfo=timezone.utc).astimezone(MANILA_TZ)
        except Exception:
            for fmt in ('%Y-%m-%d %H:%M:%S.%f', '%Y-%m-%d %H:%M:%S', '%Y-%m-%d', '%Y/%m/%d %H:%M:%S'):
                try:
                    dt = datetime.strptime(val, fmt)
                    return dt.replace(tzinfo=timezone.utc).astimezone(MANILA_TZ)
                except Exception:
                    continue
    
    # Try parsing formatted_date (e.g. 'Oct 15, 2026 · 06:26 AM') or date_display
    for candidate in (formatted_date, date_display):
        if candidate and isinstance(candidate, str) and candidate.strip() and candidate.strip() != 'N/A':
            c_val = candidate.strip().replace('·', '').strip()
            for fmt in ('%b %d, %Y %I:%M %p', '%b %d, %Y %H:%M', '%b %d, %Y', '%B %d, %Y'):
                try:
                    dt = datetime.strptime(c_val, fmt)
                    return dt.replace(tzinfo=MANILA_TZ)
                except Exception:
                    continue

    return None


def _format_items_str(items):
    if not items or not isinstance(items, list):
        return ""
    lines = []
    for it in items:
        if isinstance(it, dict):
            name = it.get('product_name') or it.get('name') or 'Item'
            qty = it.get('quantity') or it.get('qty') or 1
            unit_price = it.get('unit_price') or 0.0
            try:
                up_flt = float(unit_price)
                lines.append(f"{name} (x{qty} @ PHP {up_flt:.2f})")
            except Exception:
                lines.append(f"{name} (x{qty})")
        elif isinstance(it, str):
            lines.append(it)
    return "; ".join(lines)


def _count_total_items(items):
    if not items or not isinstance(items, list):
        return 0
    total_qty = 0
    for it in items:
        if isinstance(it, dict):
            qty = it.get('quantity') or it.get('qty') or 1
            try:
                total_qty += int(qty)
            except Exception:
                total_qty += 1
        else:
            total_qty += 1
    return total_qty


@api.route('/analytics/export-csv', methods=['GET'])
def analytics_export_csv():
    """
    Export actual sales and order records from Firebase Cloud Firestore and POS database to CSV.
    Supports filtering by date range (all, today, yesterday, 7d, 30d, custom), order status,
    order source, and payment method.
    Standardizes on Asia/Manila (UTC+8) for all date boundaries and displays.
    Ensures RFC 4180 escaping and UTF-8 BOM encoding for seamless Microsoft Excel compatibility.
    """
    try:
        range_filter = request.args.get('range', 'all').strip().lower()
        start_date_str = request.args.get('start_date', '').strip()
        end_date_str = request.args.get('end_date', '').strip()
        status_filter = request.args.get('status', 'all').strip().lower()
        source_filter = request.args.get('source', 'all').strip().lower()
        payment_filter = request.args.get('payment_method', 'all').strip().lower()

        # 1. Fetch latest records from Firebase Cloud Firestore REST API
        firestore_url = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders'
        firestore_orders_map = {}
        firestore_connected = False

        try:
            req = urllib.request.Request(firestore_url, headers={'User-Agent': 'KevsSiomaiExporter/1.0'})
            with urllib.request.urlopen(req, timeout=3.5) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                docs = data.get('documents', [])
                for doc in docs:
                    fields = doc.get('fields', {})
                    parsed = {k: _unwrap_firestore_value(v) for k, v in fields.items()}
                    doc_name = doc.get('name', '').split('/')[-1]
                    parsed['_doc_id'] = doc_name
                    raw_id = str(parsed.get('id') or parsed.get('order_id') or doc_name)
                    clean_key = raw_id.replace('order_', '') if raw_id.startswith('order_') else raw_id
                    firestore_orders_map[clean_key] = parsed
                firestore_connected = True
        except Exception as fe:
            print(f"[Firebase Export Fetch Notice]: {fe}", flush=True)

        # 2. Fetch records from local SQLite POS database
        local_orders_map = {}
        try:
            local_orders = Order.query.order_by(Order.created_at.desc()).all()
            for o in local_orders:
                o_dict = o.to_dict()
                items_list = []
                for it in o.items:
                    pname = it.product.name if it.product else f"Product #{it.product_id}"
                    items_list.append({
                        'product_name': pname,
                        'name': pname,
                        'quantity': it.quantity,
                        'unit_price': it.unit_price,
                        'subtotal': it.subtotal
                    })
                o_dict['items'] = items_list
                local_orders_map[str(o.id)] = o_dict
        except Exception as se:
            print(f"[SQLite Export Read Warning]: {se}", flush=True)

        # 3. Unified Reconciliation & Deduplication
        # Combine Firestore and SQLite records:
        # SQLite is the POS system of record for active order progression.
        combined_orders = []
        all_keys = set(firestore_orders_map.keys()) | set(local_orders_map.keys())

        for key in all_keys:
            if key in local_orders_map and key in firestore_orders_map:
                loc = local_orders_map[key]
                fs = firestore_orders_map[key]
                merged = dict(fs)
                merged.update(loc)
                # Preserve the original order creation timestamp from Firestore if earlier
                fs_dt = _parse_order_dt(
                    fs.get('created_at') or fs.get('timestamp'),
                    date_display=fs.get('date_display'),
                    formatted_date=fs.get('formatted_date')
                )
                loc_dt = _parse_order_dt(
                    loc.get('created_at') or loc.get('timestamp'),
                    date_display=loc.get('date_display'),
                    formatted_date=loc.get('formatted_date')
                )
                if fs_dt and loc_dt and fs_dt < loc_dt:
                    merged['created_at'] = fs.get('created_at') or fs.get('timestamp')
                    merged['date_display'] = fs.get('date_display')
                    merged['formatted_date'] = fs.get('formatted_date')
                combined_orders.append(merged)
            elif key in local_orders_map:
                loc = local_orders_map[key]
                combined_orders.append(loc)
            else:
                combined_orders.append(firestore_orders_map[key])

        # 4. Standardize Date Range Boundaries in Asia/Manila (UTC+8)
        now_ph = datetime.now(MANILA_TZ)
        start_dt = None
        end_dt = None

        if range_filter == 'today':
            start_dt = datetime(now_ph.year, now_ph.month, now_ph.day, 0, 0, 0, 0, tzinfo=MANILA_TZ)
            end_dt = datetime(now_ph.year, now_ph.month, now_ph.day, 23, 59, 59, 999999, tzinfo=MANILA_TZ)
        elif range_filter == 'yesterday':
            yest = now_ph - timedelta(days=1)
            start_dt = datetime(yest.year, yest.month, yest.day, 0, 0, 0, 0, tzinfo=MANILA_TZ)
            end_dt = datetime(yest.year, yest.month, yest.day, 23, 59, 59, 999999, tzinfo=MANILA_TZ)
        elif range_filter == '7d':
            start_dt = (now_ph - timedelta(days=7)).replace(hour=0, minute=0, second=0, microsecond=0)
            end_dt = datetime(now_ph.year, now_ph.month, now_ph.day, 23, 59, 59, 999999, tzinfo=MANILA_TZ)
        elif range_filter == '30d':
            start_dt = (now_ph - timedelta(days=30)).replace(hour=0, minute=0, second=0, microsecond=0)
            end_dt = datetime(now_ph.year, now_ph.month, now_ph.day, 23, 59, 59, 999999, tzinfo=MANILA_TZ)
        elif range_filter == 'custom':
            if start_date_str:
                try:
                    s_parts = [int(p) for p in start_date_str.split('-')]
                    start_dt = datetime(s_parts[0], s_parts[1], s_parts[2], 0, 0, 0, 0, tzinfo=MANILA_TZ)
                except Exception:
                    pass
            if end_date_str:
                try:
                    e_parts = [int(p) for p in end_date_str.split('-')]
                    end_dt = datetime(e_parts[0], e_parts[1], e_parts[2], 23, 59, 59, 999999, tzinfo=MANILA_TZ)
                except Exception:
                    pass

        # 5. Apply Filters and Calculate Accurate Revenue
        filtered_orders = []
        collected_revenue = 0.0

        for o in combined_orders:
            dt_val = o.get('created_at') or o.get('timestamp') or ''
            date_disp = o.get('date_display')
            fmt_date = o.get('formatted_date')
            parsed_dt = _parse_order_dt(dt_val, date_display=date_disp, formatted_date=fmt_date)

            # Date Range Filter
            if parsed_dt is not None:
                if start_dt and parsed_dt < start_dt:
                    continue
                if end_dt and parsed_dt > end_dt:
                    continue
            elif start_dt or end_dt:
                continue

            # Status Normalization
            o_status = str(o.get('status') or 'pending').strip().lower()
            p_status = str(o.get('payment_status') or 'pending').strip().lower()

            # Status Filter
            if status_filter != 'all':
                if status_filter in ('completed', 'done', 'fulfilled', 'paid'):
                    is_completed = (
                        (o_status in ('completed', 'delivered', 'done', 'fulfilled') or 
                         p_status in ('confirmed', 'paid', 'completed')) and 
                        o_status != 'cancelled'
                    )
                    if not is_completed:
                        continue
                elif status_filter == 'pending':
                    is_pending = (
                        o_status in ('pending', 'accepted', 'preparing', 'ready_pickup', 'ready_delivery', 'out_for_delivery') and
                        o_status != 'cancelled'
                    )
                    if not is_pending:
                        continue
                elif status_filter in ('cancelled', 'failed'):
                    if o_status not in ('cancelled', 'failed') and p_status != 'failed':
                        continue
                else:
                    if o_status != status_filter and p_status != status_filter:
                        continue

            # Source Filter (walk-in vs online)
            src_val = str(o.get('type') or 'walk-in').strip().lower()
            if source_filter != 'all' and src_val != source_filter:
                continue

            # Payment Method Filter
            if payment_filter != 'all':
                pm_val = str(o.get('payment_method') or 'cash').strip().lower()
                if pm_val != payment_filter:
                    continue

            # Safe amount parsing
            try:
                amt = float(o.get('total_amount') or o.get('total') or 0.0)
            except Exception:
                amt = 0.0

            filtered_orders.append((o, parsed_dt, amt))

            # Collected revenue strictly excludes cancelled/unpaid orders
            is_collected = (
                (o_status in ('completed', 'delivered', 'done', 'fulfilled') or 
                 p_status in ('confirmed', 'paid', 'completed')) and 
                o_status != 'cancelled'
            )
            if is_collected:
                collected_revenue += amt

        # Sort descending by transaction date (newest first)
        epoch_min = datetime(1970, 1, 1, 0, 0, 0, tzinfo=MANILA_TZ)
        filtered_orders.sort(key=lambda pair: pair[1] or epoch_min, reverse=True)

        # 6. Construct RFC 4180 CSV
        output = io.StringIO()
        writer = csv.writer(output, quoting=csv.QUOTE_MINIMAL)

        headers = [
            "Order ID",
            "Transaction Date",
            "Customer Name",
            "Customer Phone",
            "Order Source",
            "Fulfillment Type",
            "Delivery Address",
            "Products & Quantities",
            "Total Items Count",
            "Payment Method",
            "Payment Status",
            "Order Status",
            "Total Amount (PHP)",
            "Notes"
        ]
        writer.writerow(headers)

        for o, p_dt, amt in filtered_orders:
            raw_id = o.get('id') or o.get('order_id') or o.get('order_number') or o.get('_doc_id') or 'N/A'
            order_id = f"#{raw_id}" if str(raw_id).isdigit() else str(raw_id)
            date_str = p_dt.strftime('%Y-%m-%d %I:%M:%S %p') if p_dt else str(o.get('date_display') or o.get('created_at') or '')
            customer_name = o.get('customer_name') or 'Walk-in Customer'
            customer_phone = o.get('customer_phone') or 'N/A'
            source = str(o.get('type') or 'walk-in').title()
            fulfillment = str(o.get('order_type') or 'pickup').title()
            delivery_address = o.get('delivery_address') or 'N/A'

            items = o.get('items') or []
            products_str = _format_items_str(items)
            items_count = _count_total_items(items)

            payment_method = o.get('payment_method') or 'Cash'
            payment_status = str(o.get('payment_status') or 'Pending').title()
            order_status = str(o.get('status') or 'Pending').title()
            notes = o.get('notes') or ''

            writer.writerow([
                order_id,
                date_str,
                customer_name,
                customer_phone,
                source,
                fulfillment,
                delivery_address,
                products_str,
                items_count,
                payment_method,
                payment_status,
                order_status,
                f"{amt:.2f}",
                notes
            ])

        csv_data = '\ufeff' + output.getvalue()

        today_file_str = now_ph.strftime('%Y-%m-%d')
        if range_filter == 'today':
            filename = f"kevs_siomai_sales_today_{today_file_str}.csv"
        elif range_filter == 'yesterday':
            yest_file_str = (now_ph - timedelta(days=1)).strftime('%Y-%m-%d')
            filename = f"kevs_siomai_sales_yesterday_{yest_file_str}.csv"
        elif range_filter == 'custom' and start_date_str and end_date_str:
            filename = f"kevs_siomai_sales_{start_date_str}_to_{end_date_str}.csv"
        else:
            filename = f"kevs_siomai_sales_{today_file_str}.csv"

        response = Response(csv_data, mimetype='text/csv; charset=utf-8')
        response.headers['Content-Disposition'] = f'attachment; filename="{filename}"'
        response.headers['X-Record-Count'] = str(len(filtered_orders))
        response.headers['X-Total-Revenue'] = f"{collected_revenue:.2f}"
        response.headers['X-Data-Source'] = 'Firebase Cloud Firestore & Local POS Synced'
        return response
    except Exception as err:
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(err)}), 500



# ─────────────────────────────────────────────
# OFFLINE SYNC
# ─────────────────────────────────────────────
@api.route('/offline/sync', methods=['POST'])
def offline_sync():
    """Receive batched offline orders and sales from the Admin PWA."""
    from app import socketio
    data = request.get_json()
    batch_id = data.get('batch_id', str(uuid.uuid4()))
    orders_data = data.get('orders', [])
    source = data.get('source', 'admin_pwa')

    # Check for duplicate batch
    existing = OfflineSyncLog.query.filter_by(batch_id=batch_id).first()
    if existing:
        return jsonify({'message': 'Batch already synced', 'batch_id': batch_id, 'duplicate': True}), 200

    synced_orders = 0
    synced_sales = 0
    queue = _get_or_init_queue()

    for order_data in orders_data:
        queue.current_queue_no += 1
        raw_created_at = order_data.get('created_at')
        created_at_dt = datetime.now(timezone.utc)
        if raw_created_at:
            try:
                created_at_dt = datetime.fromisoformat(str(raw_created_at).replace('Z', '+00:00'))
            except Exception:
                created_at_dt = datetime.now(timezone.utc)

        order = Order(
            queue_no=queue.current_queue_no,
            type=order_data.get('type', 'walk-in'),
            order_type=order_data.get('order_type', 'pickup'),
            customer_name=order_data.get('customer_name', 'Offline Walk-in'),
            customer_phone=order_data.get('customer_phone', ''),
            status=order_data.get('status', 'completed'),
            payment_status=order_data.get('payment_status', 'confirmed'),
            payment_method=order_data.get('payment_method', 'Cash'),
            total_amount=float(order_data.get('total', 0)),
            notes=order_data.get('notes', '') + ' [Synced from offline]',
            is_offline=True,
            created_at=created_at_dt
        )
        db.session.add(order)
        db.session.flush()

        # Record items
        for item_data in order_data.get('items', []):
            product = Product.query.get(item_data.get('product_id'))
            if product:
                oi = OrderItem(
                    order_id=order.id,
                    product_id=product.id,
                    quantity=int(item_data.get('quantity', 1)),
                    unit_price=float(item_data.get('unit_price', product.price)),
                    subtotal=float(item_data.get('subtotal', product.price))
                )
                db.session.add(oi)

        if order_data.get('status') in ('completed', 'delivered'):
            _record_sale(order)
            synced_sales += 1

        synced_orders += 1

    queue.last_updated = datetime.now(timezone.utc)

    log = OfflineSyncLog(
        batch_id=batch_id,
        orders_synced=synced_orders,
        sales_synced=synced_sales,
        source=source
    )
    db.session.add(log)
    db.session.commit()
    _emit_queue_update(socketio)

    return jsonify({
        'message': 'Offline sync successful',
        'batch_id': batch_id,
        'orders_synced': synced_orders,
        'sales_synced': synced_sales
    }), 200


# ─────────────────────────────────────────────
# DASHBOARD / REPORTS
# ─────────────────────────────────────────────
@api.route('/dashboard/stats', methods=['GET'])
def dashboard_stats():
    """Quick stats for the dashboard header cards using Asia/Manila (UTC+8) date boundaries."""
    queue = _get_or_init_queue()
    now_utc = datetime.now(timezone.utc)
    ph_offset = timedelta(hours=8)
    now_ph = now_utc + ph_offset
    today_start_ph = now_ph.replace(hour=0, minute=0, second=0, microsecond=0)
    today_start = (today_start_ph - ph_offset).replace(tzinfo=None)

    active_orders = Order.query.filter(
        Order.status.notin_(['completed', 'delivered', 'cancelled'])
    ).count()
    pending_orders = Order.query.filter_by(status='pending').count()
    today_completed = Order.query.filter(
        Order.status.in_(['completed', 'delivered']),
        Order.created_at >= today_start
    ).count()

    today_sales_q = db.session.query(db.func.sum(Sale.total_amount)).filter(
        Sale.timestamp >= today_start
    ).scalar()
    today_revenue = float(today_sales_q or 0.0)

    total_sales_q = db.session.query(db.func.sum(Sale.total_amount)).scalar()
    total_sales = float(total_sales_q or 0.0)

    # In case Sale has not been synced from completed orders yet
    if total_sales == 0.0:
        completed_orders_total = db.session.query(db.func.sum(Order.total_amount)).filter(
            Order.status.in_(['completed', 'delivered'])
        ).scalar()
        total_sales = float(completed_orders_total or 0.0)
        today_completed_orders_total = db.session.query(db.func.sum(Order.total_amount)).filter(
            Order.status.in_(['completed', 'delivered']),
            Order.created_at >= today_start
        ).scalar()
        today_revenue = float(today_completed_orders_total or 0.0)

    low_stock_products = Product.query.filter(
        Product.is_active == True,
        Product.stock <= (Product.max_stock * 0.20)
    ).count()

    all_completed = Order.query.filter(Order.status.in_(['completed', 'delivered'])).count()

    return jsonify({
        'queue': queue.to_dict(),
        'active_orders': active_orders,
        'pending_orders': pending_orders,
        'today_completed': today_completed,
        'completed_orders': all_completed,
        'today_revenue': today_revenue,
        'total_sales': total_sales,
        'total_revenue': total_sales,
        'low_stock_alerts': low_stock_products
    }), 200


# ─────────────────────────────────────────────
# REVIEWS MANAGEMENT (Customer App & Admin Dashboard)
# ─────────────────────────────────────────────
@api.route('/reviews', methods=['GET'])
def get_reviews():
    """
    Get customer reviews with statistics.
    Query params:
      - include_disabled: 'true' (for admin website to view all reviews including disabled ones)
      - order_id: optional filter by order
    """
    include_disabled = request.args.get('include_disabled', 'false').lower() in ('true', '1')
    order_id = request.args.get('order_id', type=int)

    query = Review.query
    if not include_disabled:
        query = query.filter(Review.is_disabled == False)
    if order_id is not None:
        query = query.filter(Review.order_id == order_id)

    reviews = query.order_by(Review.created_at.desc()).all()

    # Calculate statistics based on available reviews
    all_active_reviews = Review.query.filter(Review.is_disabled == False).all()
    target_reviews = reviews if include_disabled else all_active_reviews
    total = len(target_reviews)
    avg_rating = round(sum(r.rating for r in target_reviews) / total, 1) if total > 0 else 0.0

    breakdown = {5: 0, 4: 0, 3: 0, 2: 0, 1: 0}
    for r in target_reviews:
        if r.rating in breakdown:
            breakdown[r.rating] += 1

    return jsonify({
        'reviews': [r.to_dict() for r in reviews],
        'stats': {
            'total_reviews': total,
            'average_rating': avg_rating,
            'rating_breakdown': breakdown,
            'total_all': Review.query.count(),
            'total_disabled': Review.query.filter(Review.is_disabled == True).count()
        }
    }), 200


@api.route('/reviews', methods=['POST'])
def create_review():
    """
    Create a new customer review from the mobile app.
    Rating (1-5 stars) is required.
    Comment is optional.
    """
    data = request.get_json() or {}
    rating = data.get('rating')

    if rating is None:
        return jsonify({'error': 'Rating is required (1 to 5 stars)'}), 400

    try:
        rating = int(rating)
    except (ValueError, TypeError):
        return jsonify({'error': 'Rating must be an integer between 1 and 5'}), 400

    if rating < 1 or rating > 5:
        return jsonify({'error': 'Rating must be between 1 and 5 stars'}), 400

    comment = str(data.get('comment', '')).strip()
    if len(comment) > 1000:
        return jsonify({'error': 'Ang komento ay hindi maaaring lumampas sa 1000 characters.'}), 400

    raw_name = str(data.get('customer_name', '')).strip()
    if raw_name and raw_name not in ('Anonymous Customer', 'Customer'):
        is_valid_name, name_res = _validate_person_name(raw_name, "Pangalan ng kostumer", allow_default=True)
        if not is_valid_name:
            return jsonify({'error': name_res}), 400
        customer_name = name_res
    else:
        customer_name = raw_name or 'Anonymous Customer'

    raw_phone = str(data.get('customer_phone', '')).strip()
    is_valid_phone, phone_res = _validate_phone_number(raw_phone, required=False)
    if not is_valid_phone:
        return jsonify({'error': phone_res}), 400
    customer_phone = phone_res

    order_id = data.get('order_id')

    # Validate order_id if supplied
    if order_id:
        order = Order.query.get(order_id)
        if not order:
            order_id = None

    review = Review(
        rating=rating,
        comment=comment,
        customer_name=customer_name,
        customer_phone=customer_phone,
        order_id=order_id,
        is_disabled=False
    )

    db.session.add(review)
    db.session.commit()
    print(f"⭐ [CUSTOMER REVIEW] {customer_name} rated {rating} star(s): \"{comment}\"", flush=True)

    review_dict = review.to_dict()
    _emit_review_event('review_created', review_dict)

    return jsonify({
        'message': 'Thank you! Your review has been submitted.',
        'review': review_dict
    }), 201


@api.route('/reviews/<int:review_id>/reply', methods=['POST', 'PUT'])
def reply_to_review(review_id):
    """
    Admin replies to a customer review.
    """
    review = Review.query.get(review_id)
    if not review:
        return jsonify({'error': 'Review not found'}), 404

    data = request.get_json() or {}
    reply_text = str(data.get('reply', '')).strip()
    if len(reply_text) > 1000:
        return jsonify({'error': 'Ang tugon ay hindi maaaring lumampas sa 1000 characters.'}), 400

    review.reply = reply_text
    review.replied_at = datetime.now(timezone.utc) if reply_text else None
    db.session.commit()

    review_dict = review.to_dict()
    _emit_review_event('review_updated', review_dict)

    return jsonify({
        'message': 'Reply updated successfully',
        'review': review_dict
    }), 200


@api.route('/reviews/<int:review_id>/toggle-status', methods=['POST', 'PUT'])
def toggle_review_status(review_id):
    """
    Admin toggles or sets the disabled state of a review.
    """
    review = Review.query.get(review_id)
    if not review:
        return jsonify({'error': 'Review not found'}), 404

    data = request.get_json() or {}
    if 'is_disabled' in data:
        review.is_disabled = bool(data['is_disabled'])
    else:
        review.is_disabled = not review.is_disabled

    db.session.commit()

    review_dict = review.to_dict()
    _emit_review_event('review_updated', review_dict)

    action_str = 'disabled' if review.is_disabled else 'enabled'
    return jsonify({
        'message': f'Review has been {action_str}',
        'review': review_dict
    }), 200


@api.route('/reviews/clear', methods=['POST', 'DELETE'])
def clear_reviews():
    """
    Clear all customer reviews from the database.
    """
    num_deleted = Review.query.delete()
    db.session.commit()

    _emit_review_event('review_updated', {'cleared': True})

    return jsonify({
        'message': f'All reviews have been cleared ({num_deleted} removed).',
        'count': num_deleted
    }), 200


@api.route('/reviews/<int:review_id>', methods=['DELETE'])
def delete_review(review_id):
    """
    Delete a single customer review.
    """
    review = Review.query.get(review_id)
    if not review:
        return jsonify({'error': 'Review not found'}), 404

    db.session.delete(review)
    db.session.commit()

    _emit_review_event('review_updated', {'deleted_id': review_id})

    return jsonify({
        'message': f'Review #{review_id} deleted successfully.',
        'review_id': review_id
    }), 200


