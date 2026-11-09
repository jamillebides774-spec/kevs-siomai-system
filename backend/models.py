from datetime import datetime, timezone, timedelta
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()

MANILA_TZ = timezone(timedelta(hours=8))


def ensure_utc(dt):
    """Normalize any datetime (naive or timezone-aware) to canonical UTC."""
    if dt is None:
        return None
    if dt.tzinfo is not None:
        return dt.astimezone(timezone.utc)
    return dt.replace(tzinfo=timezone.utc)


def to_utc_iso(dt):
    """Serialize a datetime as a canonical ISO-8601 UTC string ending with 'Z'."""
    utc_dt = ensure_utc(dt)
    if utc_dt is None:
        return None
    return utc_dt.isoformat().replace('+00:00', 'Z')


def to_manila_dt(dt):
    """Convert any datetime (naive UTC or tz-aware) to Asia/Manila (UTC+8)."""
    utc_dt = ensure_utc(dt)
    if utc_dt is None:
        return None
    return utc_dt.astimezone(MANILA_TZ)

class User(db.Model):
    __tablename__ = 'users'

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    full_name = db.Column(db.String(120), default="Kevin Bernardino")
    role = db.Column(db.String(50), default="admin") # 'admin', 'staff'
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            'id': self.id,
            'username': self.username,
            'full_name': self.full_name,
            'role': self.role,
            'created_at': self.created_at.isoformat() if self.created_at else None
        }


class Product(db.Model):
    __tablename__ = 'products'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    category = db.Column(db.String(80), default="Siomai") # Siomai, Dumplings, Sauces, Drinks, Rice Meals
    price = db.Column(db.Float, nullable=False)
    stock = db.Column(db.Integer, default=50, nullable=False)
    max_stock = db.Column(db.Integer, default=100, nullable=False)
    unit = db.Column(db.String(20), default="servings") # servings, pcs, bottles, packs
    description = db.Column(db.String(255), default="")
    image_url = db.Column(db.String(255), default="")
    is_active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    items = db.relationship('OrderItem', backref='product', lazy=True)

    @property
    def stock_percentage(self):
        if self.max_stock <= 0:
            return 0
        return round((self.stock / self.max_stock) * 100, 1)

    @property
    def stock_status(self):
        pct = self.stock_percentage
        if self.stock <= 0:
            return 'out_of_stock'
        elif pct <= 10.0:
            return 'critical' # <= 10%
        elif pct <= 20.0:
            return 'warning' # <= 20%
        return 'available'

    def to_dict(self):
        return {
            'id': self.id,
            'product_id': self.id,
            'name': self.name,
            'category': self.category,
            'price': self.price,
            'stock': self.stock,
            'max_stock': self.max_stock,
            'min_stock': max(10, int(self.max_stock * 0.2)),
            'unit': self.unit,
            'stock_percentage': self.stock_percentage,
            'stock_status': self.stock_status,
            'status': 'Active' if self.is_active else 'Inactive',
            'description': self.description,
            'image_url': self.image_url,
            'is_active': bool(self.is_active)
        }


