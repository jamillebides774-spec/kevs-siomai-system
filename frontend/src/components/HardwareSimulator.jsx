import React, { useState, useRef, useEffect } from 'react';
import { Monitor, Smartphone, Wifi, WifiOff, RefreshCw, Play, Plus } from 'lucide-react';
import { addToQueue, createOrder, gcashCallback, getQueueDisplay } from '../services/api';
import { getProducts } from '../services/api';

// ── Virtual OLED Display ──────────────────────────────────────────────────────
function OLEDDisplay({ nowServing, nextQueue, status }) {
  return (
    <div className="w-full bg-black rounded-xl p-4 font-mono border-2 border-dark-500 shadow-inner"
      style={{ fontFamily: "'Courier New', monospace", minHeight: 96 }}>
      <div className="text-center">
        <p className="text-green-400 text-xs tracking-widest opacity-70">KEVS SIOMAI QUEUE</p>
        <p className="text-green-400 text-xs mt-1 tracking-widest">━━━━━━━━━━━━━━━━━━━━</p>
        <div className="flex justify-around mt-2">
          <div>
            <p className="text-green-300 text-[10px] opacity-60">NOW SERVING</p>
            <p className="text-green-400 text-2xl font-bold">#{nowServing}</p>
          </div>
          <div className="border-r border-green-900 mx-2" />
          <div>
            <p className="text-green-300 text-[10px] opacity-60">NEXT QUEUE</p>
            <p className="text-green-400 text-2xl font-bold">#{nextQueue}</p>
          </div>
        </div>
        <p className="text-green-300 text-[10px] mt-2 opacity-70 uppercase tracking-widest">{status || 'PLEASE WAIT'}</p>
      </div>
    </div>
  );
}

