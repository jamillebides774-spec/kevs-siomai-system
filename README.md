# 🥟 KEVS Siomai — Integrated Order Management System

A full-stack, real-time order management system for **KEVS Siomai** featuring:
- **Unified Queue Dashboard** with Socket.IO real-time updates
- **ESP32 + OLED Hardware Integration** (walk-in queue buttons)
- **Online Mobile Customer Orders** (Pickup & Delivery)
- **Offline PWA Mode** (IndexedDB + auto-sync)
- **Descriptive / Predictive / Prescriptive Analytics** (Pandas + Scikit-learn)
- **Mock GCash Payment Integration**
- **Interactive Hardware & Mobile App Simulators**

---

## 📁 Project Structure

```
BOSS KEVS/
├── backend/
│   ├── venv/                  # Python virtual environment
│   ├── app.py                 # Flask app factory + Socket.IO + seed data
│   ├── models.py              # SQLAlchemy database models
│   ├── routes.py              # All REST API endpoints
│   ├── analytics.py           # Pandas/Scikit-learn analytics engine
│   ├── requirements.txt       # Python dependencies
│   ├── .env                   # Environment variables
│   ├── simulate_esp32.py      # CLI ESP32 button simulator
│   └── simulate_mobile.py     # CLI mobile app order simulator
└── frontend/
    ├── public/
    │   ├── manifest.webmanifest  # PWA manifest
    │   └── sw.js                 # Service Worker (offline caching)
    ├── src/
    │   ├── components/
    │   │   ├── Navbar.jsx          # Navigation + live queue status
    │   │   ├── QueueDashboard.jsx  # Unified queue with real-time updates
    │   │   ├── OrderModal.jsx      # Order detail + status workflow
    │   │   ├── OfflineOrderModal.jsx # Walk-in order (online/offline)
    │   │   ├── InventoryView.jsx   # Product CRUD + stock alerts
    │   │   ├── AnalyticsView.jsx   # All 3 analytics dashboards
    │   │   ├── HardwareSimulator.jsx # Virtual ESP32 + Mobile App
    │   │   ├── LoginPage.jsx
    │   │   └── Toast.jsx
    │   ├── services/
    │   │   ├── api.js          # Axios API service
    │   │   ├── indexedDb.js    # IndexedDB offline storage
    │   │   └── syncManager.js  # Network detection + auto-sync
    │   ├── App.jsx             # Root component (auth, socket, offline)
    │   ├── main.jsx
    │   └── index.css           # Tailwind + custom design system
    ├── index.html
    ├── vite.config.js
    ├── tailwind.config.js
    └── postcss.config.js
```

---

## ⚡ One-Click Start (Easiest Way)

You can launch the **entire system (Backend + Frontend + Real-Time Sockets) and open the website automatically** in one step:

### Option A: Double-Click (Windows)
Just double-click **[`start.bat`](file:///c:/Users/User/Desktop/BOSS%20KEVS/start.bat)** in the project root folder.

### Option B: Terminal Command
```bash
# From the project root folder:
python app.py
```
> This starts the unified server at **`http://localhost:5000`** and **automatically opens your web browser to the website!**
> 
> **Admin Login:** `admin` / `kevs2024`

### For Frontend Development (Hot Reloading):
```bash
python app.py --dev
```
> Starts Flask on port 5000 and Vite dev server on `http://localhost:5173` with instant HMR.

---

### 1. Backend Setup

```bash
# Navigate to backend folder
cd "BOSS KEVS/backend"

# Activate virtual environment
# Windows:
venv\Scripts\activate
# Mac/Linux:
source venv/bin/activate

# Install dependencies (already done if setup was run)
pip install -r requirements.txt

# Start the Flask server
python app.py
```

**Backend runs at:** `http://localhost:5000`

The database (`kevs_siomai.db`) is auto-created with:
- ✅ Admin user: `admin` / `kevs2024`
- ✅ 12 sample products (Siomai, Dumplings, Sauces, Drinks, Rice)
- ✅ 30 days of historical orders & sales for analytics

---

### 2. Frontend Setup

```bash
# Open a new terminal, navigate to frontend
cd "BOSS KEVS/frontend"

# Install dependencies
npm install

# Start the Vite dev server
npm run dev
```

**Frontend runs at:** `http://localhost:5173`

---

### 3. Login

Open `http://localhost:5173` and log in with:
- **Username:** `admin`
- **Password:** `kevs2024`

---

## 🔧 Hardware Simulators (CLI)

### Simulate ESP32 Button Press

```bash
cd "BOSS KEVS/backend"
venv\Scripts\activate    # Windows
python simulate_esp32.py

# Auto-press button 5 times:
python simulate_esp32.py --auto 5
```

### Simulate Mobile Customer Order + GCash Payment

```bash
python simulate_mobile.py
# Follow the interactive menu
```

---

## 📡 API Endpoints Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/auth/login` | Admin login |
| `GET` | `/api/queue` | Get active queue + orders |
| `POST` | `/api/queue/add` | **ESP32** adds walk-in to queue |
| `GET` | `/api/queue/display` | **ESP32 OLED** polling |
| `POST` | `/api/queue/reset` | Reset daily queue counter |
| `GET` | `/api/products` | List products |
| `POST` | `/api/products` | Create product |
| `PUT` | `/api/products/<id>` | Update product |
| `PUT` | `/api/inventory/<id>` | Update stock level |
| `POST` | `/api/orders` | **Mobile app** places order |
| `PUT` | `/api/orders/<id>` | Update order status (triggers inventory decrease on `accepted`) |
| `POST` | `/api/payments/gcash` | Initiate mock GCash payment |
| `POST` | `/api/payments/gcash/callback` | **Mock GCash webhook** |
| `PUT` | `/api/payments/confirm/<id>` | Admin confirms payment |
| `GET` | `/api/analytics/descriptive` | Sales trends, top products, peak hours |
| `GET` | `/api/analytics/predictive` | 7-day sales & demand forecast |
| `GET` | `/api/analytics/prescriptive` | Restock & prep recommendations |
| `POST` | `/api/offline/sync` | **PWA** syncs offline orders |
| `GET` | `/api/dashboard/stats` | Dashboard summary KPIs |

---

## 🔴 Order Status Workflow

```
Walk-in / Online Pickup:
  pending → accepted → preparing → ready_pickup → completed

Online Delivery:
  pending → accepted → preparing → ready_delivery → out_for_delivery → delivered
```

> ⚡ **On `accepted`:** Stock automatically decreases for all order items.  
> ⚡ **On `completed`/`delivered`:** Sale is recorded and queue `now_serving` increments.

---

## 📊 Analytics Details

### Descriptive
- Daily / Weekly / Monthly revenue charts (30 days historical data)
- Walk-in vs Online breakdown (pie chart)
- Pickup vs Delivery distribution
- Top 8 best-selling products (bar chart)
- Peak hours heatmap (hourly order density)

### Predictive
- Next-day revenue forecast (Linear Regression via Scikit-learn)
- 7-day product demand projection per product
- Trend direction (up/down/flat) and R² confidence score

### Prescriptive
- 🔴 Critical inventory alerts (stock ≤ 10%)
- 🟡 Low stock warnings (stock ≤ 20%)
- 📦 Reorder suggestions (items with <3 days of stock)
- 🍤 Batch preparation recommendations (+20% buffer above forecast)
- ⏰ Daily peak-hour operation schedule

---

## 📲 PWA Offline Mode

1. The Admin Web App is a **Progressive Web App (PWA)**.
2. When internet drops, an offline banner appears automatically.
3. Walk-in orders can still be created — stored in **IndexedDB**.
4. When internet returns, offline orders **auto-sync** to the Flask backend via `POST /api/offline/sync`.
5. Manual sync can be triggered via the **sync button** in the navbar (shows pending count badge).

---

## 🗄️ Database Models

| Model | Key Fields |
|-------|-----------|
| `User` | id, username, password_hash, role |
| `Product` | id, name, category, price, stock, max_stock, unit, is_active |
| `Order` | id, queue_no, type, order_type, status, payment_status, total_amount |
| `OrderItem` | id, order_id, product_id, quantity, unit_price, subtotal |
| `Sale` | id, order_id, total_amount, payment_method, timestamp |
| `Queue` | id, current_queue_no, now_serving |
| `OfflineSyncLog` | id, batch_id, orders_synced, timestamp |

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| **Backend** | Python 3.14, Flask 3, Flask-SocketIO 5, Flask-SQLAlchemy |
| **Database** | SQLite (dev) / PostgreSQL (prod via `DATABASE_URL`) |
| **Analytics** | Pandas, NumPy, Scikit-learn (LinearRegression) |
| **Frontend** | React 18, Vite, Tailwind CSS 3 |
| **Real-time** | Socket.IO (Flask-SocketIO + socket.io-client) |
| **Charts** | Recharts |
| **Icons** | Lucide React |
| **Offline** | Service Worker + IndexedDB |
| **HTTP Client** | Axios |

---

## 🐘 PostgreSQL (Production)

Set the `DATABASE_URL` in `backend/.env`:

```env
DATABASE_URL=postgresql://user:password@localhost:5432/kevs_siomai
```

Install psycopg2:
```bash
pip install psycopg2-binary
```

---

## 🔌 ESP32 Arduino Integration

Point your ESP32 firmware to:

```cpp
// Button press → POST /api/queue/add
const char* serverUrl = "http://YOUR_PC_IP:5000/api/queue/add";

// OLED refresh → GET /api/queue/display
const char* displayUrl = "http://YOUR_PC_IP:5000/api/queue/display";
```

---

## 📦 Build for Production

```bash
cd "BOSS KEVS/frontend"
npm run build
# Output in dist/ — deploy to any static host or serve with Flask
```

---

*Built for KEVS Siomai · Admin Dashboard v1.0*
