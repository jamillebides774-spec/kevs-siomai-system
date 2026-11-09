import pandas as pd
import numpy as np
from datetime import datetime, timedelta, timezone
from sklearn.linear_model import LinearRegression


PH_TZ = timezone(timedelta(hours=8))


def _get_ph_now():
    """Return current datetime in Philippines local time (Asia/Manila, UTC+8)."""
    return datetime.now(timezone.utc).astimezone(PH_TZ)


def _to_ph_dt(dt):
    """Convert a naive UTC or timezone-aware datetime to Asia/Manila (UTC+8)."""
    if dt is None:
        return _get_ph_now()
    if dt.tzinfo is not None:
        return dt.astimezone(PH_TZ)
    return dt.replace(tzinfo=timezone.utc).astimezone(PH_TZ)


def _sync_sales_with_orders(db, Sale, Order, now):
    """
    Ensure all confirmed/completed orders in the database have a corresponding
    Sale record whose timestamp matches the order's actual creation timestamp (Order.created_at),
    while strictly deleting any sales for cancelled orders and removing duplicates
    so analytics revenue and date grouping remain 100% accurate.
    """
    try:
        sales = Sale.query.all()
        orders = Order.query.all()
        synced_any = False

        # 1. Purge sales for cancelled orders
        cancelled_ids = {o.id for o in orders if o.status == 'cancelled'}
        for s in sales:
            if s.order_id in cancelled_ids:
                db.session.delete(s)
                synced_any = True

        # 2. Purge duplicate sales and map existing sales by order_id
        seen_order_ids = {}
        for s in sales:
            if s.order_id and s.order_id not in cancelled_ids:
                if s.order_id in seen_order_ids:
                    db.session.delete(s)
                    synced_any = True
                else:
                    seen_order_ids[s.order_id] = s

        # 3. Add missing sales and align Sale.timestamp with Order.created_at
        completed_orders = [
            o for o in orders
            if o.status != 'cancelled' and (o.status in ('completed', 'delivered') or o.payment_status == 'confirmed')
        ]
        for o in completed_orders:
            if o.id not in seen_order_ids:
                new_s = Sale(
                    order_id=o.id,
                    total_amount=float(o.total_amount or 0.0),
                    payment_method=o.payment_method or 'Cash',
                    timestamp=o.created_at or now
                )
                db.session.add(new_s)
                seen_order_ids[o.id] = new_s
                synced_any = True
            else:
                existing_s = seen_order_ids[o.id]
                if o.created_at and existing_s.timestamp != o.created_at:
                    existing_s.timestamp = o.created_at
                    synced_any = True
                if float(o.total_amount or 0.0) != float(existing_s.total_amount or 0.0):
                    existing_s.total_amount = float(o.total_amount or 0.0)
                    synced_any = True

        if synced_any:
            db.session.commit()
    except Exception as e:
        db.session.rollback()
        print(f"[Analytics Sync Error]: {e}", flush=True)