// ── Virtual ESP32 ─────────────────────────────────────────────────────────────
function ESP32Simulator({ addToast }) {
  const [wifiOn, setWifiOn] = useState(true);
  const [pressing, setPressing] = useState(false);
  const [displayData, setDisplayData] = useState({ now_serving: 0, next_queue: 0, now_serving_status: 'idle' });
  const [log, setLog] = useState([]);
  const logRef = useRef(null);

  const addLog = (msg, type = 'info') => {
    setLog(prev => [...prev.slice(-19), { msg, type, time: new Date().toLocaleTimeString('en-PH', { hour: '2-digit', minute: '2-digit', second: '2-digit' }) }]);
  };

  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight;
  }, [log]);

  useEffect(() => {
    if (!wifiOn) return;
    const poll = setInterval(async () => {
      try {
        const resp = await getQueueDisplay();
        setDisplayData(resp.data);
      } catch { }
    }, 5000);
    return () => clearInterval(poll);
  }, [wifiOn]);

  const pressButton = async () => {
    if (pressing || !wifiOn) return;
    setPressing(true);
    addLog('Button pressed! Sending to server...', 'action');
    try {
      const resp = await addToQueue({
        type: 'walk-in',
        order_type: 'pickup',
        customer_name: 'Walk-in Customer',
        payment_method: 'Cash',
        items: [{ product_id: 1, quantity: 1 }],
        notes: 'ESP32 button press'
      });
      const queueNo = resp.data.order.queue_no;
      setDisplayData({ now_serving: resp.data.queue.now_serving, next_queue: resp.data.queue.current_queue_no, now_serving_status: 'waiting' });
      addLog(`Queue #${queueNo} issued!`, 'success');
      addToast('success', 'ESP32 Button', `Queue ticket #${queueNo} issued`);
    } catch (err) {
      addLog(`Error: ${err?.response?.data?.error || err.message}`, 'error');
    } finally {
      setTimeout(() => setPressing(false), 800);
    }
  };

  return (
    <div className="card p-5 space-y-4">
      <div className="flex items-center justify-between">
        <h3 className="font-bold text-white flex items-center gap-2">
          <Monitor className="w-5 h-5 text-brand-400" />
          Virtual ESP32 Device
        </h3>
        <button
          onClick={() => setWifiOn(p => !p)}
          className={`badge cursor-pointer ${wifiOn ? 'badge-green' : 'badge-red'}`}
        >
          {wifiOn ? <><Wifi className="w-3 h-3" /> Wi-Fi ON</> : <><WifiOff className="w-3 h-3" /> Wi-Fi OFF</>}
        </button>
      </div>

      {/* OLED Display */}
      <OLEDDisplay
        nowServing={displayData.now_serving}
        nextQueue={displayData.next_queue}
        status={displayData.now_serving_status}
      />

      {/* Button */}
      <div className="flex flex-col items-center gap-3">
        <button
          onClick={pressButton}
          disabled={pressing || !wifiOn}
          className={`w-24 h-24 rounded-full font-bold text-sm transition-all duration-150 shadow-2xl
            ${pressing ? 'scale-90 bg-brand-700 shadow-brand-500/20'
              : wifiOn ? 'bg-brand-500 hover:bg-brand-400 shadow-brand-500/40 active:scale-95 cursor-pointer glow-orange'
                : 'bg-dark-600 text-dark-400 cursor-not-allowed'}
            text-white`}
        >
          {pressing ? 'Sending...' : 'PRESS'}
        </button>
        <p className="text-xs text-dark-400">
          {wifiOn ? 'Simulates a customer pressing the queue button' : 'Wi-Fi disabled — button offline'}
        </p>
      </div>

      {/* Serial Log */}
      <div>
        <p className="text-xs font-semibold text-dark-400 uppercase tracking-wider mb-2">Serial Monitor</p>
        <div ref={logRef} className="bg-black rounded-xl p-3 h-36 overflow-y-auto font-mono text-xs space-y-0.5">
          {log.length === 0 && <p className="text-green-700">Waiting for button press...</p>}
          {log.map((entry, i) => (
            <p key={i} className={`${entry.type === 'error' ? 'text-red-400' : entry.type === 'success' ? 'text-green-400' : entry.type === 'action' ? 'text-yellow-400' : 'text-green-600'}`}>
              [{entry.time}] {entry.msg}
            </p>
          ))}
        </div>
      </div>
    </div>
  );
}