class Order(db.Model):
    __tablename__ = 'orders'

    id = db.Column(db.Integer, primary_key=True)
    queue_no = db.Column(db.Integer, nullable=False, index=True)
    type = db.Column(db.String(20), nullable=False, default="walk-in") # 'walk-in', 'online'
    order_type = db.Column(db.String(20), nullable=False, default="pickup") # 'pickup', 'delivery'
    customer_id = db.Column(db.Integer, nullable=True)
    customer_name = db.Column(db.String(120), default="Walk-in Customer")
    customer_phone = db.Column(db.String(50), default="")
    delivery_address = db.Column(db.Text, default="")
    status = db.Column(db.String(30), default="pending", index=True)
    # Status progression:
    # Walk-in: pending -> accepted -> preparing -> ready_pickup -> completed
    # Online Pickup: pending -> accepted -> preparing -> ready_pickup -> completed
    # Online Delivery: pending -> accepted -> preparing -> ready_delivery -> out_for_delivery -> delivered
    payment_status = db.Column(db.String(30), default="pending", index=True) # 'pending', 'confirmed', 'failed'
    payment_method = db.Column(db.String(30), default="Cash") # 'Cash', 'GCash'
    payment_reference = db.Column(db.String(100), default="")
    payment_account_id = db.Column(db.String(64), default="")
    payment_account_name = db.Column(db.String(120), default="")
    payment_provider = db.Column(db.String(60), default="")
    payment_confirmed_at = db.Column(db.DateTime, nullable=True)
    total_amount = db.Column(db.Float, default=0.0)
    notes = db.Column(db.Text, default="")
    is_offline = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), index=True)
    updated_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    items = db.relationship('OrderItem', backref='order', lazy=True, cascade="all, delete-orphan")
    sales = db.relationship('Sale', backref='order', lazy=True, cascade="all, delete-orphan")

    def to_dict(self):
        ph_created = to_manila_dt(self.created_at)
        ph_updated = to_manila_dt(self.updated_at)
        utc_created_iso = to_utc_iso(self.created_at)
        utc_updated_iso = to_utc_iso(self.updated_at)

        return {
            'id': self.id,
            'order_id': self.id,
            'order_number': str(self.id),
            'queue_no': self.queue_no,
            'queue_number': self.queue_no,
            'type': self.type,
            'order_type': self.order_type,
            'customer_id': self.customer_id,
            'customer_name': self.customer_name,
            'customer_phone': self.customer_phone,
            'delivery_address': self.delivery_address,
            'status': self.status,
            'payment_status': self.payment_status,
            'payment_method': self.payment_method,
            'payment_reference': self.payment_reference,
            'payment_account_id': self.payment_account_id or '',
            'payment_account_name': self.payment_account_name or '',
            'payment_provider': self.payment_provider or '',
            'payment_confirmed_at': to_utc_iso(self.payment_confirmed_at),
            'total': self.total_amount,
            'total_amount': self.total_amount,
            'notes': self.notes,
            'is_offline': self.is_offline,
            'items': [item.to_dict() for item in self.items],
            'timestamp': utc_created_iso,
            'created_at': utc_created_iso,
            'created_at_ph': ph_created.isoformat() if ph_created else None,
            'updated_at': utc_updated_iso,
            'updated_at_ph': ph_updated.isoformat() if ph_updated else None,
            'date_display': ph_created.strftime('%b %d, %Y') if ph_created else 'N/A',
            'time_display': ph_created.strftime('%I:%M %p') if ph_created else 'N/A',
            'formatted_date': ph_created.strftime('%b %d, %Y · %I:%M %p') if ph_created else 'N/A'
        }


class OrderItem(db.Model):
    __tablename__ = 'order_items'

    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer, db.ForeignKey('orders.id'), nullable=False)
    product_id = db.Column(db.Integer, db.ForeignKey('products.id'), nullable=False)
    quantity = db.Column(db.Integer, nullable=False, default=1)
    unit_price = db.Column(db.Float, nullable=False, default=0.0)
    subtotal = db.Column(db.Float, nullable=False, default=0.0)

    def to_dict(self):
        return {
            'id': self.id,
            'order_id': self.order_id,
            'product_id': self.product_id,
            'product_name': self.product.name if self.product else "Unknown Product",
            'image_url': (self.product.image_url if self.product and self.product.image_url else ""),
            'unit': (self.product.unit if self.product and self.product.unit else "pcs"),
            'quantity': self.quantity,
            'qty': self.quantity,
            'unit_price': self.unit_price,
            'subtotal': self.subtotal
        }


class Sale(db.Model):
    __tablename__ = 'sales'

    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer, db.ForeignKey('orders.id'), nullable=True, unique=True)
    total_amount = db.Column(db.Float, nullable=False, default=0.0)
    payment_method = db.Column(db.String(30), default="Cash") # 'Cash', 'GCash'
    timestamp = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), index=True)

    def to_dict(self):
        ph_ts = to_manila_dt(self.timestamp)
        return {
            'id': self.id,
            'order_id': self.order_id,
            'total_amount': self.total_amount,
            'payment_method': self.payment_method,
            'timestamp': to_utc_iso(self.timestamp),
            'timestamp_ph': ph_ts.isoformat() if ph_ts else None,
            'formatted_date': ph_ts.strftime('%b %d, %Y · %I:%M %p') if ph_ts else 'N/A'
        }


class Queue(db.Model):
    __tablename__ = 'queue'

    id = db.Column(db.Integer, primary_key=True)
    current_queue_no = db.Column(db.Integer, default=0, nullable=False)
    now_serving = db.Column(db.Integer, default=0, nullable=False)
    last_updated = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            'current_queue_no': self.current_queue_no,
            'current_queue': self.current_queue_no,
            'now_serving': self.now_serving,
            'now_serving_number': self.now_serving,
            'last_updated': to_utc_iso(self.last_updated)
        }


class OfflineSyncLog(db.Model):
    __tablename__ = 'offline_sync_logs'

    id = db.Column(db.Integer, primary_key=True)
    batch_id = db.Column(db.String(100), nullable=False)
    orders_synced = db.Column(db.Integer, default=0)
    sales_synced = db.Column(db.Integer, default=0)
    source = db.Column(db.String(50), default="admin_pwa")
    timestamp = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            'id': self.id,
            'batch_id': self.batch_id,
            'orders_synced': self.orders_synced,
            'sales_synced': self.sales_synced,
            'source': self.source,
            'timestamp': to_utc_iso(self.timestamp)
        }