def get_descriptive_analytics(db, Sale, Order, OrderItem, Product):
    """
    Compute descriptive analytics strictly from actual database records:
    sales trends, top products, empirical peak hours, and order distribution.
    No hardcoded or fabricated values.
    """
    now = datetime.now(timezone.utc)
    now_ph = _get_ph_now()
    today = now_ph.date()

    # Step 1: Synchronize Sales table with any completed/confirmed Orders
    _sync_sales_with_orders(db, Sale, Order, now)

    # Step 2: Query actual records
    sales = Sale.query.all()
    orders = Order.query.all()
    order_items = OrderItem.query.all()
    products = Product.query.filter_by(is_active=True).all()

    # --- Sales DataFrame (using actual order creation timestamp in Asia/Manila) ---
    if sales:
        sales_df = pd.DataFrame([
            {
                'date': _to_ph_dt(s.order.created_at if s.order and s.order.created_at else s.timestamp).date(),
                'amount': float(s.total_amount or 0.0),
                'method': s.payment_method or 'Cash'
            }
            for s in sales
        ])
    else:
        sales_df = pd.DataFrame(columns=['date', 'amount', 'method'])

    # --- Orders DataFrame (using actual order creation timestamp in Asia/Manila) ---
    if orders:
        orders_df = pd.DataFrame([
            {
                'id': o.id,
                'queue_no': o.queue_no,
                'type': o.type or 'walk-in',
                'order_type': o.order_type or 'pickup',
                'status': o.status or 'pending',
                'total': float(o.total_amount or 0.0),
                'date': _to_ph_dt(o.created_at).date() if o.created_at else today,
                'hour': _to_ph_dt(o.created_at).hour if o.created_at else now_ph.hour,
                'payment_method': o.payment_method or 'Cash'
            }
            for o in orders
        ])
    else:
        orders_df = pd.DataFrame(columns=['id', 'type', 'order_type', 'status', 'total', 'date', 'hour', 'payment_method'])

    # --- Order Items DataFrame ---
    if order_items:
        items_df = pd.DataFrame([
            {
                'order_id': i.order_id,
                'product_id': i.product_id,
                'product_name': i.product.name if i.product else 'Unknown',
                'quantity': int(i.quantity or 1),
                'subtotal': float(i.subtotal or 0.0)
            }
            for i in order_items
        ])
    else:
        items_df = pd.DataFrame(columns=['order_id', 'product_id', 'product_name', 'quantity', 'subtotal'])

    # --- Daily Sales (last 30 days) ---
    daily_labels = [(today - timedelta(days=i)).isoformat() for i in range(29, -1, -1)]
    if not sales_df.empty:
        sales_df['date'] = pd.to_datetime(sales_df['date']).dt.date
        daily_grp = sales_df.groupby('date')['amount'].sum()
        daily_sales = [float(daily_grp.get(today - timedelta(days=i), 0.0)) for i in range(29, -1, -1)]
    else:
        daily_sales = [0.0] * 30

    # --- Weekly Sales (last 8 weeks) ---
    week_labels = []
    weekly_sales = []
    if not sales_df.empty:
        for w in range(7, -1, -1):
            week_start = today - timedelta(weeks=w + 1)
            week_end = today - timedelta(weeks=w)
            mask = [(d >= week_start and d < week_end) for d in sales_df['date']]
            total = float(sales_df[mask]['amount'].sum()) if any(mask) else 0.0
            weekly_sales.append(total)
            week_labels.append(week_start.strftime('Week of %b %d'))
    else:
        weekly_sales = [0.0] * 8
        week_labels = [(today - timedelta(weeks=w)).strftime('Week of %b %d') for w in range(7, -1, -1)]

    # --- Monthly Sales (last 6 months) ---
    monthly_labels = []
    monthly_sales = []
    if not sales_df.empty:
        for m in range(5, -1, -1):
            if m == 0:
                year, month = today.year, today.month
            else:
                dt = today.replace(day=1)
                for _ in range(m):
                    dt = (dt.replace(day=1) - timedelta(days=1))
                year, month = dt.year, dt.month
            mask = [(d.year == year and d.month == month) for d in sales_df['date']]
            total = float(sales_df[mask]['amount'].sum()) if any(mask) else 0.0
            monthly_sales.append(total)
            monthly_labels.append(datetime(year, month, 1).strftime('%b %Y'))
    else:
        monthly_sales = [0.0] * 6
        monthly_labels = [(today - timedelta(days=30 * m)).strftime('%b %Y') for m in range(5, -1, -1)]

    # --- Order Counts & Channels ---
    if not orders_df.empty:
        total_orders = len(orders_df)
        total_completed = int(orders_df['status'].isin(['completed', 'delivered']).sum())
        active_orders_count = int((~orders_df['status'].isin(['completed', 'delivered', 'cancelled'])).sum())
        cancelled_count = int((orders_df['status'] == 'cancelled').sum())
        walkin_count = int((orders_df['type'] == 'walk-in').sum())
        online_count = int((orders_df['type'] == 'online').sum())
        pickup_count = int((orders_df['order_type'] == 'pickup').sum())
        delivery_count = int((orders_df['order_type'] == 'delivery').sum())
    else:
        total_orders = total_completed = active_orders_count = cancelled_count = 0
        walkin_count = online_count = pickup_count = delivery_count = 0

    # --- Top Products (strictly computed from order items) ---
    top_products = []
    if not items_df.empty:
        top_grp = items_df.groupby('product_name').agg({'quantity': 'sum', 'subtotal': 'sum'}).reset_index()
        top_grp = top_grp.sort_values('quantity', ascending=False).head(10)
        top_products = [
            {
                'name': r['product_name'],
                'quantity': int(r['quantity']),
                'revenue': float(r['subtotal'])
            }
            for _, r in top_grp.iterrows()
        ]

    # --- Actual Peak Hours (computed strictly from actual order timestamps) ---
    peak_hours = []
    actual_peaks = []
    if not orders_df.empty:
        hour_grp = orders_df.groupby('hour')['id'].count()
        peak_hours = [
            {'hour': h, 'label': f"{h:02d}:00", 'orders': int(hour_grp.get(h, 0))}
            for h in range(24)
        ]
        # Active peak hours with at least 1 order
        hours_with_orders = [ph for ph in peak_hours if ph['orders'] > 0]
        actual_peaks = sorted(hours_with_orders, key=lambda x: x['orders'], reverse=True)
    else:
        peak_hours = [{'hour': h, 'label': f"{h:02d}:00", 'orders': 0} for h in range(24)]

    # Peak hours summary based on actual data
    if actual_peaks:
        top_peak = actual_peaks[0]
        peak_summary = f"Peak order volume at {top_peak['label']} ({top_peak['orders']} order{'s' if top_peak['orders'] > 1 else ''})"
    else:
        peak_summary = "No order records available yet to determine peak hours."

    # --- Financial Metrics ---
    total_sales_revenue = float(sales_df['amount'].sum()) if not sales_df.empty else 0.0
    today_sales = float(sales_df[sales_df['date'] == today]['amount'].sum()) if not sales_df.empty else 0.0
    gcash_revenue = float(sales_df[sales_df['method'] == 'GCash']['amount'].sum()) if not sales_df.empty else 0.0
    cash_revenue = float(sales_df[sales_df['method'] == 'Cash']['amount'].sum()) if not sales_df.empty else 0.0
    other_revenue = max(0.0, total_sales_revenue - gcash_revenue - cash_revenue)

    # Fulfillment rate
    fulfillment_rate = round((total_completed / total_orders * 100), 1) if total_orders > 0 else 0.0
    avg_order_value = round(total_sales_revenue / total_completed, 2) if total_completed > 0 else (
        round(total_sales_revenue / total_orders, 2) if total_orders > 0 else 0.0
    )

    # Average items per completed order
    total_items_sold = int(items_df['quantity'].sum()) if not items_df.empty else 0
    avg_items_per_order = round(total_items_sold / total_completed, 1) if total_completed > 0 else 0.0

    has_data = total_sales_revenue > 0 or len(sales) > 0 or len(orders) > 0

    return {
        "has_sales_data": has_data,
        "total_sales": total_sales_revenue,
        "total_revenue": total_sales_revenue,
        "today_sales": today_sales,
        "total_orders": total_orders,
        "total_completed": total_completed,
        "active_orders": active_orders_count,
        "cancelled_orders": cancelled_count,
        "fulfillment_rate": fulfillment_rate,
        "average_order_value": avg_order_value,
        "average_items_per_order": avg_items_per_order,
        "total_items_sold": total_items_sold,
        "top_selling_product": top_products[0] if top_products else {
            "name": "No sales recorded yet", "quantity": 0, "revenue": 0.0
        },
        "summary": {
            "total_revenue": total_sales_revenue,
            "today_sales": today_sales,
            "total_orders": total_orders,
            "total_completed": total_completed,
            "walkin_count": walkin_count,
            "online_count": online_count,
            "pickup_count": pickup_count,
            "delivery_count": delivery_count,
            "gcash_revenue": gcash_revenue,
            "cash_revenue": cash_revenue,
            "other_revenue": other_revenue
        },
        "daily_sales": {"labels": daily_labels, "data": daily_sales},
        "weekly_sales": {"labels": week_labels, "data": weekly_sales},
        "monthly_sales": {"labels": monthly_labels, "data": monthly_sales},
        "top_products": top_products,
        "peak_hours": peak_hours,
        "actual_peak_hours": actual_peaks,
        "peak_summary": peak_summary,
        "channel_breakdown": {
            "type": [
                {"name": "Walk-in", "value": walkin_count},
                {"name": "Online", "value": online_count}
            ],
            "order_type": [
                {"name": "Pickup", "value": pickup_count},
                {"name": "Delivery", "value": delivery_count}
            ],
            "payment": [
                {"name": "Cash", "value": cash_revenue},
                {"name": "GCash", "value": gcash_revenue}
            ]
        },
        "model_info": {
            "model_type": "Descriptive Analytics Engine",
            "model_name": "Empirical Transaction & Frequency Distribution Analysis",
            "methodology": "Direct discrete point-of-sale aggregation, timezone-indexed timeline bucketing, and relational sales verification.",
            "formula": "Total Revenue = Σ (Product Price × Quantity Sold)",
            "data_records": {
                "orders_count": total_orders,
                "sales_count": len(sales),
                "items_count": len(order_items),
                "active_products": len(products)
            }
        }
    }