// ── Virtual Mobile App ─────────────────────────────────────────────────────────
function MobileSimulator({ addToast }) {
  const [screen, setScreen] = useState('menu'); // menu | cart | checkout | confirmation
  const [products, setProducts] = useState([]);
  const [cart, setCart] = useState({});
  const [orderType, setOrderType] = useState('pickup');
  const [paymentMethod, setPaymentMethod] = useState('GCash');
  const [customerName, setCustomerName] = useState('Maria Santos');
  const [address, setAddress] = useState('123 Rizal St., Makati');
  const [placedOrder, setPlacedOrder] = useState(null);
  const [loading, setLoading] = useState(false);
  const [paying, setPaying] = useState(false);

  useEffect(() => {
    getProducts().then(r => setProducts(r.data.products?.filter(p => p.is_active !== false).slice(0, 8) || [])).catch(() => {
      setProducts([
        { id: 1, name: 'Classic Pork Siomai', price: 45 },
        { id: 2, name: 'Beef Siomai', price: 50 },
        { id: 3, name: 'Chicken Siomai', price: 45 },
        { id: 9, name: 'Siomai Rice Meal', price: 65 },
        { id: 10, name: 'Gulaman', price: 20 },
      ]);
    });
  }, []);

  const updateCart = (id, delta) => {
    setCart(prev => {
      const cur = prev[id] || 0;
      const next = Math.max(0, cur + delta);
      if (next === 0) { const { [id]: _, ...rest } = prev; return rest; }
      return { ...prev, [id]: next };
    });
  };

  const cartItems = Object.entries(cart).map(([pid, qty]) => {
    const p = products.find(pr => pr.id === parseInt(pid));
    return p ? { ...p, qty, subtotal: p.price * qty } : null;
  }).filter(Boolean);

  const total = cartItems.reduce((s, i) => s + i.subtotal, 0);

  const placeOrder = async () => {
    setLoading(true);
    try {
      const resp = await createOrder({
        customer_name: customerName,
        customer_phone: '09171234567',
        order_type: orderType,
        delivery_address: orderType === 'delivery' ? address : '',
        payment_method: paymentMethod,
        items: cartItems.map(i => ({ product_id: i.id, quantity: i.qty })),
        notes: 'Simulation order'
      });
      setPlacedOrder(resp.data.order);
      setScreen('confirmation');
      addToast('success', 'Order Placed!', `Queue #${resp.data.order.queue_no} assigned`);
    } catch (err) {
      addToast('error', 'Order Failed', err?.response?.data?.error || 'Error');
    } finally {
      setLoading(false);
    }
  };

  const simulateGcash = async () => {
    if (!placedOrder) return;
    setPaying(true);
    try {
      await new Promise(r => setTimeout(r, 1500));
      const ref = `GC-${Math.random().toString(36).substr(2, 10).toUpperCase()}`;
      await gcashCallback({ order_id: placedOrder.id, reference: ref, status: 'paid' });
      setPlacedOrder(prev => ({ ...prev, payment_status: 'confirmed' }));
      addToast('success', 'GCash Paid', `Reference: ${ref}`);
    } catch {
      addToast('error', 'Payment Failed', 'GCash simulation error');
    } finally {
      setPaying(false);
    }
  };

  const resetSim = () => {
    setCart({}); setScreen('menu'); setPlacedOrder(null);
  };

  const PhoneShell = ({ children }) => (
    <div className="mx-auto" style={{ width: 280 }}>
      <div className="bg-dark-900 rounded-3xl border-4 border-dark-500 shadow-2xl overflow-hidden" style={{ minHeight: 520 }}>
        {/* Status bar */}
        <div className="bg-dark-900 px-4 py-2 flex justify-between items-center">
          <span className="text-xs text-dark-400">9:41 AM</span>
          <span className="text-xs text-dark-400">100%</span>
        </div>
        <div className="bg-dark-800" style={{ minHeight: 480 }}>
          {children}
        </div>
      </div>
    </div>
  );

  return (
    <div className="card p-5 space-y-4">
      <div className="flex items-center justify-between">
        <h3 className="font-bold text-white flex items-center gap-2">
          <Smartphone className="w-5 h-5 text-blue-400" />
          Virtual Customer App
        </h3>
        <div className="flex gap-2">
          {['menu', 'cart', 'checkout'].map(s => (
            <button
              key={s}
              onClick={() => setScreen(s)}
              disabled={s === 'cart' && cartItems.length === 0}
              className={`text-xs px-2 py-1 rounded-lg capitalize transition-all
                ${screen === s ? 'bg-blue-500/20 text-blue-400' : 'text-dark-500 hover:text-dark-300 disabled:opacity-30'}`}
            >
              {s}
            </button>
          ))}
          <button onClick={resetSim} className="btn-ghost text-xs px-2 py-1"><RefreshCw className="w-3 h-3" /></button>
        </div>
      </div>

      <PhoneShell>
        {/* MENU */}
        {screen === 'menu' && (
          <div>
            <div className="bg-gradient-to-r from-brand-600 to-brand-700 p-4">
              <p className="text-white font-bold text-sm">KEVS Siomai</p>
              <p className="text-brand-200 text-xs">Order online · Fast & Fresh</p>
            </div>
            <div className="p-3 space-y-2">
              {products.map(p => (
                <div key={p.id} className="flex items-center justify-between bg-dark-700 rounded-xl p-2.5">
                  <div>
                    <p className="text-white text-xs font-medium">{p.name}</p>
                    <p className="text-brand-400 text-xs font-bold">₱{p.price}</p>
                  </div>
                  <div className="flex items-center gap-1.5">
                    <button onClick={() => updateCart(p.id, -1)} disabled={!cart[p.id]}
                      className="w-6 h-6 rounded-full bg-dark-600 text-dark-300 flex items-center justify-center text-sm disabled:opacity-30">−</button>
                    <span className="text-white text-xs font-bold w-4 text-center">{cart[p.id] || 0}</span>
                    <button onClick={() => updateCart(p.id, 1)}
                      className="w-6 h-6 rounded-full bg-brand-500 text-white flex items-center justify-center text-sm">+</button>
                  </div>
                </div>
              ))}
              {cartItems.length > 0 && (
                <button onClick={() => setScreen('cart')} className="w-full py-2.5 bg-brand-500 text-white text-xs font-bold rounded-xl mt-2">
                  View Cart ({cartItems.length}) · ₱{total}
                </button>
              )}
            </div>
          </div>
        )}

        {/* CART */}
        {screen === 'cart' && (
          <div className="p-3">
            <p className="font-bold text-white text-sm mb-3">Your Cart</p>
            <div className="space-y-2">
              {cartItems.map(i => (
                <div key={i.id} className="flex justify-between items-center bg-dark-700 rounded-xl p-2.5">
                  <div>
                    <p className="text-white text-xs">{i.name}</p>
                    <p className="text-dark-400 text-xs">×{i.qty}</p>
                  </div>
                  <p className="text-brand-400 text-xs font-bold">₱{i.subtotal}</p>
                </div>
              ))}
              <div className="flex justify-between py-2 border-t border-dark-600">
                <p className="text-white text-xs font-bold">Total</p>
                <p className="text-brand-400 font-bold">₱{total}</p>
              </div>
            </div>
            <button onClick={() => setScreen('checkout')} className="w-full py-2.5 bg-brand-500 text-white text-xs font-bold rounded-xl mt-3">
              Proceed to Checkout →
            </button>
          </div>
        )}

        {/* CHECKOUT */}
        {screen === 'checkout' && (
          <div className="p-3 space-y-3">
            <p className="font-bold text-white text-sm">Checkout</p>
            <div>
              <p className="text-dark-400 text-xs mb-1">Name</p>
              <input className="w-full bg-dark-700 border border-dark-600 rounded-lg px-2 py-1.5 text-xs text-white" value={customerName} onChange={e => setCustomerName(e.target.value)} />
            </div>
            <div>
              <p className="text-dark-400 text-xs mb-1">Order Type</p>
              <div className="flex gap-2">
                {['pickup', 'delivery'].map(t => (
                  <button key={t} onClick={() => setOrderType(t)}
                    className={`flex-1 py-1.5 rounded-lg text-xs font-medium transition-all capitalize
                      ${orderType === t ? 'bg-brand-500 text-white' : 'bg-dark-700 text-dark-400'}`}>
                    {t}
                  </button>
                ))}
              </div>
            </div>
            {orderType === 'delivery' && (
              <div>
                <p className="text-dark-400 text-xs mb-1">Address</p>
                <input className="w-full bg-dark-700 border border-dark-600 rounded-lg px-2 py-1.5 text-xs text-white" value={address} onChange={e => setAddress(e.target.value)} />
              </div>
            )}
            <div>
              <p className="text-dark-400 text-xs mb-1">Payment</p>
              <div className="flex gap-2">
                {['GCash', 'Cash'].map(m => (
                  <button key={m} onClick={() => setPaymentMethod(m)}
                    className={`flex-1 py-1.5 rounded-lg text-xs font-medium transition-all
                      ${paymentMethod === m ? 'bg-brand-500 text-white' : 'bg-dark-700 text-dark-400'}`}>
                    {m}
                  </button>
                ))}
              </div>
            </div>
            <div className="flex justify-between border-t border-dark-600 pt-2">
              <p className="text-white text-xs font-bold">Total</p>
              <p className="text-brand-400 font-bold text-sm">₱{total}</p>
            </div>
            <button onClick={placeOrder} disabled={loading} className="w-full py-2.5 bg-brand-500 text-white text-xs font-bold rounded-xl">
              {loading ? 'Placing...' : 'Place Order'}
            </button>
          </div>
        )}

        {/* CONFIRMATION */}
        {screen === 'confirmation' && placedOrder && (
          <div className="p-4 text-center space-y-3">
            <p className="text-white font-bold text-base mt-2">Order Confirmed!</p>
            <div className="bg-dark-700 rounded-xl p-3 text-left space-y-1">
              <p className="text-xs text-dark-400">Queue Number</p>
              <p className="text-3xl font-bold text-brand-400">#{placedOrder.queue_no}</p>
              <p className="text-xs text-dark-400 mt-2">Payment Status</p>
              <p className={`text-sm font-semibold ${placedOrder.payment_status === 'confirmed' ? 'text-emerald-400' : 'text-yellow-400'}`}>
                {placedOrder.payment_status === 'confirmed' ? 'Paid' : 'Pending'}
              </p>
            </div>
            {placedOrder.payment_status !== 'confirmed' && placedOrder.payment_method === 'GCash' && (
              <button onClick={simulateGcash} disabled={paying} className="w-full py-2.5 bg-blue-600 text-white text-xs font-bold rounded-xl">
                {paying ? 'Processing GCash...' : 'Pay with GCash (Simulate)'}
              </button>
            )}
            <button onClick={resetSim} className="text-xs text-dark-400 underline">Place another order</button>
          </div>
        )}
      </PhoneShell>
    </div>
  );
}