class Review(db.Model):
    __tablename__ = 'reviews'

    id = db.Column(db.Integer, primary_key=True)
    customer_name = db.Column(db.String(120), default="Anonymous Customer")
    customer_phone = db.Column(db.String(50), default="")
    rating = db.Column(db.Integer, nullable=False) # 1 to 5
    comment = db.Column(db.Text, default="")
    order_id = db.Column(db.Integer, db.ForeignKey('orders.id'), nullable=True)
    reply = db.Column(db.Text, nullable=True, default="")
    replied_at = db.Column(db.DateTime, nullable=True)
    is_disabled = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), index=True)

    order = db.relationship('Order', backref=db.backref('reviews', lazy=True))

    def to_dict(self):
        ph_created = to_manila_dt(self.created_at)
        return {
            'id': self.id,
            'customer_name': self.customer_name or 'Anonymous Customer',
            'customer_phone': self.customer_phone or '',
            'rating': self.rating,
            'comment': self.comment or '',
            'order_id': self.order_id,
            'reply': self.reply or '',
            'replied_at': to_utc_iso(self.replied_at),
            'is_disabled': bool(self.is_disabled),
            'created_at': to_utc_iso(self.created_at),
            'formatted_date': ph_created.strftime('%b %d, %Y · %I:%M %p') if ph_created else 'N/A'
        }


class PaymentAccount(db.Model):
    __tablename__ = 'payment_accounts'

    id = db.Column(db.Integer, primary_key=True)
    account_id = db.Column(db.String(64), unique=True, nullable=False, index=True)
    account_name = db.Column(db.String(120), nullable=False)
    provider = db.Column(db.String(60), nullable=False, default="GCash / InstaPay")
    account_holder_name = db.Column(db.String(120), nullable=False)
    mobile_number = db.Column(db.String(60), nullable=False)
    qr_image_url = db.Column(db.Text, nullable=False, default="/images/gcash_instapay_qr_1.jpg")
    limit_type = db.Column(db.String(20), nullable=False, default="count")  # 'count' or 'amount'
    transaction_limit = db.Column(db.Float, nullable=False, default=5.0)
    confirmed_count = db.Column(db.Integer, nullable=False, default=0)
    confirmed_amount = db.Column(db.Float, nullable=False, default=0.0)
    is_active = db.Column(db.Boolean, nullable=False, default=True)
    priority = db.Column(db.Integer, nullable=False, default=1)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    @property
    def confirmed_usage(self):
        if str(self.limit_type or 'count').lower() == 'amount':
            return round(float(self.confirmed_amount or 0.0), 2)
        return int(self.confirmed_count or 0)

    @property
    def remaining_capacity(self):
        limit_val = float(self.transaction_limit or 0.0)
        if limit_val <= 0:
            return 0
        if str(self.limit_type or 'count').lower() == 'amount':
            return max(0.0, round(limit_val - float(self.confirmed_amount or 0.0), 2))
        return max(0, int(limit_val) - int(self.confirmed_count or 0))

    @property
    def limit_reached(self):
        limit_val = float(self.transaction_limit or 0.0)
        if limit_val <= 0:
            return True
        if str(self.limit_type or 'count').lower() == 'amount':
            return float(self.confirmed_amount or 0.0) >= limit_val
        return int(self.confirmed_count or 0) >= int(limit_val)

    @property
    def is_available(self):
        return bool(self.is_active and not self.limit_reached)

    @property
    def status_label(self):
        if not self.is_active:
            return 'Inactive'
        if self.limit_reached:
            return 'Limit Reached'
        return 'Available'

    def to_dict(self):
        return {
            'id': self.id,
            'account_id': self.account_id,
            'account_name': self.account_name,
            'provider': self.provider,
            'account_holder_name': self.account_holder_name,
            'mobile_number': self.mobile_number,
            'qr_image_url': self.qr_image_url,
            'limit_type': self.limit_type or 'count',
            'transaction_limit': float(self.transaction_limit or 0.0) if str(self.limit_type or 'count').lower() == 'amount' else int(self.transaction_limit or 0),
            'confirmed_count': int(self.confirmed_count or 0),
            'confirmed_amount': round(float(self.confirmed_amount or 0.0), 2),
            'confirmed_usage': self.confirmed_usage,
            'remaining_capacity': self.remaining_capacity,
            'limit_reached': self.limit_reached,
            'is_active': bool(self.is_active),
            'is_available': self.is_available,
            'status_label': self.status_label,
            'priority': int(self.priority or 1),
            'created_at': to_utc_iso(self.created_at),
            'updated_at': to_utc_iso(self.updated_at),
        }