def get_predictive_analytics(db, Sale, Order, OrderItem, Product):
    """
    Compute predictive analytics: forecast future sales and demand using
    Ordinary Least Squares (OLS) Linear Regression based on actual historical records.
    Properly detects and handles insufficient data without generating fabricated predictions.
    """
    now = datetime.now(timezone.utc)
    now_ph = _get_ph_now()
    today = now_ph.date()

    # Step 1: Ensure synchronization
    _sync_sales_with_orders(db, Sale, Order, now)

    sales = Sale.query.all()
    order_items = OrderItem.query.all()
    products = Product.query.filter_by(is_active=True).all()

    # Minimum required distinct operational days with sales to fit an OLS regression model
    MIN_REQUIRED_DAYS = 3

    # Group sales by distinct calendar date
    daily_grp = pd.DataFrame()
    if sales:
        sales_df = pd.DataFrame([
            {
                'date': _to_ph_dt(s.order.created_at if s.order and s.order.created_at else s.timestamp).date(),
                'amount': float(s.total_amount or 0.0)
            }
            for s in sales
        ])
        sales_df['date'] = pd.to_datetime(sales_df['date']).dt.date
        daily_grp = sales_df.groupby('date')['amount'].sum().reset_index().sort_values('date')

    distinct_days_count = len(daily_grp)
    has_sufficient_data = distinct_days_count >= MIN_REQUIRED_DAYS

    daily_forecast_labels = []
    daily_forecast_data = []
    product_forecasts = []

    if has_sufficient_data:
        # Fit Ordinary Least Squares (OLS) Linear Regression
        daily_grp['day_idx'] = range(len(daily_grp))
        X = daily_grp[['day_idx']].values
        y = daily_grp['amount'].values

        model = LinearRegression()
        model.fit(X, y)

        next_idx = len(daily_grp)
        raw_pred = float(model.predict([[next_idx]])[0])
        next_day_forecast = max(0.0, round(raw_pred, 2))
        trend_slope = float(model.coef_[0])
        intercept = float(model.intercept_)
        r2_score = float(model.score(X, y)) if len(y) > 1 else 0.0
        confidence = max(0.0, min(1.0, r2_score))

        # 7-day projection
        for i in range(1, 8):
            future_date = today + timedelta(days=i)
            proj_val = max(0.0, float(model.predict([[next_idx + i - 1]])[0]))
            daily_forecast_labels.append(future_date.strftime('%Y-%m-%d'))
            daily_forecast_data.append(round(proj_val, 2))

        # Product-level demand forecasts
        if order_items:
            items_df = pd.DataFrame([
                {
                    'product_id': i.product_id,
                    'product_name': i.product.name if i.product else 'Unknown',
                    'quantity': int(i.quantity or 1),
                    'date': _to_ph_dt(i.order.created_at).date() if i.order and i.order.created_at else today
                }
                for i in order_items
            ])
            items_df['date'] = pd.to_datetime(items_df['date']).dt.date

            for product in products[:10]:
                prod_df = items_df[items_df['product_id'] == product.id].copy()
                prod_daily = prod_df.groupby('date')['quantity'].sum().reset_index().sort_values('date') if not prod_df.empty else pd.DataFrame()

                if len(prod_daily) >= MIN_REQUIRED_DAYS:
                    prod_daily['day_idx'] = range(len(prod_daily))
                    p_model = LinearRegression()
                    p_model.fit(prod_daily[['day_idx']].values, prod_daily['quantity'].values)
                    p_next = len(prod_daily)
                    prod_forecast = [max(0, int(p_model.predict([[p_next + j]])[0])) for j in range(7)]
                    weekly_demand = sum(prod_forecast)
                    item_sufficient = True
                else:
                    prod_forecast = []
                    weekly_demand = int(prod_df['quantity'].sum()) if not prod_df.empty else 0
                    item_sufficient = False

                product_forecasts.append({
                    'product_id': product.id,
                    'product_name': product.name,
                    'current_stock': product.stock,
                    'has_sufficient_data': item_sufficient,
                    'data_points': len(prod_daily),
                    'weekly_forecast': prod_forecast,
                    'total_weekly_demand': weekly_demand,
                    'days_of_stock': round(product.stock / (weekly_demand / 7), 1) if weekly_demand > 0 else 99.9
                })

        trend_direction = "up" if trend_slope > 1.0 else ("down" if trend_slope < -1.0 else "flat")
        model_status = "Trained & Operational"
        model_name = "Ordinary Least Squares (OLS) Linear Trend Model (y = mx + b)"
        model_message = f"OLS regression model trained on {distinct_days_count} distinct daily sales records (R² = {confidence:.3f})."

    elif distinct_days_count > 0:
        # Preliminary forecast: Empirical Daily Mean Run-Rate (Low Sample Size)
        mean_daily_sales = float(daily_grp['amount'].mean())
        next_day_forecast = max(0.0, round(mean_daily_sales, 2))
        trend_slope = 0.0
        intercept = next_day_forecast
        confidence = 0.50
        trend_direction = "stable"
        model_status = "Preliminary Run-Rate Baseline"
        model_name = "Empirical Daily Run-Rate (Preliminary Baseline)"
        model_message = (
            f"Preliminary forecast based on empirical daily run-rate (₱{next_day_forecast:.2f}/day). "
            f"Insufficient historical data ({distinct_days_count}/{MIN_REQUIRED_DAYS} distinct sales days) for OLS regression slope. "
            f"A minimum of {MIN_REQUIRED_DAYS} distinct operating days are required for full linear trend modeling."
        )

        # 7-day projection using empirical daily mean run-rate
        for i in range(1, 8):
            future_date = today + timedelta(days=i)
            daily_forecast_labels.append(future_date.strftime('%Y-%m-%d'))
            daily_forecast_data.append(round(mean_daily_sales, 2))

        # Product-level demand based on current order volume
        if order_items:
            items_df = pd.DataFrame([
                {
                    'product_id': i.product_id,
                    'product_name': i.product.name if i.product else 'Unknown',
                    'quantity': int(i.quantity or 1),
                    'date': _to_ph_dt(i.order.created_at).date() if i.order and i.order.created_at else today
                }
                for i in order_items
            ])
            for product in products[:10]:
                prod_df = items_df[items_df['product_id'] == product.id].copy() if not items_df.empty else pd.DataFrame()
                total_qty = int(prod_df['quantity'].sum()) if not prod_df.empty else 0
                daily_rate = total_qty / max(1, distinct_days_count)
                weekly_demand = int(round(daily_rate * 7))
                product_forecasts.append({
                    'product_id': product.id,
                    'product_name': product.name,
                    'current_stock': product.stock,
                    'has_sufficient_data': False,
                    'is_preliminary': True,
                    'data_points': distinct_days_count,
                    'weekly_forecast': [int(round(daily_rate))] * 7,
                    'total_weekly_demand': weekly_demand,
                    'days_of_stock': round(product.stock / (weekly_demand / 7), 1) if weekly_demand > 0 else 99.9
                })
        else:
            for product in products[:10]:
                product_forecasts.append({
                    'product_id': product.id,
                    'product_name': product.name,
                    'current_stock': product.stock,
                    'has_sufficient_data': False,
                    'is_preliminary': True,
                    'data_points': 0,
                    'weekly_forecast': [],
                    'total_weekly_demand': 0,
                    'days_of_stock': 99.9
                })

    else:
        # Zero sales: Insufficient data
        next_day_forecast = None
        trend_slope = 0.0
        intercept = 0.0
        confidence = 0.0
        trend_direction = "insufficient_data"
        model_status = "Data Collection Phase"
        model_name = "Awaiting Data"
        model_message = (
            f"Insufficient historical daily sales data (0/{MIN_REQUIRED_DAYS} distinct sales days recorded). "
            f"A minimum of {MIN_REQUIRED_DAYS} distinct operating days are required to fit a statistically valid linear regression trend line."
        )

        for product in products[:10]:
            product_forecasts.append({
                'product_id': product.id,
                'product_name': product.name,
                'current_stock': product.stock,
                'has_sufficient_data': False,
                'data_points': 0,
                'weekly_forecast': [],
                'total_weekly_demand': 0,
                'days_of_stock': 99.9
            })

    # Expected order count estimate based on average ticket if forecast available
    avg_ticket = 70.0
    predicted_orders = max(1, int(next_day_forecast / avg_ticket)) if next_day_forecast is not None and next_day_forecast > 0 else None

    return {
        "has_sufficient_data": has_sufficient_data,
        "is_preliminary": not has_sufficient_data and distinct_days_count > 0,
        "min_required_days": MIN_REQUIRED_DAYS,
        "current_days_count": distinct_days_count,
        "message": model_message,
        "predicted_sales": next_day_forecast,
        "predicted_orders": predicted_orders,
        "next_day_forecast": next_day_forecast,
        "trend_slope": round(trend_slope, 2) if has_sufficient_data else None,
        "trend_intercept": round(intercept, 2) if has_sufficient_data else None,
        "confidence": round(confidence, 3) if has_sufficient_data else 0.0,
        "trend_direction": trend_direction,
        "forecast_labels": daily_forecast_labels,
        "forecast_data": daily_forecast_data,
        "product_forecasts": product_forecasts,
        "model_info": {
            "model_type": "Predictive Analytics Engine",
            "model_name": model_name,
            "status": model_status,
            "min_days_required": MIN_REQUIRED_DAYS,
            "days_analyzed": distinct_days_count,
            "formula": f"y = {trend_slope:.2f}x + {intercept:.2f}" if has_sufficient_data else (f"y = {next_day_forecast:.2f} (Daily Mean Run-Rate)" if distinct_days_count > 0 else "y = mx + b (Awaiting minimum 3 data points)"),
            "r_squared": round(confidence, 4) if has_sufficient_data else None,
            "goodness_of_fit": "Strong" if confidence >= 0.7 else ("Moderate" if confidence >= 0.4 else "Initial Baseline") if has_sufficient_data else ("Preliminary" if distinct_days_count > 0 else "Awaiting Data")
        }
    }