// ── Main Simulator View ────────────────────────────────────────────────────────
export default function HardwareSimulator({ addToast }) {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-white">Hardware & App Simulator</h1>
        <p className="text-dark-400 text-sm mt-1">
          Simulate the ESP32 hardware device and mobile customer app without real hardware.
          All actions update the Queue Dashboard in real-time via Socket.IO.
        </p>
      </div>

      <div className="grid lg:grid-cols-2 gap-6">
        <ESP32Simulator addToast={addToast} />
        <MobileSimulator addToast={addToast} />
      </div>

      <div className="card p-5 border-brand-500/20">
        <h3 className="font-semibold text-white mb-3">API Testing Reference</h3>
        <div className="grid md:grid-cols-2 gap-3 text-xs font-mono">
          {[
            { method: 'POST', path: '/api/queue/add', desc: 'ESP32 button press (walk-in)' },
            { method: 'POST', path: '/api/orders', desc: 'Mobile app places online order' },
            { method: 'POST', path: '/api/payments/gcash/callback', desc: 'Mock GCash webhook' },
            { method: 'GET', path: '/api/queue/display', desc: 'ESP32 OLED polling' },
            { method: 'PUT', path: '/api/orders/:id', desc: 'Update order status' },
            { method: 'POST', path: '/api/offline/sync', desc: 'Sync offline PWA orders' },
          ].map((e, i) => (
            <div key={i} className="flex items-start gap-2 bg-dark-800 px-3 py-2 rounded-lg">
              <span className={`px-1.5 py-0.5 rounded text-[10px] font-bold flex-shrink-0
                ${e.method === 'GET' ? 'bg-blue-500/20 text-blue-400'
                  : e.method === 'POST' ? 'bg-emerald-500/20 text-emerald-400'
                    : 'bg-yellow-500/20 text-yellow-400'}`}>
                {e.method}
              </span>
              <div>
                <p className="text-brand-400">{e.path}</p>
                <p className="text-dark-500 text-[10px] mt-0.5">{e.desc}</p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