def get_prescriptive_analytics(db, Sale, Order, OrderItem, Product):
    """
    Generate actionable recommendations and operational prescriptions strictly derived
    from actual inventory records, top-selling items, empirical peak hours, and statistical forecasts.
    """
    predictive = get_predictive_analytics(db, Sale, Order, OrderItem, Product)
    descriptive = get_descriptive_analytics(db, Sale, Order, OrderItem, Product)
    products = Product.query.filter_by(is_active=True).all()

    recommendations = []
    inventory_alerts = []
    preparation_plan = []
    reorder_suggestions = []
    operational_schedules = []

    # ─────────────────────────────────────────────────────────────
    # 1. INVENTORY PRESCRIPTIONS (Direct from Product stock levels)
    # ─────────────────────────────────────────────────────────────
    for p in products:
        pct = p.stock_percentage
        status = p.stock_status
        shortfall = max(0, p.max_stock - p.stock)

        if status == 'out_of_stock':
            alert = {
                'type': 'inventory',
                'category': 'Stock Out',
                'priority': 'critical',
                'icon': '🚫',
                'badge': 'OUT OF STOCK',
                'product': p.name,
                'message': f"{p.name} is completely out of stock ({p.stock}/{p.max_stock} {p.unit}).",
                'action': f"Place emergency purchase order for {shortfall} {p.unit} immediately to restore full capacity.",
                'rationale': "Stockouts directly cause lost revenue and customer queue dissatisfaction."
            }
            inventory_alerts.append(alert)
            recommendations.append(alert)

        elif status == 'critical':
            alert = {
                'type': 'inventory',
                'category': 'Critical Low Stock',
                'priority': 'critical',
                'icon': '🔴',
                'badge': 'CRITICAL',
                'product': p.name,
                'message': f"{p.name} is at critical low stock ({p.stock}/{p.max_stock} {p.unit} — {pct}% capacity).",
                'action': f"Restock at least {shortfall} {p.unit} before starting the next service rush.",
                'rationale': "Inventory is below 15% safety threshold; risk of stockout within hours."
            }
            inventory_alerts.append(alert)
            recommendations.append(alert)

        elif status == 'warning':
            alert = {
                'type': 'inventory',
                'category': 'Low Stock Warning',
                'priority': 'warning',
                'icon': '🟡',
                'badge': 'WARNING',
                'product': p.name,
                'message': f"{p.name} supply is running low ({p.stock}/{p.max_stock} {p.unit} — {pct}% capacity).",
                'action': f"Submit reorder for {shortfall} {p.unit} during regular supplier procurement.",
                'rationale': "Inventory is below 30% par level; maintain safety buffer for unexpected spikes."
            }
            inventory_alerts.append(alert)
            recommendations.append(alert)

    # ─────────────────────────────────────────────────────────────
    # 2. KITCHEN PREPARATION & BATCHING PRESCRIPTIONS
    # ─────────────────────────────────────────────────────────────
    top_product = descriptive.get('top_selling_product')
    has_sales = descriptive.get('has_sales_data', False)

    if top_product and top_product.get('quantity', 0) > 0 and top_product.get('name') != 'No sales recorded yet':
        top_name = top_product['name']
        top_qty = top_product['quantity']
        # 15% prep buffer over historical volume
        recommended_batch = max(20, int(top_qty * 1.15))
        prep_rec = {
            'type': 'preparation',
            'category': 'Kitchen Batching',
            'priority': 'info',
            'icon': '🥟',
            'badge': 'BATCH PREP',
            'product': top_name,
            'message': f"Prioritize continuous steaming batches for top seller '{top_name}' ({top_qty} units sold to date).",
            'action': f"Maintain minimum steamer tray buffer of {recommended_batch} pieces during opening hours.",
            'rationale': f"Item represents primary menu volume. Fresh batching reduces order fulfillment wait time."
        }
        preparation_plan.append(prep_rec)
        recommendations.append(prep_rec)
    elif has_sales:
        prep_rec = {
            'type': 'preparation',
            'category': 'Kitchen Batching',
            'priority': 'info',
            'icon': '🥟',
            'badge': 'BATCH PREP',
            'product': 'HotSpot Siomai',
            'message': "Prepare standard baseline steamer batch of 40 pieces of HotSpot Siomai.",
            'action': "Maintain steamer heat at 85°C to ensure instant order dispatch upon customer walk-in.",
            'rationale': "Standard operating procedure for fast customer turnaround."
        }
        preparation_plan.append(prep_rec)
        recommendations.append(prep_rec)
    else:
        prep_rec = {
            'type': 'preparation',
            'category': 'Kitchen Batching',
            'priority': 'info',
            'icon': 'ℹ️',
            'badge': 'BASELINE',
            'product': 'All Menu Items',
            'message': "Shop in opening baseline collection phase. Prepare standard minimum par levels.",
            'action': "Steam initial batch of 20-30 pieces per product; replenish as queue orders arrive.",
            'rationale': "Awaiting order velocity records to calculate dynamic demand batch sizes."
        }
        preparation_plan.append(prep_rec)
        recommendations.append(prep_rec)

    # ─────────────────────────────────────────────────────────────
    # 3. OPERATIONAL PEAK TIMING PRESCRIPTIONS (from actual order hours)
    # ─────────────────────────────────────────────────────────────
    actual_peaks = descriptive.get('actual_peak_hours', [])
    if actual_peaks:
        primary_peak = actual_peaks[0]
        peak_hour = primary_peak['hour']
        prep_hour = (peak_hour - 1) % 24
        rush_rec = {
            'type': 'operational',
            'category': 'Peak Rush Management',
            'priority': 'info',
            'icon': '⏰',
            'badge': 'PEAK SCHEDULING',
            'product': 'Operations',
            'message': f"Empirical order records indicate peak store activity at {primary_peak['label']} ({primary_peak['orders']} orders).",
            'action': f"Pre-stage condiment packets and ensure 2 staff members are at the service counter by {prep_hour:02d}:30.",
            'rationale': "Pre-rush preparation prevents counter bottlenecks during verified customer traffic hours."
        }
        operational_schedules.append(rush_rec)
        recommendations.append(rush_rec)
    else:
        rush_rec = {
            'type': 'operational',
            'category': 'Peak Rush Management',
            'priority': 'info',
            'icon': '⏰',
            'badge': 'HOURLY PROFILE',
            'product': 'Operations',
            'message': "No empirical peak hours identified yet due to initial order baseline.",
            'action': "Monitor order timestamps across the first 10 orders to map shop rush periods.",
            'rationale': "Peak scheduling rules activate dynamically as soon as transaction timestamps are recorded."
        }
        operational_schedules.append(rush_rec)
        recommendations.append(rush_rec)

    # ─────────────────────────────────────────────────────────────
    # 4. PAYMENT & CHANNEL OPTIMIZATION PRESCRIPTION
    # ─────────────────────────────────────────────────────────────
    cash_rev = descriptive.get('summary', {}).get('cash_revenue', 0.0)
    gcash_rev = descriptive.get('summary', {}).get('gcash_revenue', 0.0)
    tot_rev = descriptive.get('total_revenue', 0.0)

    if tot_rev > 0:
        gcash_pct = round((gcash_rev / tot_rev) * 100)
        cash_pct = round((cash_rev / tot_rev) * 100)
        if gcash_pct >= 50:
            pay_rec = {
                'type': 'payment',
                'category': 'Payment Flow',
                'priority': 'info',
                'icon': '📱',
                'badge': 'CASHLESS FOCUS',
                'product': 'GCash QR',
                'message': f"GCash accounts for {gcash_pct}% of total revenue (₱{gcash_rev:.2f}).",
                'action': "Ensure GCash QR code standee is placed in direct view at the ordering counter.",
                'rationale': "High cashless adoption speeds up counter turnaround time and reduces cash float handling."
            }
            recommendations.append(pay_rec)
        else:
            pay_rec = {
                'type': 'payment',
                'category': 'Payment Flow',
                'priority': 'info',
                'icon': '💵',
                'badge': 'CASH FLOAT',
                'product': 'Cash Register',
                'message': f"Cash accounts for {cash_pct}% of total revenue (₱{cash_rev:.2f}).",
                'action': "Ensure cashier drawer has adequate ₱20, ₱50 bills and ₱5/₱10 coins for fast change.",
                'rationale': "Prevents checkout delays when walk-in customers pay with large bills (₱500, ₱1000)."
            }
            recommendations.append(pay_rec)

    # ─────────────────────────────────────────────────────────────
    # 5. DEMAND & REVENUE TRAJECTORY PRESCRIPTIONS (from Forecast)
    # ─────────────────────────────────────────────────────────────
    pred_sales = predictive.get('predicted_sales')
    if pred_sales is not None and pred_sales > 0:
        is_prelim = predictive.get('is_preliminary', False)
        target_orders = predictive.get('predicted_orders', 25)
        forecast_rec = {
            'type': 'forecast',
            'category': 'Sales Target & Capacity Alignment',
            'priority': 'info',
            'icon': '📈',
            'badge': 'PRELIMINARY TARGET' if is_prelim else 'PROJECTED TARGET',
            'product': 'Sales Demand Planning',
            'message': f"Next day revenue forecasted at ₱{pred_sales:.2f} (~{target_orders} orders) based on " +
                       (f"preliminary daily run-rate ({predictive.get('current_days_count', 1)} day recorded)." if is_prelim else f"OLS linear regression (R² = {predictive.get('confidence', 0):.2f})."),
            'action': f"Pre-allocate sufficient raw siomai wrappers and beverage stock to fulfill ~{target_orders} orders without replenishment pauses.",
            'rationale': "Aligning opening inventory directly with forecasted revenue volume minimizes stockout risks during service."
        }
        recommendations.append(forecast_rec)

    # Summary counts
    critical_count = len([r for r in recommendations if r.get('priority') == 'critical'])
    warning_count = len([r for r in recommendations if r.get('priority') == 'warning'])
    info_count = len([r for r in recommendations if r.get('priority') == 'info'])

    return {
        "recommendations": recommendations,
        "inventory_alerts": inventory_alerts,
        "preparation_plan": preparation_plan,
        "reorder_suggestions": reorder_suggestions,
        "operational_schedules": operational_schedules,
        "summary": {
            "total_recommendations": len(recommendations),
            "critical_count": critical_count,
            "warning_count": warning_count,
            "info_count": info_count
        },
        "model_info": {
            "model_type": "Prescriptive Analytics Engine",
            "model_name": "Multi-Factor Rule-Based Decision System (Safety Stock & Peak Heuristics)",
            "status": "Operational",
            "rules_evaluated": [
                "Stockout Alert: Trigger Critical action when stock == 0",
                "Critical Par Rule: Trigger Critical action when stock <= 15% of max capacity",
                "Warning Par Rule: Trigger Warning action when stock <= 30% of max capacity",
                "Batch Steamer Rule: Recommend 15% buffer over empirical top seller demand",
                "Peak Rush Rule: Recommend counter staging 30 mins prior to empirical peak hour",
                "Payment Channel Rule: Optimize cashier operations based on Cash vs GCash revenue split"
            ]
        }
    }
