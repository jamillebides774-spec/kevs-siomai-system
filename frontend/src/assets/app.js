/**
 * ==============================================================================
 *  KEVS SIOMAI — INTEGRATED ORDER MANAGEMENT SYSTEM
 *  Vanilla JavaScript Frontend Controller (app.js)
 * ==============================================================================
 *  No JSX, No React, No complex build tools!
 *  Standard HTML5, CSS3, and modern Vanilla JavaScript (ES6+).
 *  Fully functional Queue, Inventory, Analytics, Hardware Simulator, and WAF Firewall.
 * ==============================================================================
 */

import * as api from './api.js';
import * as db from './indexedDb.js';
import { initSyncManager, syncOfflineData } from './syncManager.js';
import { Icons } from './icons.js?v=12';

// ── Application State ────────────────────────────────────────────────────────
const state = {
  user: null,
  activeTab: 'queue', // 'queue' | 'completed' | 'inventory' | 'analytics' | 'simulator' | 'firewall'
  queueFilter: 'All',
  completedFilter: 'All', // 'All' | 'Today' | 'Yesterday' | 'Last 7 Days'
  completedPaymentFilter: 'All', // 'All' | 'Cash' | 'GCash'
  completedTypeFilter: 'All',
  completedSearch: '',
  completedPage: 1,
  completedPerPage: 8,
  completedOrders: [],
  completedLoading: false,
  inventoryFilter: 'All',
  inventorySearch: '',
  searchQuery: '',
  queuePage: 1,
  ordersPerPage: 6,
  theme: localStorage.getItem('kevs_theme') || 'light',
  queueData: { queue: {}, orders: [], stats: {} },
  inventory: [],
  analyticsData: null,
  firewallStats: null,
  firewallLogs: [],
  isOnline: navigator.onLine,
  unsyncedCount: 0,
  audioEnabled: true,
  socket: null,
  charts: {},
  notifiedOrderIds: new Set(),
  _initializedOrderIds: false
};

// ── Theme Management (Light / Dark Mode) ────────────────────────────────────
export function applyTheme(theme) {
  state.theme = theme;
  localStorage.setItem('kevs_theme', theme);
  if (theme === 'light') {
    document.documentElement.classList.add('light-theme');
    document.body.classList.add('light-theme');
  } else {
    document.documentElement.classList.remove('light-theme');
    document.body.classList.remove('light-theme');
  }
  const btn = document.getElementById('btn-toggle-theme');
  if (btn) {
    btn.innerHTML = theme === 'light' ? Icons.moon({ size: 16 }) : Icons.sun({ size: 16 });
    btn.title = theme === 'light' ? 'Switch to Dark Mode' : 'Switch to Light Mode';
  }
}

export function toggleTheme() {
  const nextTheme = state.theme === 'light' ? 'dark' : 'light';
  applyTheme(nextTheme);
  showToast('info', 'Theme Mode', `Switched to ${nextTheme === 'light' ? 'Light' : 'Dark'} Mode`);
}

// ── Date & Time Formatter (Authoritative Asia/Manila Timezone) ──────────────
export function parseOrderUtcDate(isoString) {
  if (!isoString) return new Date();
  if (isoString instanceof Date) return isoString;
  const s = String(isoString).trim();
  if (!s) return new Date();
  // If string is an ISO date-time without 'Z' or +/-HH:MM offset, treat as canonical UTC
  if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/.test(s) && !/(Z|[+-]\d{2}:?\d{2})$/i.test(s)) {
    const dUtc = new Date(s.replace(' ', 'T') + 'Z');
    if (!isNaN(dUtc.getTime())) return dUtc;
  }
  const d = new Date(s);
  return isNaN(d.getTime()) ? new Date() : d;
}

export function getManilaDateKey(dateOrIso) {
  try {
    const d = parseOrderUtcDate(dateOrIso);
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Manila',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit'
    }).formatToParts(d);
    const y = parts.find(p => p.type === 'year')?.value;
    const m = parts.find(p => p.type === 'month')?.value;
    const day = parts.find(p => p.type === 'day')?.value;
    if (y && m && day) return `${y}-${m}-${day}`;
  } catch (e) {}
  const fallback = parseOrderUtcDate(dateOrIso);
  const phMs = fallback.getTime() + (8 * 60 * 60 * 1000);
  return new Date(phMs).toISOString().split('T')[0];
}

export function formatOrderDate(isoString) {
  if (!isoString) {
    const now = new Date();
    return now.toLocaleDateString('en-US', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', year: 'numeric' }) +
           ' · ' + now.toLocaleTimeString('en-US', { timeZone: 'Asia/Manila', hour: '2-digit', minute: '2-digit', hour12: true });
  }
  try {
    const d = parseOrderUtcDate(isoString);
    if (isNaN(d.getTime())) return String(isoString);
    const dateStr = d.toLocaleDateString('en-US', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', year: 'numeric' });
    const timeStr = d.toLocaleTimeString('en-US', { timeZone: 'Asia/Manila', hour: '2-digit', minute: '2-digit', hour12: true });
    return `${dateStr} · ${timeStr}`;
  } catch (e) {
    return String(isoString);
  }
}

// ── Live Navbar Queue Pill Helper ───────────────────────────────────────────
function getNavbarQueuePillHtml() {
  const q = state.queueData.queue || {};
  const orders = state.queueData.orders || [];
  const activeOrders = orders.filter(o => !['completed', 'delivered', 'cancelled'].includes(o.status));
  const nowServingNum = q.now_serving ?? 0;

  const activeServing = orders.find(o => String(o.queue_no || o.id) === String(nowServingNum) && !['completed', 'delivered', 'cancelled'].includes(o.status)) ||
                        orders.find(o => ['preparing', 'accepted', 'pending'].includes(o.status));

  let servingHtml = '';
  if (activeServing) {
    servingHtml = `<span class="pill-val orange">#${activeServing.queue_no || nowServingNum}</span>`;
  } else {
    servingHtml = `<span class="pill-val no-orders">No orders yet!</span>`;
  }

  const queueNo = q.current_queue_no || 0;
  const activeCount = activeOrders.length;

  return `
    <span class="pill-label">Now Serving:</span>
    ${servingHtml}
    <span class="pill-sep">|</span>
    <span class="pill-label">Queue:</span>
    <span class="pill-val">#${queueNo}</span>
    ${activeCount > 0 ? `
      <span class="pill-sep">|</span>
      <span class="pulse-dot-yellow"></span>
      <span class="pill-val yellow">${activeCount} active</span>
    ` : `
      <span class="pill-sep">|</span>
      <span class="text-xs text-dark-400">0 active</span>
    `}
  `;
}

function updateNavbarQueuePill() {
  const el = document.getElementById('nav-queue-pill-box');
  if (el) el.innerHTML = getNavbarQueuePillHtml();
}

// ── Notification Sound (Web Audio API) ───────────────────────────────────────
function playBeep() {
  if (!state.audioEnabled) return;
  try {
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    if (!AudioCtx) return;
    const ctx = new AudioCtx();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.frequency.setValueAtTime(880, ctx.currentTime);
    osc.frequency.setValueAtTime(1100, ctx.currentTime + 0.1);
    gain.gain.setValueAtTime(0.3, ctx.currentTime);
    gain.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.3);
    osc.start(ctx.currentTime);
    osc.stop(ctx.currentTime + 0.3);
  } catch (e) {
    console.warn('Audio not available:', e);
  }
}

// ── SweetAlert2 Helpers & Dialog System ─────────────────────────────────────
export const swal = {
  fire: (...args) => (window.Swal ? window.Swal.fire(...args) : Promise.resolve({ isConfirmed: true })),

  confirm: ({ title, text, html, icon = 'warning', confirmText = 'Yes, Proceed', cancelText = 'Cancel', isDestructive = false }) => {
    if (!window.Swal) return Promise.resolve(window.confirm(text || title));
    return window.Swal.fire({
      title,
      text,
      html,
      icon,
      showCancelButton: true,
      confirmButtonText: confirmText,
      cancelButtonText: cancelText,
      confirmButtonColor: isDestructive ? '#dc2626' : undefined,
      cancelButtonColor: '#475569',
      reverseButtons: true,
      focusConfirm: true,
      focusCancel: false
    }).then(res => res.isConfirmed);
  },

  success: ({ title, text, html, timer = 2200, showConfirmButton = false, confirmButtonText = 'OK' }) => {
    if (!window.Swal) {
      showToast('success', title, text || '');
      return Promise.resolve();
    }
    return window.Swal.fire({
      icon: 'success',
      title,
      text,
      html,
      timer: showConfirmButton ? undefined : timer,
      showConfirmButton,
      confirmButtonText
    });
  },

  error: ({ title = 'Action Failed', text, html, confirmButtonText = 'OK' }) => {
    if (!window.Swal) {
      showToast('error', title, text || '');
      return Promise.resolve();
    }
    return window.Swal.fire({
      icon: 'error',
      title,
      text,
      html,
      confirmButtonText
    });
  },

  warning: ({ title = 'Attention', text, html, confirmButtonText = 'Understood' }) => {
    if (!window.Swal) {
      showToast('warning', title, text || '');
      return Promise.resolve();
    }
    return window.Swal.fire({
      icon: 'warning',
      title,
      text,
      html,
      confirmButtonText
    });
  },

  loading: ({ title = 'Processing...', text = 'Please wait a moment...', html }) => {
    if (!window.Swal) return;
    window.Swal.fire({
      title,
      text,
      html,
      allowOutsideClick: false,
      allowEscapeKey: false,
      didOpen: () => window.Swal.showLoading()
    });
  },

  close: () => {
    if (window.Swal && window.Swal.isVisible()) {
      window.Swal.close();
    }
  }
};

// ── Toast System ─────────────────────────────────────────────────────────────
export function showToast(type, title, message) {
  let container = document.getElementById('toast-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'toast-container';
    document.body.appendChild(container);
  }

  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  const icon = type === 'success' 
    ? Icons.checkCircle({ size: 20, color: 'var(--emerald-400)' }) 
    : type === 'error' 
    ? Icons.xCircle({ size: 20, color: 'var(--red-400)' }) 
    : type === 'warning' 
    ? Icons.alert({ size: 20, color: 'var(--yellow-400)' }) 
    : Icons.info({ size: 20, color: 'var(--blue-400)' });

  toast.innerHTML = `
    <span class="toast-icon">${icon}</span>
    <div style="flex: 1;">
      <div class="toast-title">${escapeHtml(title)}</div>
      <div class="toast-msg">${escapeHtml(message)}</div>
    </div>
    <span class="toast-close">&times;</span>
  `;

  toast.querySelector('.toast-close').addEventListener('click', () => toast.remove());
  container.appendChild(toast);

  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transform = 'translateX(100%)';
    toast.style.transition = 'all 0.3s ease';
    setTimeout(() => toast.remove(), 300);
  }, 4500);
}

function escapeHtml(str) {
  if (str === null || str === undefined) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

// ── Validation Helpers ────────────────────────────────────────────────────────
export function validatePersonName(name, fieldName = 'Customer Name') {
  if (!name || typeof name !== 'string' || !name.trim()) {
    return { valid: false, error: `${fieldName} is required.` };
  }
  const cleaned = name.trim();
  const allowedDefaults = ['Walk-in Customer', 'Online Customer', 'Offline Walk-in', 'Anonymous Customer', 'Walk-in (ESP32 Button)'];
  if (allowedDefaults.includes(cleaned)) {
    return { valid: true, value: cleaned };
  }
  if (cleaned.length < 2 || cleaned.length > 60) {
    return { valid: false, error: `${fieldName} must be between 2 and 60 characters.` };
  }
  // Reject 3 or more consecutive identical letters (e.g. 'jammmm', 'aaaa', 'Johnnnn')
  if (/([a-zA-Z\u00C0-\u024F\u1E00-\u1EFF])\1{2,}/i.test(cleaned)) {
    return { valid: false, error: `Invalid ${fieldName}: Avoid excessive repeated letters like "${cleaned}".` };
  }
  // Reject starting or ending with hyphen, apostrophe, or space
  if (/^[-'\s]|[-'\s]$/.test(cleaned)) {
    return { valid: false, error: `${fieldName} cannot start or end with a hyphen, apostrophe, or space.` };
  }
  // Reject consecutive punctuation or multiple consecutive spaces
  if (/[\'\-\.]{2,}/.test(cleaned) || /\s{2,}/.test(cleaned)) {
    return { valid: false, error: `${fieldName} cannot have consecutive punctuation marks or spaces.` };
  }
  // Allowed characters: Latin & accented letters, spaces, hyphens, periods, apostrophes
  const pattern = /^[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF\s.'-]+$/;
  if (!pattern.test(cleaned)) {
    return { valid: false, error: `${fieldName} can only contain letters, spaces, hyphens (-), periods (.), and apostrophes (').` };
  }
  // At least 2 alphabetic letters
  const letters = cleaned.match(/[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF]/g) || [];
  if (letters.length < 2) {
    return { valid: false, error: `${fieldName} must contain at least 2 letters.` };
  }
  return { valid: true, value: cleaned };
}

export function validateProductName(name) {
  if (!name || typeof name !== 'string' || !name.trim()) {
    return { valid: false, error: 'Product name is required.' };
  }
  const cleaned = name.trim();
  if (cleaned.length < 2 || cleaned.length > 80) {
    return { valid: false, error: 'Product name must be between 2 and 80 characters.' };
  }
  // Reject 3 or more consecutive identical characters (e.g. 'siomaiiiii', 'jammmm')
  if (/([a-zA-Z0-9])\1{2,}/i.test(cleaned)) {
    return { valid: false, error: `Invalid product name: Avoid repeated characters like "${cleaned}".` };
  }
  const pattern = /^[a-zA-Z0-9\u00C0-\u024F\u1E00-\u1EFF\s\-.,()&/]+$/;
  if (!pattern.test(cleaned)) {
    return { valid: false, error: 'Product name contains invalid characters.' };
  }
  const letters = cleaned.match(/[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF]/g) || [];
  if (letters.length < 2) {
    return { valid: false, error: 'Product name must contain at least 2 letters.' };
  }
  return { valid: true, value: cleaned };
}

export function validatePhoneNumber(phone, required = false) {
  if (!phone || typeof phone !== 'string' || !phone.trim()) {
    if (required) return { valid: false, error: 'Phone number is required.' };
    return { valid: true, value: '' };
  }
  const cleaned = phone.trim().replace(/[\s\-\(\)\.]/g, '');
  if (!(/^(\+639\d{9}|09\d{9}|9\d{9})$/.test(cleaned) || (/^\d+$/.test(cleaned) && cleaned.length >= 7 && cleaned.length <= 13))) {
    return { valid: false, error: 'Invalid phone number format. Please use 09XXXXXXXXX or +639XXXXXXXXX.' };
  }
  return { valid: true, value: phone.trim() };
}

// ── Application Entrypoint ───────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', async () => {
  applyTheme(state.theme);
  const savedUser = localStorage.getItem('kevs_user');
  if (savedUser) {
    try {
      state.user = JSON.parse(savedUser);
    } catch (e) {
      localStorage.removeItem('kevs_user');
    }
  }

  renderApp();
  initNetworkAndSync();
});

// ── Network & Offline Sync Setup ─────────────────────────────────────────────
function initNetworkAndSync() {
  initSyncManager({
    onStatusChange: (online) => {
      state.isOnline = online;
      updateOfflineUI();
      if (online) {
        showToast('success', 'Back Online', 'Synchronizing offline orders...');
      } else {
        showToast('warning', 'Offline Mode', 'Orders will be saved to IndexedDB');
      }
    },
    onSyncComplete: (result) => {
      refreshPendingCount();
      if (result.synced > 0) {
        showToast('success', 'Sync Complete', `${result.synced} offline order(s) synced!`);
        refreshQueue();
      }
    }
  });

  refreshPendingCount();
}

async function refreshPendingCount() {
  try {
    state.unsyncedCount = await db.getUnsyncedCount();
    const countEl = document.getElementById('sync-pending-badge');
    if (countEl) {
      countEl.textContent = `${state.unsyncedCount} pending`;
      countEl.style.display = state.unsyncedCount > 0 ? 'inline-block' : 'none';
    }
  } catch (e) {}
}

function updateOfflineUI() {
  const banner = document.getElementById('offline-banner');
  if (banner) {
    banner.style.display = state.isOnline ? 'none' : 'flex';
  }
  const statusDot = document.getElementById('net-status-dot');
  if (statusDot) {
    statusDot.style.background = state.isOnline ? 'var(--emerald-500)' : 'var(--red-500)';
  }
}

// ── Socket.IO Connection ─────────────────────────────────────────────────────
// ── Socket.IO Connection & Real-time Synchronization ────────────────────────
function initSocket() {
  if (state.socket) return;
  const socketUrl = window.location.port === '5000' ? window.location.origin : 'http://localhost:5000';

  if (typeof io !== 'undefined') {
    // Use polling transport without upgrade to ensure 100% stable connection on Flask/Werkzeug
    state.socket = io(socketUrl, { transports: ['polling'], upgrade: false, timeout: 10000 });

    state.socket.on('connect', () => {
      console.log('[Socket.IO] Realtime connection active');
    });

    state.socket.on('disconnect', () => {
      console.log('[Socket.IO] Realtime disconnected, falling back to background heartbeat');
    });

    const refreshActiveView = (data, isNew = false, newOrder = null) => {
      if (data && data.queue) {
        state.queueData = {
          queue: data.queue || {},
          orders: data.orders || [],
          stats: data.stats || {}
        };
        const newOrders = data.orders || [];
        const newQueue = data.queue || {};
        state._orderSignature = `${newQueue.current_queue_no}_${newQueue.now_serving}_${newOrders.length}_${newOrders.map(o => `${o.id}:${o.status}:${o.payment_status}`).join(',')}`;

        // Seed existing orders on first data load so we never re-notify for pre-existing records
        if (!state._initializedOrderIds && newOrders.length > 0) {
          state._initializedOrderIds = true;
          for (const o of newOrders) {
            if (o && o.id) state.notifiedOrderIds.add(String(o.id));
          }
        }
      }

      updateNavbarQueuePill();

      if (isNew && newOrder) {
        const ordId = String(newOrder.id ?? newOrder.order_id ?? '');
        if (ordId && !state.notifiedOrderIds.has(ordId)) {
          state.notifiedOrderIds.add(ordId);
          playBeep();
          const cust = newOrder.customer_name || 'Customer';
          const qNum = newOrder.queue_no ? `#${newOrder.queue_no}` : (newOrder.queue_number ? `#${newOrder.queue_number}` : `#${newOrder.id}`);
          const totalAmt = Number(newOrder.total_amount ?? newOrder.total ?? 0).toFixed(2);
          showToast('success', 'New Order Received', `${cust} (${qNum}) — ₱${totalAmt}`);
          state.queuePage = 1;
        }
      }

      if (state.activeTab === 'queue') {
        renderQueueTab(false);
      } else if (state.activeTab === 'completed') {
        renderCompletedTab(false);
      } else if (state.activeTab === 'analytics') {
        renderAnalyticsTab();
      } else if (state.activeTab === 'inventory') {
        renderInventoryTab();
      } else if (state.activeTab === 'simulator') {
        updateSimulatorOLED();
      }
    };

    state.socket.on('queue_updated', (data) => refreshActiveView(data));
    state.socket.on('order_updated', (updatedOrder) => {
      if (updatedOrder && state.queueData && Array.isArray(state.queueData.orders)) {
        const idx = state.queueData.orders.findIndex(o => String(o.id) === String(updatedOrder.id));
        if (idx >= 0) {
          state.queueData.orders[idx] = { ...state.queueData.orders[idx], ...updatedOrder };
        }
      }
      if (updatedOrder && Array.isArray(state.completedOrders)) {
        const cIdx = state.completedOrders.findIndex(o => String(o.id) === String(updatedOrder.id));
        if (cIdx >= 0) {
          state.completedOrders[cIdx] = { ...state.completedOrders[cIdx], ...updatedOrder };
        }
      }
      api.getQueue().then(res => {
        if (res && res.data) {
          refreshActiveView(res.data, false);
        }
      }).catch(() => {});
    });
    state.socket.on('new_order', (newOrder) => {
      const ordId = String(newOrder?.id ?? newOrder?.order_id ?? '');
      if (ordId && state.notifiedOrderIds.has(ordId)) {
        // Order already notified; simply refresh queue state silently
        api.getQueue().then(res => {
          if (res && res.data) {
            refreshActiveView(res.data, false);
          }
        }).catch(() => {});
        return;
      }
      api.getQueue().then(res => {
        if (res && res.data) {
          refreshActiveView(res.data, true, newOrder);
        }
      }).catch(() => {});
    });
    state.socket.on('sales_updated', () => {
      if (state.activeTab === 'analytics') {
        renderAnalyticsTab();
      } else if (state.activeTab === 'queue') {
        renderQueueTab(false);
      } else if (state.activeTab === 'completed') {
        renderCompletedTab(false);
      }
    });
    state.socket.on('analytics_updated', () => {
      if (state.activeTab === 'analytics') {
        renderAnalyticsTab();
      }
    });
    state.socket.on('inventory_updated', () => {
      if (state.activeTab === 'inventory') {
        renderInventoryTab();
      }
    });
  }

  // ── Auto-Refresh Dashboard Heartbeat (Fallback Polling) ──
  if (state.realtimeHeartbeat) {
    clearInterval(state.realtimeHeartbeat);
    state.realtimeHeartbeat = null;
  }

  state.realtimeHeartbeat = setInterval(async () => {
    if (!state.user || document.hidden) return;
    try {
      const qRes = await api.getQueue().catch(() => null);

      if (qRes && qRes.data) {
        const newOrders = qRes.data.orders || [];
        const newQueue = qRes.data.queue || {};
        const newStats = qRes.data.stats || {};

        if (!state._initializedOrderIds && newOrders.length > 0) {
          state._initializedOrderIds = true;
          for (const o of newOrders) {
            if (o && o.id) state.notifiedOrderIds.add(String(o.id));
          }
        }

        const prevOrders = (state.queueData && state.queueData.orders) || [];
        const prevLen = prevOrders.length;
        const isNewIncomingOrder = prevLen > 0 && newOrders.length > prevLen;

        state.queueData = {
          queue: newQueue,
          orders: newOrders,
          stats: newStats
        };

        const currentSignature = `${newQueue.current_queue_no}_${newQueue.now_serving}_${newOrders.length}_${newOrders.map(o => `${o.id}:${o.status}:${o.payment_status}`).join(',')}`;
        const hasChanged = state._orderSignature !== currentSignature;
        state._orderSignature = currentSignature;

        updateNavbarQueuePill();

        if (isNewIncomingOrder) {
          const genuinelyNew = newOrders.filter(o => o && o.id && !state.notifiedOrderIds.has(String(o.id)));
          if (genuinelyNew.length > 0) {
            for (const o of genuinelyNew) {
              state.notifiedOrderIds.add(String(o.id));
            }
            playBeep();
            const latestOrder = genuinelyNew[0];
            const cust = latestOrder?.customer_name || 'Customer';
            const qNum = latestOrder?.queue_no ? `#${latestOrder.queue_no}` : `#${latestOrder?.id}`;
            const totalAmt = Number(latestOrder?.total_amount ?? latestOrder?.total ?? 0).toFixed(2);
            showToast('success', 'New Order Received', `${cust} (${qNum}) — ₱${totalAmt}`);
            state.queuePage = 1;
          }
        }

        // Live refresh views when queue or status changes
        if (state.activeTab === 'queue') {
          renderQueueTab(false);
        } else if (state.activeTab === 'completed' && hasChanged) {
          renderCompletedTab(false);
        } else if (state.activeTab === 'analytics' && hasChanged) {
          renderAnalyticsTab();
        } else if (state.activeTab === 'simulator' && hasChanged) {
          updateSimulatorOLED();
        }
      }
      await refreshPendingCount();
    } catch (e) {
      // Silent fail for polling errors
    }
  }, 4000);
}

// ── Main Render Router ───────────────────────────────────────────────────────
function renderApp() {
  const app = document.getElementById('app');
  if (!app) return;

  if (!state.user) {
    renderLoginPage(app);
    return;
  }

  initSocket();
  app.innerHTML = `
    <!-- Offline Top Banner -->
    <div id="offline-banner" class="offline-banner" style="display: ${state.isOnline ? 'none' : 'flex'};">
      <span class="offline-dot" style="display:inline-block;width:8px;height:8px;border-radius:50%;background:#ef4444;margin-right:6px;"></span>
      <strong>OFFLINE MODE</strong> — Walk-in orders saved to browser. Auto-syncs when online.
      <span id="sync-pending-badge" class="badge badge-yellow" style="margin-left: 8px; display: ${state.unsyncedCount > 0 ? 'inline-block' : 'none'};">
        ${state.unsyncedCount} pending
      </span>
    </div>

    <!-- Navigation Header -->
    <header id="navbar">
      <div class="nav-inner">
        <!-- Brand -->
        <div class="flex items-center" style="cursor: pointer; flex-shrink: 0;" id="nav-brand">
          ${Icons.brandLockup({ height: 44 })}
        </div>

        <!-- Live Queue Badges Pill in Navbar -->
        <div id="nav-queue-pill-box" class="nav-queue-pill hidden md:flex">
          ${getNavbarQueuePillHtml()}
        </div>

        <!-- Navigation Tabs -->
        <nav class="flex items-center gap-2" style="margin-left: 16px;">
          <button class="nav-tab ${state.activeTab === 'queue' ? 'active' : ''}" data-tab="queue">
            ${Icons.queue({ size: 16 })} <span>Queue</span>
          </button>
          <button class="nav-tab ${state.activeTab === 'completed' ? 'active' : ''}" data-tab="completed">
            ${Icons.checkCircle({ size: 16 })} <span>Completed</span>
          </button>
          <button class="nav-tab ${state.activeTab === 'inventory' ? 'active' : ''}" data-tab="inventory">
            ${Icons.package({ size: 16 })} <span>Inventory</span>
          </button>
          <button class="nav-tab ${state.activeTab === 'analytics' ? 'active' : ''}" data-tab="analytics">
            ${Icons.analytics({ size: 16 })} <span>Analytics</span>
          </button>
          <button class="nav-tab ${state.activeTab === 'simulator' ? 'active' : ''}" data-tab="simulator">
            ${Icons.hardware({ size: 16 })} <span>Hardware</span>
          </button>
          <button class="nav-tab ${state.activeTab === 'firewall' ? 'active' : ''}" data-tab="firewall">
            ${Icons.shield({ size: 16 })} <span>Firewall</span>
            <span class="waf-pulse" style="margin-left: 4px;"></span>
          </button>
        </nav>

        <!-- Right Utilities -->
        <div class="flex items-center gap-3 ml-auto">
          <!-- Light / Dark Mode Toggle Button -->
          <button id="btn-toggle-theme" class="theme-toggle-btn" title="${state.theme === 'light' ? 'Switch to Dark Mode' : 'Switch to Light Mode'}">
            ${state.theme === 'light' ? Icons.moon({ size: 16 }) : Icons.sun({ size: 16 })}
          </button>

          <!-- Audio Toggle -->
          <button id="btn-toggle-audio" class="btn btn-ghost" title="Toggle audio chime">
            ${state.audioEnabled ? Icons.volume({ size: 16 }) : Icons.volumeMute({ size: 16 })}
          </button>

          <!-- Manual Sync Button -->
          <button id="btn-manual-sync" class="btn btn-secondary flex items-center gap-1.5" style="font-size: 12px; padding: 6px 12px;" title="Sync offline orders">
            ${Icons.refresh({ size: 14 })} <span id="sync-btn-label">Sync</span>
          </button>

          <!-- Network Status -->
          <div class="flex items-center gap-2" style="font-size: 12px; color: var(--dark-300);">
            <span id="net-status-dot" class="status-dot" style="background: ${state.isOnline ? 'var(--emerald-500)' : 'var(--red-500)'};"></span>
            <span id="net-status-text">${state.isOnline ? 'Online' : 'Offline'}</span>
          </div>

          <!-- User & Logout -->
          <div class="flex items-center gap-2" style="border-left: 1px solid var(--dark-600); padding-left: 12px;">
            <span style="font-size: 13px; font-weight: 600;" class="text-white">${escapeHtml(state.user.full_name || state.user.username)}</span>
            <button id="btn-logout" class="btn btn-ghost flex items-center gap-1" style="padding: 4px 8px; font-size: 12px; color: var(--red-400);" title="Logout">
              ${Icons.logout({ size: 14 })} Logout
            </button>
          </div>
        </div>
      </div>
    </header>

    <!-- Main Container -->
    <main id="main-content">
      <div id="tab-content"></div>
    </main>

    <!-- Global Modal Container -->
    <div id="modal-container"></div>
  `;

  bindNavbarEvents();
  renderCurrentTab();
}

function bindNavbarEvents() {
  document.querySelectorAll('.nav-tab').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const tab = e.currentTarget.getAttribute('data-tab');
      if (tab && tab !== state.activeTab) {
        state.activeTab = tab;
        document.querySelectorAll('.nav-tab').forEach(b => b.classList.remove('active'));
        e.currentTarget.classList.add('active');
        renderCurrentTab();
      }
    });
  });

  // Theme Toggle
  const btnTheme = document.getElementById('btn-toggle-theme');
  if (btnTheme) {
    btnTheme.addEventListener('click', () => toggleTheme());
  }

  const btnAudio = document.getElementById('btn-toggle-audio');
  if (btnAudio) {
    btnAudio.addEventListener('click', () => {
      state.audioEnabled = !state.audioEnabled;
      btnAudio.innerHTML = state.audioEnabled ? Icons.volume({ size: 16 }) : Icons.volumeMute({ size: 16 });
      showToast('info', 'Audio', state.audioEnabled ? 'Sound alerts unmuted' : 'Sound muted');
    });
  }

  const btnSync = document.getElementById('btn-manual-sync');
  if (btnSync) {
    btnSync.addEventListener('click', async () => {
      btnSync.disabled = true;
      btnSync.innerHTML = `${Icons.spinner({ size: 14 })} Syncing...`;
      swal.loading({
        title: 'Synchronizing Offline Orders...',
        text: 'Uploading pending offline orders to the server...'
      });

      const res = await syncOfflineData();
      btnSync.disabled = false;
      btnSync.innerHTML = `${Icons.refresh({ size: 14 })} Sync`;
      refreshPendingCount();

      if (res.synced > 0) {
        await swal.success({
          title: 'Sync Complete!',
          html: `<b>${res.synced}</b> offline order(s) successfully synchronized to the server!`,
          showConfirmButton: true,
          confirmButtonText: 'Great!'
        });
        refreshQueue();
      } else if (res.error) {
        swal.error({
          title: 'Sync Failed',
          text: res.error || 'Unable to synchronize offline orders.'
        });
      } else {
        swal.fire({
          icon: 'info',
          title: 'All Caught Up',
          text: 'There are no pending offline orders to sync.',
          confirmButtonText: 'OK'
        });
      }
    });
  }

  const btnLogout = document.getElementById('btn-logout');
  if (btnLogout) {
    btnLogout.addEventListener('click', async () => {
      const confirmed = await swal.confirm({
        title: 'Sign Out?',
        text: 'Are you sure you want to end your current session?',
        icon: 'question',
        confirmText: 'Yes, Sign Out',
        cancelText: 'Stay Signed In',
        isDestructive: false
      });
      if (!confirmed) return;

      state.user = null;
      localStorage.removeItem('kevs_user');
      if (state.realtimeHeartbeat) {
        clearInterval(state.realtimeHeartbeat);
        state.realtimeHeartbeat = null;
      }
      if (state.socket) {
        state.socket.disconnect();
        state.socket = null;
      }
      renderApp();
      swal.success({
        title: 'Signed Out',
        text: 'You have been signed out successfully.',
        timer: 1600
      });
    });
  }
}

function renderCurrentTab() {
  const container = document.getElementById('tab-content');
  if (!container) return;

  if (state.activeTab === 'queue') {
    renderQueueTab();
  } else if (state.activeTab === 'completed') {
    renderCompletedTab();
  } else if (state.activeTab === 'inventory') {
    renderInventoryTab();
  } else if (state.activeTab === 'analytics') {
    renderAnalyticsTab();
  } else if (state.activeTab === 'simulator') {
    renderSimulatorTab();
  } else if (state.activeTab === 'firewall') {
    renderFirewallTab();
  }
}

// ==============================================================================
// 1. LOGIN PAGE (HTML & JS)
// ==============================================================================
function renderLoginPage(container) {
  container.innerHTML = `
    <div id="login-page">
      <div class="login-orb-1"></div>
      <div class="login-orb-2"></div>

      <div class="card p-8" style="width: 100%; max-width: 420px; z-index: 10; position: relative;">
        <div class="text-center mb-6">
          <div style="display:inline-flex;align-items:center;justify-content:center;background:#171717;border:1px solid #262626;border-radius:14px;padding:12px 20px;box-shadow:0 6px 20px rgba(0,0,0,0.28);margin-bottom:8px;">
            ${Icons.brandLockup({ height: 48 })}
          </div>
          <p class="text-dark-300 text-sm mt-1">Admin Order Management & Security Gateway</p>
        </div>

        <div id="login-error" class="error-box" style="display: none;"></div>

        <form id="login-form" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-dark-300 mb-1">Username</label>
            <input type="text" id="login-username" class="input" value="admin" required placeholder="admin" />
          </div>

          <div>
            <label class="block text-sm font-medium text-dark-300 mb-1">Password</label>
            <input type="password" id="login-password" class="input" value="kevs2024" required placeholder="••••••••" />
          </div>

          <button type="submit" id="btn-login-submit" class="btn btn-primary w-full justify-center py-3 text-base mt-4 flex items-center gap-2">
            ${Icons.check({ size: 16 })} Sign In
          </button>
        </form>

        <div class="text-center mt-6 text-xs text-dark-400">
          KEVS Siomai POS & Order Management &bull; Protected by Kevs WAF Firewall
        </div>
      </div>
    </div>
  `;

  const form = document.getElementById('login-form');
  const errorBox = document.getElementById('login-error');
  const btnSubmit = document.getElementById('btn-login-submit');

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    errorBox.style.display = 'none';

    const username = document.getElementById('login-username').value.trim();
    const password = document.getElementById('login-password').value;

    if (!username || !password) {
      swal.warning({
        title: 'Missing Credentials',
        text: 'Please enter both username and password.'
      });
      return;
    }

    if (username.length < 3 || username.length > 50) {
      swal.warning({
        title: 'Invalid Username',
        text: 'Username must be between 3 and 50 characters.'
      });
      return;
    }

    if (password.length < 4 || password.length > 100) {
      swal.warning({
        title: 'Invalid Password',
        text: 'Password must be between 4 and 100 characters.'
      });
      return;
    }

    btnSubmit.disabled = true;
    btnSubmit.innerHTML = 'Signing in...';
    swal.loading({
      title: 'Signing In...',
      text: 'Verifying credentials and security tokens...'
    });

    try {
      const res = await api.login({ username, password });
      state.user = res.data.user;
      localStorage.setItem('kevs_user', JSON.stringify(state.user));
      swal.close();
      showToast('success', 'Welcome!', `Signed in as ${state.user.full_name || state.user.username}`);
      renderApp();
    } catch (err) {
      swal.close();
      const errMsg = err.response?.data?.error || err.message || 'Login failed. Please check credentials.';
      errorBox.textContent = errMsg;
      errorBox.style.display = 'block';
      swal.error({
        title: 'Authentication Failed',
        text: errMsg
      });
    } finally {
      btnSubmit.disabled = false;
      btnSubmit.innerHTML = `${Icons.check({ size: 16 })} Sign In`;
    }
  });
}

// ==============================================================================
// 2. QUEUE DASHBOARD (HTML & JS)
// ==============================================================================
async function refreshQueue() {
  try {
    const [qRes, statsRes] = await Promise.all([
      api.getQueue(),
      api.getDashboardStats().catch(() => ({ data: {} }))
    ]);
    state.queueData = {
      queue: qRes.data?.queue || {},
      orders: qRes.data?.orders || [],
      stats: statsRes.data || {}
    };
  } catch (err) {
    console.warn('Queue fetch error:', err);
  }
}

function isOrderPaid(order) {
  if (!order) return false;
  const ps = String(order.payment_status || order.payment?.status || '').trim().toLowerCase();
  return ps === 'confirmed' || ps === 'paid';
}

function getPaymentStatusLabel(order) {
  return isOrderPaid(order) ? 'Paid' : 'Pending Payment';
}

function getPaymentStatusBadgeClass(order) {
  return isOrderPaid(order) ? 'badge-green' : 'badge-yellow';
}

async function handleConfirmPayment(rawId, paymentMethod = 'Cash', triggerBtn = null) {
  if (!rawId) return;
  const orderId = String(rawId).replace(/^order_/, '').trim();
  if (triggerBtn) {
    if (triggerBtn.disabled || triggerBtn.getAttribute('data-submitting') === 'true') return;
    triggerBtn.disabled = true;
    triggerBtn.setAttribute('data-submitting', 'true');
  }

  try {
    const res = await api.confirmPayment(orderId, paymentMethod);
    const updated = res.data?.order;

    if (state.queueData && Array.isArray(state.queueData.orders)) {
      const qOrd = state.queueData.orders.find(o => String(o.id) === String(orderId) || String(o.id) === String(rawId));
      if (qOrd) {
        qOrd.payment_status = 'confirmed';
        if (updated && updated.payment_method) qOrd.payment_method = updated.payment_method;
      }
    }

    if (Array.isArray(state.completedOrders)) {
      const cOrd = state.completedOrders.find(o => String(o.id) === String(orderId) || String(o.id) === String(rawId));
      if (cOrd) {
        cOrd.payment_status = 'confirmed';
        if (updated && updated.payment_method) cOrd.payment_method = updated.payment_method;
      }
    }

    showToast('success', 'Payment Confirmed', `Order #${orderId} payment marked as Paid.`);

    if (state.activeTab === 'completed') {
      await renderCompletedTab(false);
    } else {
      await renderQueueTab(false);
    }
  } catch (err) {
    showToast('error', 'Payment Confirmation Failed', err.response?.data?.error || err.message || 'Unable to confirm payment.');
    if (triggerBtn) {
      triggerBtn.disabled = false;
      triggerBtn.removeAttribute('data-submitting');
    }
  }
}

function renderActiveBannerHtml(activeOrder) {
  if (!activeOrder) {
    return `
      <div class="card p-5 mb-6 text-center" style="border: 1px dashed var(--dark-600); background: rgba(15,23,42,0.4);">
        <div style="margin-bottom: 8px; color: var(--brand-400);">${Icons.siomai({ size: 36, strokeWidth: 1.8 })}</div>
        <div class="text-base font-bold text-dark-300">No orders yet!</div>
        <div class="text-xs text-dark-400 mt-1">Create a new walk-in order to start the queue.</div>
      </div>
    `;
  }
  const isPaid = isOrderPaid(activeOrder);
  const payMethod = activeOrder.payment_method || 'Cash';
  return `
    <div class="card p-6 mb-6 now-serving-card">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div class="flex items-center gap-4">
          <div style="width: 64px; height: 64px; border-radius: 16px; background: linear-gradient(135deg, #ef4444, #dc2626); color: #fff; display: flex; flex-direction: column; align-items: center; justify-content: center; font-weight: 800; box-shadow: 0 4px 14px -2px rgba(220, 38, 38, 0.4);">
            <span style="font-size: 11px; opacity: 0.85;">QUEUE</span>
            <span style="font-size: 26px; line-height: 1;">${(activeOrder.queue_no && Number(activeOrder.queue_no) > 0) ? '#' + activeOrder.queue_no : ((activeOrder.queue_number && Number(activeOrder.queue_number) > 0) ? '#' + activeOrder.queue_number : (activeOrder.id ? '#' + activeOrder.id : '—'))}</span>
          </div>
          <div>
            <div class="flex items-center gap-2 flex-wrap">
              <span class="flame-tag">${Icons.flame({ size: 12, color: '#dc2626' })} STEAMING NOW</span>
              <h3 class="text-xl font-bold text-white">${escapeHtml(activeOrder.customer_name || 'Walk-in Customer')}</h3>
              <span class="badge ${getStatusBadgeClass(activeOrder.status)}">${activeOrder.status}</span>
              <span class="badge ${getPaymentStatusBadgeClass(activeOrder)}">${getPaymentStatusLabel(activeOrder)} (${escapeHtml(payMethod)})</span>
              <span class="badge badge-gray">${activeOrder.order_type || activeOrder.type || 'Walk-in'}</span>
            </div>
            <p class="text-sm text-dark-300 mt-1">
              Order #${activeOrder.id} &bull; ${formatOrderItems(activeOrder.items)}
            </p>
            <p class="text-xs text-dark-400 mt-1 flex items-center gap-1.5">
              ${Icons.calendar({ size: 13, color: '#64748b' })} ${activeOrder.date_display || new Date(activeOrder.created_at || Date.now()).toLocaleDateString('en-US', {month:'short',day:'numeric',year:'numeric'})}
            </p>
          </div>
        </div>

        <div class="flex items-center gap-3 flex-wrap">
          <div class="text-right" style="margin-right: 12px;">
            <div class="text-xs text-dark-300">Total Amount</div>
            <div class="text-xl font-bold text-emerald-400">₱${Number(activeOrder.total || activeOrder.total_amount || 0).toFixed(2)}</div>
          </div>
          <button class="btn btn-secondary btn-buzz-order flex items-center gap-1.5" data-id="${activeOrder.id}">
            ${Icons.bellRing({ size: 15 })} Buzz
          </button>
          ${!isPaid && activeOrder.status !== 'cancelled' ? `
            <button class="btn btn-primary btn-confirm-payment flex items-center gap-1.5" data-id="${activeOrder.id}" data-method="${escapeHtml(payMethod)}">
              ${Icons.creditCard({ size: 15 })} Confirm Payment
            </button>
          ` : ''}
          <button class="btn btn-success btn-complete-order flex items-center gap-1.5" data-id="${activeOrder.id}">
            ${Icons.checkCircle({ size: 15 })} Mark Completed
          </button>
        </div>
      </div>
    </div>
  `;
}

async function renderQueueTab(showSpinner = true) {
  const container = document.getElementById('tab-content');
  if (!container) return;

  const ordersContainer = document.getElementById('orders-container');
  const isExistingDom = !showSpinner && ordersContainer !== null;

  if (showSpinner) {
    container.innerHTML = `
      <div class="flex items-center justify-center p-8">
        <div class="spinner"></div>
      </div>
    `;
    await refreshQueue();
    await refreshPendingCount();
  } else {
    // In-place update: always fetch fresh queue state from backend so cancellations/completions reflect immediately
    await refreshQueue();
    await refreshPendingCount();
  }

  const q = state.queueData.queue || {};
  let orders = state.queueData.orders || [];
  // Ensure active orders are sorted newest first so they immediately show on page 1 without refresh
  orders = [...orders].sort((a, b) => {
    const aActive = !['completed', 'delivered', 'cancelled'].includes(a.status);
    const bActive = !['completed', 'delivered', 'cancelled'].includes(b.status);
    if (aActive !== bActive) return bActive ? 1 : -1;
    return (b.id || 0) - (a.id || 0);
  });
  const stats = state.queueData.stats || {};

  const activeOrders = orders.filter(o => !['completed', 'delivered', 'cancelled'].includes(o.status));
  const hasActive = activeOrders.length > 0;
  const nowServingNum = hasActive ? (q.now_serving ?? q.now_serving_number ?? 0) : 0;
  const waitingCount = activeOrders.length;

  // Stats from backend (prefer backend stats which are date-accurate)
  const completedToday = stats.today_completed ?? 0;
  const todayRevenue = stats.today_revenue ?? 0;

  // Active serving order — only show banner when genuinely in-progress
  const activeOrder = hasActive
    ? (orders.find(o => String(o.queue_no || o.queue_number) === String(nowServingNum) && !['completed', 'delivered', 'cancelled'].includes(o.status)) ||
       orders.find(o => ['preparing', 'accepted'].includes(o.status)) ||
       activeOrders[0])
    : null;

  // Fast In-Place Real-Time DOM Update (Zero Flicker & Preserves Focus/State)
  if (isExistingDom) {
    const elNowServing = document.getElementById('stat-now-serving-val');
    if (elNowServing) elNowServing.textContent = hasActive ? '#' + nowServingNum : '—';
    const elNowServingSub = document.getElementById('stat-now-serving-sub');
    if (elNowServingSub) elNowServingSub.textContent = hasActive ? 'Ticket in progress' : 'No orders yet!';

    const elWaiting = document.getElementById('stat-waiting-val');
    if (elWaiting) elWaiting.textContent = waitingCount;
    const elWaitingSub = document.getElementById('stat-waiting-sub');
    if (elWaitingSub) elWaitingSub.textContent = waitingCount === 0 ? 'No orders in line' : 'Orders in line';

    const elCompleted = document.getElementById('stat-completed-val');
    if (elCompleted) elCompleted.textContent = completedToday;

    const elRevenue = document.getElementById('stat-revenue-val');
    if (elRevenue) elRevenue.textContent = '₱' + Number(todayRevenue).toFixed(2);

    const btnCallNext = document.getElementById('btn-call-next');
    if (btnCallNext) btnCallNext.innerHTML = `${Icons.bullhorn({ size: 16 })} Call Next (#${Number(nowServingNum) + 1})`;

    const bannerBox = document.getElementById('active-serving-banner-box');
    if (bannerBox) bannerBox.innerHTML = renderActiveBannerHtml(activeOrder);

    // Update tab badges
    document.querySelectorAll('.tab-btn').forEach(btn => {
      const filter = btn.getAttribute('data-filter');
      const countEl = btn.querySelector('.tab-count');
      if (filter && countEl) {
        if (filter === 'All' || filter === 'All Active') countEl.textContent = activeOrders.length;
        else if (filter === 'Cancelled') countEl.textContent = orders.filter(o => o.status === 'cancelled').length;
        else countEl.textContent = activeOrders.filter(o => mapStage(o.status) === filter.toLowerCase()).length;
      }
    });

    ordersContainer.innerHTML = renderOrderCards(orders);
    bindQueueCardActions();
    return;
  }

  const searchInput = document.getElementById('queue-search');
  const isSearchFocused = searchInput && document.activeElement === searchInput;
  const cursorSelectionStart = isSearchFocused ? searchInput.selectionStart : null;
  const cursorSelectionEnd = isSearchFocused ? searchInput.selectionEnd : null;

  container.innerHTML = `
    <!-- Top Action Bar & Stat Cards -->
    <div class="flex flex-wrap items-center justify-between gap-4 mb-6">
      <div>
        <h1 class="text-2xl font-bold text-white">Live Queue</h1>
      </div>

      <div class="flex items-center gap-3 flex-wrap">
        <button id="btn-open-order-modal" class="btn btn-primary flex items-center gap-1.5">
          ${Icons.plus({ size: 16 })} New Walk-in Order
        </button>
        <button id="btn-call-next" class="btn btn-success flex items-center gap-1.5">
          ${Icons.bullhorn({ size: 16 })} Call Next (#${Number(nowServingNum) + 1})
        </button>
        <button id="btn-goto-completed" class="btn btn-secondary flex items-center gap-1.5" title="View dedicated Completed Orders page">
          ${Icons.checkCircle({ size: 16 })} Completed (${completedToday})
        </button>
        <button id="btn-reset-queue" class="btn btn-secondary text-red-400 flex items-center gap-1.5" title="Reset today's queue count">
          ${Icons.alert({ size: 15 })} Reset
        </button>
        <button id="btn-refresh-queue" class="btn btn-secondary flex items-center gap-1.5">
          ${Icons.refresh({ size: 15 })} Refresh
        </button>
      </div>
    </div>

    <!-- Stat Cards Bar -->
    <div class="grid-4 mb-6">
      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(249,115,22,0.2); color: var(--brand-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.bullhorn({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">NOW SERVING</div>
          <div id="stat-now-serving-val" class="text-3xl font-bold text-white">${hasActive ? '#' + nowServingNum : '—'}</div>
          <div id="stat-now-serving-sub" class="text-xs text-brand-400 mt-1">${hasActive ? 'Ticket in progress' : 'No orders yet!'}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(234,179,8,0.2); color: var(--yellow-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.clock({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">WAITING IN QUEUE</div>
          <div id="stat-waiting-val" class="text-3xl font-bold text-white">${waitingCount}</div>
          <div id="stat-waiting-sub" class="text-xs text-yellow-400 mt-1">${waitingCount === 0 ? 'No orders in line' : 'Orders in line'}</div>
        </div>
      </div>

      <div class="card stat-card" id="stat-completed-card" style="cursor: pointer;" title="Click to view Completed Orders archive">
        <div class="stat-icon" style="background: rgba(16,185,129,0.2); color: var(--emerald-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.checkCircle({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">COMPLETED TODAY</div>
          <div id="stat-completed-val" class="text-3xl font-bold text-white">${completedToday}</div>
          <div id="stat-completed-sub" class="text-xs text-emerald-400 mt-1">${completedToday === 0 ? 'None yet today' : 'Orders served today →'}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(59,130,246,0.2); color: var(--blue-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.coins({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">TODAY'S REVENUE</div>
          <div id="stat-revenue-val" class="text-3xl font-bold text-white">₱${Number(todayRevenue).toFixed(2)}</div>
          <div id="stat-revenue-sub" class="text-xs text-blue-400 mt-1">${todayRevenue === 0 ? 'No sales yet today' : 'Total sales today'}</div>
        </div>
      </div>
    </div>

    <!-- Active Now Serving Banner Box -->
    <div id="active-serving-banner-box">
      ${renderActiveBannerHtml(activeOrder)}
    </div>

    <!-- Filter and Search Bar -->
    <div class="flex flex-wrap items-center justify-between gap-4 mb-4">
      <div class="tab-bar">
        ${['All Active', 'Pending', 'Preparing', 'Ready', 'Cancelled'].map(tab => {
          const filterKey = tab === 'All Active' ? 'All' : tab;
          let count = 0;
          if (filterKey === 'All') count = activeOrders.length;
          else if (filterKey === 'Cancelled') count = orders.filter(o => o.status === 'cancelled').length;
          else count = activeOrders.filter(o => mapStage(o.status) === filterKey.toLowerCase()).length;
          return `
            <button class="tab-btn ${(state.queueFilter === filterKey || (filterKey === 'All' && !state.queueFilter)) ? 'active' : ''}" data-filter="${filterKey}">
              ${tab}
              <span class="tab-count">${count}</span>
            </button>
          `;
        }).join('')}
      </div>

      <div style="position: relative; width: 280px;">
        <input type="text" id="queue-search" class="input" placeholder="Search customer or queue #..." value="${escapeHtml(state.searchQuery)}" />
      </div>
    </div>

    <!-- Orders Cards Grid -->
    <div class="orders-grid" id="orders-container">
      ${renderOrderCards(orders)}
    </div>

    <!-- Pagination Controls -->
    <div id="pagination-controls" style="margin-top: 16px;"></div>
  `;

  bindQueueEvents();

  if (isSearchFocused) {
    const newSearchInput = document.getElementById('queue-search');
    if (newSearchInput) {
      newSearchInput.focus();
      if (cursorSelectionStart !== null) {
        newSearchInput.setSelectionRange(cursorSelectionStart, cursorSelectionEnd);
      }
    }
  }
}

function mapStage(status) {
  if (['pending', 'accepted'].includes(status)) return 'pending';
  if (['preparing'].includes(status)) return 'preparing';
  if (['ready_pickup', 'ready_delivery', 'out_for_delivery', 'ready'].includes(status)) return 'ready';
  if (['completed', 'delivered'].includes(status)) return 'completed';
  if (['cancelled'].includes(status)) return 'cancelled';
  return 'other';
}

function getStatusBadgeClass(status) {
  switch (status) {
    case 'pending': return 'badge-yellow';
    case 'accepted':
    case 'preparing': return 'badge-orange';
    case 'ready':
    case 'ready_pickup':
    case 'ready_delivery': return 'badge-green';
    case 'completed':
    case 'delivered': return 'badge-gray';
    case 'cancelled': return 'badge-red';
    default: return 'badge-blue';
  }
}

const ASSET_VERSION = '20261025_v3';

function getFreshImageUrl(url) {
  if (!url) return '';
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}v=${ASSET_VERSION}`;
}

function getProductImageUrl(name) {
  if (!name) return getFreshImageUrl('/images/hotspot_siomai.jpg');
  const n = String(name).toLowerCase();
  if (n.includes('siomai')) return getFreshImageUrl('/images/hotspot_siomai.jpg');
  if (n.includes('coke') || n.includes('coca')) return getFreshImageUrl('/images/coke.jpg');
  if (n.includes('royal')) return getFreshImageUrl('/images/royal.jpg');
  if (n.includes('sprite')) return getFreshImageUrl('/images/sprite.jpg');
  if (n.includes('chilli') || n.includes('chili')) return getFreshImageUrl('/images/chilli_garlic.jpg');
  if (n.includes('soy')) return getFreshImageUrl('/images/soy_sauce.jpg');
  if (n.includes('calamansi')) return getFreshImageUrl('/images/calamansi.jpg');
  return getFreshImageUrl('/images/hotspot_siomai.jpg');
}

function formatOrderItems(items) {
  if (!items || !items.length) {
    return `
      <div style="display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px; border-radius: 8px; background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.1); font-size: 12px; margin-top: 4px; height: auto; word-break: break-word;">
        <img src="/images/hotspot_siomai.jpg" style="width: 18px; height: 18px; border-radius: 4px; object-fit: cover; flex-shrink: 0;" onerror="this.style.display='none'">
        <span>1x Siomai</span>
      </div>
    `;
  }
  return `
    <div style="display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px;">
      ${items.map(i => {
        const qty = i.quantity || i.qty || 1;
        const name = i.product_name || i.name || 'Siomai';
        const img = i.image_url || getProductImageUrl(name);
        return `
          <span style="display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px; border-radius: 8px; background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.08); font-size: 12px; color: var(--dark-200); height: auto; line-height: 1.35; word-break: break-word;">
            ${img ? `<img src="${escapeHtml(img)}" alt="${escapeHtml(name)}" style="width: 18px; height: 18px; border-radius: 4px; object-fit: cover; border: 1px solid rgba(255,255,255,0.1); flex-shrink: 0;" onerror="this.style.display='none'">` : ''}
            <span><strong style="color: #fff;">${qty}x</strong> ${escapeHtml(name)}</span>
          </span>
        `;
      }).join('')}
    </div>
  `;
}

function renderOrderCards(orders) {
  let filtered = orders || [];
  if (state.queueFilter === 'Cancelled') {
    filtered = filtered.filter(o => o.status === 'cancelled');
  } else if (state.queueFilter && state.queueFilter !== 'All' && state.queueFilter !== 'All Active') {
    filtered = filtered.filter(o => mapStage(o.status) === state.queueFilter.toLowerCase());
  } else {
    // Live Queue only displays active orders in progress; completed & cancelled orders are kept separate
    filtered = filtered.filter(o => !['completed', 'delivered', 'cancelled'].includes(o.status));
  }
  if (state.searchQuery) {
    const q = state.searchQuery.toLowerCase();
    filtered = filtered.filter(o =>
      (o.customer_name && o.customer_name.toLowerCase().includes(q)) ||
      (String(o.queue_no || o.queue_number).includes(q)) ||
      (String(o.id).includes(q))
    );
  }

  const totalFiltered = filtered.length;
  const perPage = state.ordersPerPage || 6;
  const totalPages = Math.ceil(totalFiltered / perPage);

  // Clamp page to valid range
  if (state.queuePage < 1) state.queuePage = 1;
  if (state.queuePage > totalPages && totalPages > 0) state.queuePage = totalPages;

  const start = (state.queuePage - 1) * perPage;
  const paginated = filtered.slice(start, start + perPage);

  // Render pagination controls if there are multiple pages
  setTimeout(() => {
    const paginationEl = document.getElementById('pagination-controls');
    if (paginationEl && totalPages > 1) {
      let pagesHtml = `<div class="flex items-center justify-center gap-2" style="flex-wrap: wrap;">`;
      pagesHtml += `<button class="btn btn-secondary btn-page" data-page="${state.queuePage - 1}" ${state.queuePage <= 1 ? 'disabled' : ''} style="padding: 6px 12px;">← Prev</button>`;
      for (let i = 1; i <= totalPages; i++) {
        pagesHtml += `<button class="btn ${i === state.queuePage ? 'btn-primary' : 'btn-secondary'} btn-page" data-page="${i}" style="padding: 6px 12px; min-width: 36px;">${i}</button>`;
      }
      pagesHtml += `<button class="btn btn-secondary btn-page" data-page="${state.queuePage + 1}" ${state.queuePage >= totalPages ? 'disabled' : ''} style="padding: 6px 12px;">Next →</button>`;
      pagesHtml += `<span class="text-xs text-dark-400" style="margin-left: 8px;">Page ${state.queuePage} of ${totalPages} (${totalFiltered} orders)</span>`;
      pagesHtml += `</div>`;
      paginationEl.innerHTML = pagesHtml;

      paginationEl.querySelectorAll('.btn-page').forEach(btn => {
        btn.addEventListener('click', (e) => {
          const newPage = parseInt(e.currentTarget.getAttribute('data-page'), 10);
          if (!isNaN(newPage) && newPage >= 1 && newPage <= totalPages) {
            state.queuePage = newPage;
            const container = document.getElementById('orders-container');
            if (container) {
              container.innerHTML = renderOrderCards(state.queueData.orders || []);
              bindQueueCardActions();
            }
          }
        });
      });
    } else if (paginationEl) {
      paginationEl.innerHTML = '';
    }
  }, 0);

  if (paginated.length === 0) {
    return `
      <div class="card p-8 text-center" style="grid-column: 1 / -1;">
        <div style="margin-bottom: 8px; color: var(--brand-400);">${Icons.siomai({ size: 40, strokeWidth: 1.5 })}</div>
        <h3 class="text-lg font-bold text-white">No Orders Found</h3>
        <p class="text-sm text-dark-300 mt-1">There are currently no orders matching this filter.</p>
      </div>
    `;
  }

  return paginated.map(order => {
    const rawQ = order.queue_no || order.queue_number;
    const queueNo = (rawQ && Number(rawQ) > 0) ? rawQ : (order.id ? order.id : 'Pending');
    const totalVal = order.total || order.total_amount || 0;
    const isPaid = isOrderPaid(order);
    const payMethod = order.payment_method || 'Cash';
    return `
      <div class="card queue-card p-5" data-order-id="${order.id}">
        <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
          <div class="flex flex-wrap items-center gap-2">
            <span style="font-size: 16px; font-weight: 800; color: var(--brand-400);">${queueNo === 'Pending' ? 'Ticket: Pending' : '#' + queueNo}</span>
            <span class="badge ${getStatusBadgeClass(order.status)}">${order.status}</span>
            <span class="badge ${getPaymentStatusBadgeClass(order)}">${getPaymentStatusLabel(order)}</span>
            <span class="badge ${order.order_type === 'delivery' ? 'badge-amber' : 'badge-gray'}">${order.order_type === 'delivery' ? 'Delivery (Gatid)' : (order.order_type || order.type || 'Walk-in')}</span>
          </div>
          <span class="text-xs text-dark-400">${formatOrderDate(order.created_at || order.timestamp)}</span>
        </div>

        <div class="mb-3">
          <div class="font-bold text-white text-base">${escapeHtml(order.customer_name || 'Walk-in Customer')}</div>
          <div class="text-xs text-dark-300 mt-1">${formatOrderItems(order.items)}</div>
          ${order.delivery_address ? `
            <div class="text-xs text-amber-300 mt-2 p-2 rounded bg-amber-950/30 border border-amber-800/40 flex items-start gap-1.5">
              <span class="mt-0.5 text-amber-400">${Icons.pin({ size: 13 })}</span>
              <span><strong>Delivery Address:</strong> ${escapeHtml(order.delivery_address)}</span>
            </div>
          ` : ''}
        </div>

        <div class="flex flex-wrap items-center justify-between gap-2 pt-3 border-t">
          <div>
            <div class="text-xs text-dark-400">Total &bull; ${escapeHtml(payMethod)}</div>
            <div class="font-bold text-emerald-400 text-sm">₱${Number(totalVal).toFixed(2)}</div>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            ${!isPaid && order.status !== 'cancelled' ? `
              <button class="btn btn-primary btn-confirm-payment flex items-center gap-1" data-id="${order.id}" data-method="${escapeHtml(payMethod)}" style="font-size: 12px; padding: 4px 10px;">
                ${Icons.creditCard({ size: 13 })} Confirm Payment
              </button>
            ` : ''}

            ${order.status === 'pending' ? `
              <button class="btn btn-secondary btn-action-status flex items-center gap-1" data-id="${order.id}" data-status="preparing" style="font-size: 12px; padding: 4px 10px;">
                ${Icons.cook({ size: 14 })} Prepare
              </button>
            ` : order.status === 'preparing' ? `
              <button class="btn btn-secondary btn-action-status flex items-center gap-1" data-id="${order.id}" data-status="ready_pickup" style="font-size: 12px; padding: 4px 10px;">
                ${Icons.bellRing({ size: 14 })} Ready
              </button>
            ` : order.status === 'ready_pickup' || order.status === 'ready' ? `
              <button class="btn btn-success btn-action-status flex items-center gap-1" data-id="${order.id}" data-status="completed" style="font-size: 12px; padding: 4px 10px;">
                ${Icons.check({ size: 14 })} Complete
              </button>
            ` : order.status === 'cancelled' ? `
              <span class="badge badge-red" style="font-size: 12px; padding: 4px 8px;">
                ${Icons.xCircle({ size: 13 })} Cancelled
              </span>
            ` : ''}

            ${!['completed', 'delivered', 'cancelled'].includes(order.status) ? `
              <button class="btn btn-ghost text-red-400 btn-action-status flex items-center gap-1" data-id="${order.id}" data-status="cancelled" style="font-size: 12px; padding: 4px 8px;">
                ${Icons.xCircle({ size: 13 })} Cancel
              </button>
            ` : ''}
          </div>
        </div>
      </div>
    `;
  }).join('');
}

function bindQueueCardActions() {
  document.querySelectorAll('.btn-action-status').forEach(btn => {
    btn.onclick = async (e) => {
      const targetBtn = e.currentTarget;
      const rawId = targetBtn.getAttribute('data-id');
      const nextStatus = targetBtn.getAttribute('data-status');
      if (!rawId || !nextStatus) return;
      const orderId = String(rawId).replace(/^order_/, '').trim();

      // Prevent duplicate double clicks
      if (targetBtn.disabled || targetBtn.getAttribute('data-submitting') === 'true') {
        return;
      }

      if (nextStatus === 'cancelled') {
        const confirmed = await swal.confirm({
          title: 'Cancel Order?',
          text: `Are you sure you want to cancel Order #${orderId}? This cannot be undone.`,
          icon: 'warning',
          confirmText: 'Yes, Cancel Order',
          cancelText: 'Keep Order',
          isDestructive: true
        });
        if (!confirmed) return;
      }

      targetBtn.disabled = true;
      targetBtn.setAttribute('data-submitting', 'true');

      // Show loading indicator during cancellation
      if (nextStatus === 'cancelled' && window.Swal) {
        window.Swal.fire({
          title: 'Cancelling Order...',
          text: 'Updating status and restoring inventory...',
          allowOutsideClick: false,
          allowEscapeKey: false,
          didOpen: () => {
            window.Swal.showLoading();
          }
        });
      }

      try {
        await api.updateOrderStatus(orderId, { status: nextStatus });

        // Immediately mutate local cache so UI reflects immediately
        if (state.queueData && Array.isArray(state.queueData.orders)) {
          const ord = state.queueData.orders.find(o => String(o.id) === String(orderId) || String(o.id) === String(rawId));
          if (ord) ord.status = nextStatus;
        }

        // Immediately update DOM so order leaves active queue without delay
        await renderQueueTab(false);

        // Fetch fresh queue and stats from backend
        await refreshQueue();
        await renderQueueTab(false);

        if (nextStatus === 'cancelled') {
          await swal.success({
            title: 'Order Cancelled',
            text: `Order #${orderId} has been successfully marked as cancelled.`,
            timer: 1800,
            showConfirmButton: false
          });
        } else {
          showToast('success', 'Updated', `Order marked as ${nextStatus}`);
        }
      } catch (err) {
        if (nextStatus === 'cancelled') {
          await swal.error({
            title: 'Cancellation Failed',
            text: err.message || 'Could not cancel order. Please check connection and try again.'
          });
        } else {
          showToast('error', 'Update Failed', err.message);
        }
        targetBtn.disabled = false;
        targetBtn.removeAttribute('data-submitting');
        await renderQueueTab(false);
      }
    };
  });

  document.querySelectorAll('.btn-complete-order').forEach(btn => {
    btn.onclick = async (e) => {
      const id = e.currentTarget.getAttribute('data-id');
      if (!id) return;
      e.currentTarget.disabled = true;
      try {
        await api.updateOrderStatus(id, { status: 'completed' });
        showToast('success', 'Order Completed', 'Customer order fulfilled!');
        await renderQueueTab(false);
      } catch (err) {
        showToast('error', 'Failed', err.message);
        e.currentTarget.disabled = false;
      }
    };
  });

  document.querySelectorAll('.btn-buzz-order').forEach(btn => {
    btn.onclick = () => {
      playBeep();
      showToast('info', 'Calling Customer', 'Audible alert triggered for order!');
    };
  });

  document.querySelectorAll('.btn-confirm-payment').forEach(btn => {
    btn.onclick = async (e) => {
      const targetBtn = e.currentTarget;
      const id = targetBtn.getAttribute('data-id');
      const method = targetBtn.getAttribute('data-method') || 'Cash';
      await handleConfirmPayment(id, method, targetBtn);
    };
  });
}

function bindQueueEvents() {
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const filter = e.currentTarget.getAttribute('data-filter');
      if (filter) {
        state.queueFilter = filter;
        state.queuePage = 1; // reset pagination when filter changes
        document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
        e.currentTarget.classList.add('active');
        const container = document.getElementById('orders-container');
        if (container) {
          container.innerHTML = renderOrderCards(state.queueData.orders || []);
          bindQueueCardActions();
        }
      }
    });
  });

  const searchInput = document.getElementById('queue-search');
  if (searchInput) {
    searchInput.addEventListener('input', (e) => {
      state.searchQuery = e.target.value;
      state.queuePage = 1; // reset pagination when searching
      const container = document.getElementById('orders-container');
      if (container) {
        container.innerHTML = renderOrderCards(state.queueData.orders || []);
        bindQueueCardActions();
      }
    });
  }

  // Refresh
  document.getElementById('btn-refresh-queue')?.addEventListener('click', async () => {
    showToast('info', 'Refreshing', 'Updating queue data...');
    await renderQueueTab();
  });

  // Reset Queue
  document.getElementById('btn-reset-queue')?.addEventListener('click', async () => {
    const confirmed = await swal.confirm({
      title: 'Reset Daily Queue?',
      text: 'Are you sure you want to reset the daily queue counter to #0? Ticketing will restart from #1. This cannot be undone.',
      icon: 'warning',
      confirmText: 'Yes, Reset Queue',
      cancelText: 'Cancel',
      isDestructive: true
    });
    if (!confirmed) return;

    swal.loading({
      title: 'Resetting Queue...',
      text: 'Updating daily counter...'
    });

    try {
      await api.resetQueue();
      await swal.success({
        title: 'Queue Reset Successful',
        text: 'The daily queue counter has been reset to #0.',
        timer: 2000
      });
      await renderQueueTab();
    } catch (err) {
      swal.error({
        title: 'Reset Failed',
        text: err.message || 'Unable to reset queue counter.'
      });
    }
  });

  // Call Next
  document.getElementById('btn-call-next')?.addEventListener('click', async () => {
    try {
      playBeep();
      const res = await api.callNextOrder();
      showToast('info', 'Customer Called', res.data?.message || 'Now calling next ticket!');
      await renderQueueTab();
    } catch (e) {
      showToast('error', 'Call Next Error', e.message);
    }
  });

  // Order modal
  document.getElementById('btn-open-order-modal')?.addEventListener('click', () => {
    openOrderModal();
  });

  // Navigate to Completed Orders tab
  const navigateToCompleted = () => {
    state.activeTab = 'completed';
    document.querySelectorAll('.nav-tab').forEach(b => {
      b.classList.toggle('active', b.getAttribute('data-tab') === 'completed');
    });
    renderCurrentTab();
  };
  document.getElementById('btn-goto-completed')?.addEventListener('click', navigateToCompleted);
  document.getElementById('stat-completed-card')?.addEventListener('click', navigateToCompleted);

  // Bind card and banner action buttons
  bindQueueCardActions();
}

// ── New Order Modal ──────────────────────────────────────────────────────────
async function openOrderModal() {
  let products = [];
  try {
    const res = await api.getProducts(true);
    products = res.data?.products || [];
  } catch (e) {
    products = [
      { id: 1, name: 'Hotspot Siomai', price: 45, category: 'Siomai' },
      { id: 2, name: 'Chili Garlic (Small)', price: 25, category: 'Sauces' },
      { id: 3, name: 'Chili Garlic (Large)', price: 45, category: 'Sauces' },
      { id: 4, name: 'Sauce Pack', price: 5, category: 'Sauces' }
    ];
  }

  const modalContainer = document.getElementById('modal-container');
  const cart = {};

  const isSiomaiProduct = (pr) => {
    if (!pr) return false;
    const name = (pr.name || '').toLowerCase();
    const cat = (pr.category || '').toLowerCase();
    return name.includes('siomai') || cat === 'siomai';
  };

  const getAddonType = (pr) => {
    if (!pr) return null;
    const name = (pr.name || '').toLowerCase();
    if (name.includes('calamansi')) return 'calamansi';
    if (name.includes('soy')) return 'soy_sauce';
    if (name.includes('chili') || name.includes('chilli')) return 'chili_garlic';
    return null;
  };

  const getAddonLimits = (totalSiomai) => {
    if (totalSiomai <= 0) {
      return {
        calamansi: { max: 0, unit: 'pcs', name: 'Calamansi' },
        soy_sauce: { max: 0, unit: 'packs', name: 'Soy Sauce' },
        chili_garlic: { max: 0, unit: 'packs', name: 'Chili Garlic' }
      };
    } else if (totalSiomai <= 10) {
      return {
        calamansi: { max: 3, unit: 'pcs', name: 'Calamansi' },
        soy_sauce: { max: 2, unit: 'packs', name: 'Soy Sauce' },
        chili_garlic: { max: 2, unit: 'packs', name: 'Chili Garlic' }
      };
    } else {
      return {
        calamansi: { max: 5, unit: 'pcs', name: 'Calamansi' },
        soy_sauce: { max: 3, unit: 'packs', name: 'Soy Sauce' },
        chili_garlic: { max: 3, unit: 'packs', name: 'Chili Garlic' }
      };
    }
  };

  const calculateTotalSiomai = () => {
    let sum = 0;
    for (const [pid, qty] of Object.entries(cart)) {
      const pr = products.find(p => String(p.id) === String(pid));
      if (pr && isSiomaiProduct(pr)) {
        sum += (qty || 0);
      }
    }
    return sum;
  };

  modalContainer.innerHTML = `
    <div class="modal-backdrop" id="order-modal-backdrop">
      <div class="card modal-box" style="max-width: 600px;" id="order-modal-box">
        <div class="modal-header">
          <h2 class="text-xl font-bold text-white flex items-center gap-2">
            ${Icons.plusCircle({ size: 20, color: 'var(--brand-400)' })} Create Walk-in Order
          </h2>
          <button id="btn-close-modal" class="btn btn-ghost" style="font-size: 20px;">&times;</button>
        </div>

        <div class="modal-body space-y-4">
          <div>
            <label class="block text-xs text-dark-300 font-medium mb-1">Customer Name</label>
            <input type="text" id="order-cust-name" class="input" placeholder="e.g. Juan Dela Cruz" value="Walk-in Customer" />
          </div>

          <div class="grid-2">
            <div>
              <label class="block text-xs text-dark-300 font-medium mb-1">Order Type</label>
              <select id="order-cust-type" class="input">
                <option value="pickup" selected>Takeout / Pick-up</option>
                <option value="dine-in">Dine-in</option>
              </select>
            </div>
            <div>
              <label class="block text-xs text-dark-300 font-medium mb-1">Payment Method</label>
              <select id="order-cust-payment" class="input">
                <option value="Cash" selected>Cash</option>
                <option value="GCash">GCash QR</option>
              </select>
            </div>
          </div>

          <div id="gcash-qr-modal-preview" style="display: none; padding: 14px; background: rgba(0, 125, 254, 0.08); border: 1px solid rgba(0, 125, 254, 0.3); border-radius: 14px; text-align: center;">
            <div style="font-size: 13px; font-weight: bold; color: #60a5fa; margin-bottom: 8px; display: flex; align-items: center; justify-content: center; gap: 6px;">
              ${Icons.creditCard({ size: 15, color: '#60a5fa' })}
              <span>GCash QR Payment</span>
            </div>
            <img src="/images/gcash_qr.png" alt="GCash QR" style="max-height: 180px; margin: 0 auto; border-radius: 10px; border: 2px solid #fff; box-shadow: 0 4px 12px rgba(0,0,0,0.3); display: block;" />
            <div style="font-size: 12px; color: #e2e8f0; font-weight: 600; margin-top: 8px;">
              Account: JO*N LL**D C. &bull; +63 921 296 &bull;&bull;&bull;&bull;
            </div>
            <div style="font-size: 11px; color: #94a3b8; margin-top: 2px;">
              Scan QR code with GCash App to transfer payment.
            </div>
          </div>

          <div>
            <label class="block text-xs text-dark-300 font-medium mb-2">Select Items</label>
            <div class="space-y-2.5" style="max-height: clamp(260px, 44vh, 380px); overflow-y: auto; padding-right: 6px;">
              ${products.map(p => {
                const isActive = p.is_active !== false;
                const addonType = getAddonType(p);
                return `
                <div class="card-sm p-3 flex flex-wrap items-center justify-between gap-2.5" id="order-item-card-${p.id}" style="background: var(--dark-800); height: auto; min-height: 64px; ${!isActive ? 'opacity: 0.55; border: 1px dashed rgba(239,68,68,0.3);' : ''}">
                  <div style="display: flex; align-items: flex-start; gap: 10px; min-width: 180px; flex: 1 1 220px;">
                    ${p.image_url ? `<img src="${escapeHtml(getFreshImageUrl(p.image_url))}" alt="${escapeHtml(p.name)}" style="width: 42px; height: 42px; object-fit: cover; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); flex-shrink: 0; margin-top: 2px; ${!isActive ? 'filter: grayscale(100%);' : ''}" onerror="this.style.display='none'">` : ''}
                    <div style="min-width: 0; flex: 1;">
                      <div class="font-bold text-sm text-white flex flex-wrap items-center gap-1.5" style="line-height: 1.35; word-break: break-word;">
                        <span>${escapeHtml(p.name)}</span>
                        ${!isActive ? '<span class="badge badge-red" style="font-size: 10px; padding: 1px 6px; flex-shrink: 0;">Disabled</span>' : ''}
                        ${addonType ? `<span id="addon-badge-${p.id}" class="badge" style="font-size: 11px; padding: 2px 8px; border-radius: 9999px; font-weight: 700; transition: all 0.2s ease; background: rgba(59, 130, 246, 0.18); color: #60a5fa; border: 1px solid rgba(59, 130, 246, 0.4); flex-shrink: 0;">Max: 0 pcs</span>` : ''}
                      </div>
                      <div class="text-xs text-brand-400 font-semibold mt-0.5" style="line-height: 1.4;">
                        ₱${Number(p.price).toFixed(2)} / ${p.unit || 'pcs'} <span class="text-xs text-dark-400 font-normal">(${p.stock} ${p.unit || 'pcs'} in stock)</span>
                      </div>
                      ${addonType ? `<div id="addon-warning-${p.id}" class="text-xs font-semibold" style="display: none; color: #f87171; margin-top: 3px; line-height: 1.35;"></div>` : ''}
                    </div>
                  </div>
                  <div class="flex items-center gap-1.5" style="flex-shrink: 0; margin-left: auto;">
                    ${!isActive ? `
                      <span class="text-xs text-red-400 font-semibold mr-1">Unavailable</span>
                    ` : `
                      <button type="button" class="btn btn-secondary btn-qty-minus" data-id="${p.id}" style="width: 32px; height: 32px; padding: 0; justify-content: center; font-weight: bold; font-size: 16px;">-</button>
                      <input type="number" min="0" max="${p.stock || 999}" value="0" class="input order-qty-input" id="qty-input-${p.id}" data-id="${p.id}" style="width: 56px; height: 32px; min-height: 32px; text-align: center; font-weight: bold; font-size: 14px; padding: 2px 4px;" />
                      <button type="button" class="btn btn-primary btn-qty-plus" data-id="${p.id}" id="btn-plus-${p.id}" style="width: 32px; height: 32px; padding: 0; justify-content: center; font-weight: bold; font-size: 16px;">+</button>
                    `}
                  </div>
                </div>
              `;
              }).join('')}
            </div>
          </div>
        </div>

        <div class="modal-footer" style="background: var(--dark-800); border-top: 1px solid var(--dark-600); display: flex; align-items: center; justify-content: space-between;">
          <div>
            <div class="text-xs text-dark-300 font-medium">Total Order Amount</div>
            <div class="text-2xl font-bold text-white" id="order-total-display">₱0.00</div>
          </div>
          <button id="btn-submit-order" class="btn btn-primary flex items-center gap-2" style="padding: 10px 24px; font-size: 15px;">
            ${Icons.check({ size: 16 })} Place Order
          </button>
        </div>
      </div>
    </div>
  `;

  const updateTotal = () => {
    let sum = 0;
    for (const [pid, qty] of Object.entries(cart)) {
      const pr = products.find(p => String(p.id) === String(pid));
      if (pr) sum += pr.price * qty;
    }
    const display = document.getElementById('order-total-display');
    if (display) display.textContent = `₱${sum.toFixed(2)}`;
  };

  const updateAddonLimits = (isSiomaiDecrease = false) => {
    const totalSiomai = calculateTotalSiomai();
    const limits = getAddonLimits(totalSiomai);
    const violations = [];

    products.forEach(p => {
      const addonType = getAddonType(p);
      if (!addonType) return;

      const limit = limits[addonType];
      const maxAllowed = limit.max;
      const unit = limit.unit;
      const currentQty = cart[p.id] || 0;
      const stockLimit = typeof p.stock === 'number' ? p.stock : 999;
      const effectiveCap = Math.min(maxAllowed, stockLimit);

      // Display the applicable maximum quantity beside each add-on (Requirement 5)
      const badge = document.getElementById(`addon-badge-${p.id}`);
      if (badge) {
        badge.textContent = `Max: ${maxAllowed} ${unit}`;
        if (maxAllowed === 0) {
          badge.style.background = 'rgba(239, 68, 68, 0.15)';
          badge.style.color = '#f87171';
          badge.style.borderColor = 'rgba(239, 68, 68, 0.3)';
        } else {
          badge.style.background = 'rgba(59, 130, 246, 0.18)';
          badge.style.color = '#60a5fa';
          badge.style.borderColor = 'rgba(59, 130, 246, 0.4)';
        }
      }

      // Disable the increment button when maximum is reached (Requirement 4)
      const plusBtn = document.getElementById(`btn-plus-${p.id}`);
      if (plusBtn) {
        if (currentQty >= effectiveCap || p.is_active === false) {
          plusBtn.disabled = true;
          plusBtn.style.opacity = '0.4';
          plusBtn.style.cursor = 'not-allowed';
        } else {
          plusBtn.disabled = false;
          plusBtn.style.opacity = '1';
          plusBtn.style.cursor = 'pointer';
        }
      }

      const input = document.getElementById(`qty-input-${p.id}`);
      if (input) {
        input.setAttribute('max', effectiveCap);
      }

      // Requirement 3: If siomai decreases, validate existing add-on selections
      // and require the customer to adjust any quantities that exceed the new limits before checkout
      const warningEl = document.getElementById(`addon-warning-${p.id}`);
      if (currentQty > maxAllowed) {
        violations.push({ product: p, qty: currentQty, max: maxAllowed, unit });
        if (warningEl) {
          warningEl.style.display = 'block';
          if (totalSiomai === 0) {
            warningEl.textContent = `⚠️ Requires at least 1 Siomai (Max: 0 ${unit})`;
          } else {
            warningEl.textContent = `⚠️ Exceeds max of ${maxAllowed} ${unit} for ${totalSiomai} pcs siomai!`;
          }
        }
        if (input) {
          input.style.borderColor = '#ef4444';
          input.style.backgroundColor = 'rgba(239, 68, 68, 0.15)';
        }
      } else {
        if (warningEl) {
          warningEl.style.display = 'none';
        }
        if (input) {
          input.style.borderColor = '';
          input.style.backgroundColor = '';
        }
      }
    });

    if (isSiomaiDecrease && violations.length > 0) {
      showToast('warning', 'Add-on Limit Exceeded', 'Siomai quantity decreased. Please adjust add-on quantities exceeding the new limits before placing order.');
    }

    return violations;
  };

  // Direct typed editable quantity input
  modalContainer.querySelectorAll('.order-qty-input').forEach(input => {
    input.addEventListener('input', (e) => {
      const pid = e.target.getAttribute('data-id');
      const pr = products.find(p => String(p.id) === String(pid));
      if (!pr) return;
      let val = parseInt(e.target.value, 10);
      if (isNaN(val) || val < 0) val = 0;

      const addonType = getAddonType(pr);
      const isSiomai = isSiomaiProduct(pr);
      const prevQty = cart[pid] || 0;

      if (addonType) {
        // Requirement 2: Block quantities exceeding the applicable limits, including manually typed quantities
        const currentSiomai = calculateTotalSiomai();
        const limits = getAddonLimits(currentSiomai);
        const maxAllowed = limits[addonType].max;
        const stockLimit = typeof pr.stock === 'number' ? pr.stock : 999;
        const effectiveCap = Math.min(maxAllowed, stockLimit);

        if (val > effectiveCap) {
          val = effectiveCap;
          e.target.value = val;
          if (maxAllowed < stockLimit) {
            showToast('warning', 'Add-on Limit', `Maximum ${maxAllowed} ${limits[addonType].unit} allowed for ${currentSiomai} HotSpot Siomai.`);
          } else {
            showToast('warning', 'Stock Limit', `Only ${pr.stock} ${pr.unit || 'pcs'} available in stock.`);
          }
        }
        cart[pid] = val;
        updateTotal();
        updateAddonLimits(false);
      } else {
        // Normal item or siomai
        if (typeof pr.stock === 'number' && val > pr.stock) {
          val = pr.stock;
          e.target.value = val;
          showToast('warning', 'Stock Limit', `Only ${pr.stock} ${pr.unit || 'pcs'} available.`);
        }
        const isSiomaiDecrease = isSiomai && val < prevQty;
        cart[pid] = val;
        updateTotal();
        updateAddonLimits(isSiomaiDecrease);
      }
    });
  });

  modalContainer.querySelectorAll('.btn-qty-plus').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const pid = e.currentTarget.getAttribute('data-id');
      const pr = products.find(p => String(p.id) === String(pid));
      if (pr && pr.is_active === false) return;
      const current = cart[pid] || 0;
      const addonType = getAddonType(pr);

      if (addonType) {
        const currentSiomai = calculateTotalSiomai();
        const limits = getAddonLimits(currentSiomai);
        const maxAllowed = limits[addonType].max;
        if (current >= maxAllowed) {
          showToast('warning', 'Limit Reached', `Maximum ${maxAllowed} ${limits[addonType].unit} allowed for ${currentSiomai} HotSpot Siomai.`);
          return;
        }
        if (typeof pr.stock === 'number' && current >= pr.stock) {
          showToast('warning', 'Stock Limit', `Only ${pr.stock} ${pr.unit || 'pcs'} available in stock.`);
          return;
        }
        cart[pid] = current + 1;
        const input = document.getElementById(`qty-input-${pid}`);
        if (input) input.value = cart[pid];
        updateTotal();
        updateAddonLimits(false);
      } else {
        if (typeof pr.stock === 'number' && current >= pr.stock) {
          showToast('warning', 'Stock Limit', `Only ${pr.stock} ${pr.unit || 'pcs'} available in stock.`);
          return;
        }
        cart[pid] = current + 1;
        const input = document.getElementById(`qty-input-${pid}`);
        if (input) input.value = cart[pid];
        updateTotal();
        updateAddonLimits(false);
      }
    });
  });

  modalContainer.querySelectorAll('.btn-qty-minus').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const pid = e.currentTarget.getAttribute('data-id');
      const pr = products.find(p => String(p.id) === String(pid));
      if (cart[pid] > 0) {
        cart[pid] -= 1;
        const input = document.getElementById(`qty-input-${pid}`);
        if (input) input.value = cart[pid];
        updateTotal();
        const isSiomai = isSiomaiProduct(pr);
        updateAddonLimits(isSiomai);
      }
    });
  });

  // Initial call to set addon badges and button states (0 siomai = 0 max)
  updateAddonLimits(false);

  const handleCloseOrderModal = async () => {
    const hasItems = Object.values(cart).some(qty => qty > 0);
    if (hasItems) {
      const confirmed = await swal.confirm({
        title: 'Discard Order?',
        text: 'You have items selected in your current order. Are you sure you want to discard them?',
        icon: 'warning',
        confirmText: 'Discard Order',
        cancelText: 'Keep Ordering',
        isDestructive: true
      });
      if (!confirmed) return;
    }
    modalContainer.innerHTML = '';
  };

  document.getElementById('btn-close-modal')?.addEventListener('click', handleCloseOrderModal);

  const custPaymentSelect = document.getElementById('order-cust-payment');
  const gcashModalPreview = document.getElementById('gcash-qr-modal-preview');
  if (custPaymentSelect && gcashModalPreview) {
    custPaymentSelect.addEventListener('change', () => {
      gcashModalPreview.style.display = custPaymentSelect.value === 'GCash' ? 'block' : 'none';
    });
  }

  document.getElementById('order-modal-backdrop')?.addEventListener('click', (e) => {
    if (e.target.id === 'order-modal-backdrop') {
      handleCloseOrderModal();
    }
  });

  document.getElementById('btn-submit-order')?.addEventListener('click', async () => {
    const items = [];
    let total = 0;
    for (const [pid, qty] of Object.entries(cart)) {
      if (qty > 0) {
        const pr = products.find(p => String(p.id) === String(pid));
        if (pr) {
          items.push({
            product_id: pr.id,
            product_name: pr.name,
            quantity: qty,
            price: pr.price,
            subtotal: pr.price * qty
          });
          total += pr.price * qty;
        }
      }
    }

    if (items.length === 0) {
      swal.warning({
        title: 'Empty Order',
        text: 'Please select at least one siomai or drink item before placing an order.',
        confirmButtonText: 'Understood'
      });
      return;
    }

    // Requirement 3 & 6: Validate add-on restrictions before checkout
    const violations = updateAddonLimits(false);
    if (violations && violations.length > 0) {
      const currentSiomai = calculateTotalSiomai();
      const violationLines = violations.map(v =>
        `• <b>${escapeHtml(v.product.name)}</b>: ${v.qty} ${v.unit} (Maximum: ${v.max} ${v.unit})`
      ).join('<br>');

      swal.fire({
        icon: 'warning',
        title: 'Adjust Add-on Quantities',
        html: `Your order has add-ons that exceed the maximum limit for <b>${currentSiomai} pcs HotSpot Siomai</b>:<br><br><div style="text-align: left; background: rgba(239,68,68,0.12); border: 1px solid rgba(239,68,68,0.3); border-radius: 8px; padding: 12px 14px; font-size: 13px; color: #fca5a5;">${violationLines}</div><br>Please reduce your add-on quantities to meet the limits before checking out.`,
        confirmButtonText: 'Adjust Quantities',
        confirmButtonColor: '#f97316'
      });
      return;
    }

    const nameInput = document.getElementById('order-cust-name');
    const rawCustomerName = (nameInput?.value || '').trim();
    let customerName = 'Walk-in Customer';
    if (rawCustomerName) {
      const nameVal = validatePersonName(rawCustomerName, 'Customer Name');
      if (!nameVal.valid) {
        swal.warning({
          title: 'Invalid Customer Name',
          text: nameVal.error,
          confirmButtonText: 'Correct Name'
        });
        nameInput?.focus();
        return;
      }
      customerName = nameVal.value;
    }

    const orderType = document.getElementById('order-cust-type').value;
    const paymentMethod = document.getElementById('order-cust-payment').value;

    const orderPayload = {
      type: 'walk-in',
      order_type: orderType,
      customer_name: customerName,
      customer_phone: '',
      items: items,
      total: total,
      payment_method: paymentMethod,
      payment_status: 'pending'
    };

    modalContainer.innerHTML = '';

    swal.loading({
      title: 'Placing Order...',
      text: `Processing order for ${escapeHtml(customerName)}...`
    });

    // Offline / Online routing
    if (!state.isOnline) {
      try {
        await db.saveOfflineOrder(orderPayload);
        await refreshPendingCount();
        playBeep();
        await swal.fire({
          icon: 'info',
          title: 'Order Saved Offline',
          html: `Network is offline. Order for <b>${escapeHtml(customerName)}</b> has been saved locally to IndexedDB and will automatically sync when reconnected.<br><br><b>Total: ₱${total.toFixed(2)}</b> (${paymentMethod})`,
          confirmButtonText: 'Got It'
        });
      } catch (err) {
        swal.error({
          title: 'Offline Save Failed',
          text: err.message
        });
      }
    } else {
      try {
        const res = await api.addToQueue(orderPayload);
        playBeep();
        const ticketNo = res.data?.order?.queue_no || res.data?.queue?.current_queue_no || '—';
        await swal.fire({
          icon: 'success',
          title: 'Order Placed Successfully!',
          html: `
            <div style="font-size: 15px; margin-top: 8px;">
              Queue Ticket: <strong style="font-size: 19px; color: var(--brand-500);">#${ticketNo}</strong>
            </div>
            <div style="margin-top: 5px;">
              Customer: <strong>${escapeHtml(customerName)}</strong> &bull; <span style="text-transform: capitalize;">${escapeHtml(orderType)}</span>
            </div>
            <div style="font-size: 16px; font-weight: 700; margin-top: 10px; color: var(--emerald-500);">
              Total: ₱${total.toFixed(2)} &bull; ${paymentMethod}
            </div>
          `,
          confirmButtonText: 'Done'
        });
        await renderQueueTab();
      } catch (err) {
        swal.error({
          title: 'Order Placement Failed',
          text: err.response?.data?.error || err.message
        });
      }
    }
  });
}

// ==============================================================================
// 2.5. COMPLETED ORDERS VIEW (HTML & JS)
// ==============================================================================

async function fetchCompletedOrders() {
  try {
    state.completedLoading = true;
    const res = await api.getOrders({ status: 'completed', limit: 500 });
    state.completedOrders = res.data?.orders || [];
  } catch (err) {
    console.warn('Completed orders fetch error:', err);
    state.completedOrders = [];
  } finally {
    state.completedLoading = false;
  }
}

function getFilteredCompletedOrders() {
  let list = (state.completedOrders || []).filter(o => o.status !== 'cancelled');

  // 1. Date Filter (using Philippine Asia/Manila date boundaries on order creation time)
  if (state.completedFilter && state.completedFilter !== 'All') {
    const now = new Date();
    const todayKey = getManilaDateKey(now);
    const yesterdayKey = getManilaDateKey(new Date(now.getTime() - 86400000));
    const sevenDaysAgoKey = getManilaDateKey(new Date(now.getTime() - 7 * 86400000));

    if (state.completedFilter === 'Today') {
      list = list.filter(o => {
        const key = getManilaDateKey(o.created_at || o.timestamp || o.updated_at);
        return key === todayKey;
      });
    } else if (state.completedFilter === 'Yesterday') {
      list = list.filter(o => {
        const key = getManilaDateKey(o.created_at || o.timestamp || o.updated_at);
        return key === yesterdayKey;
      });
    } else if (state.completedFilter === 'Last 7 Days') {
      list = list.filter(o => {
        const key = getManilaDateKey(o.created_at || o.timestamp || o.updated_at);
        return key >= sevenDaysAgoKey && key <= todayKey;
      });
    }
  }

  // 2. Payment Method Filter
  if (state.completedPaymentFilter && state.completedPaymentFilter !== 'All') {
    const payFilter = state.completedPaymentFilter.toLowerCase();
    list = list.filter(o => {
      const pm = (o.payment_method || o.payment?.method || 'cash').toLowerCase();
      return pm.includes(payFilter);
    });
  }

  // 3. Order Type Filter
  if (state.completedTypeFilter && state.completedTypeFilter !== 'All') {
    const typeFilter = state.completedTypeFilter.toLowerCase();
    list = list.filter(o => {
      const ot = (o.order_type || o.type || 'walk-in').toLowerCase();
      return ot.includes(typeFilter);
    });
  }

  // 4. Search Filter
  if (state.completedSearch) {
    const q = state.completedSearch.toLowerCase().trim();
    list = list.filter(o => {
      const name = (o.customer_name || '').toLowerCase();
      const qNo = String(o.queue_no || o.queue_number || '');
      const id = String(o.id || '');
      const itemsStr = (o.items || []).map(i => i.product_name || i.name || '').join(' ').toLowerCase();
      return name.includes(q) || qNo.includes(q) || id.includes(q) || itemsStr.includes(q);
    });
  }

  // Sort newest first by original order creation timestamp
  return list.sort((a, b) => {
    const da = parseOrderUtcDate(b.created_at || b.timestamp || b.updated_at)?.getTime() || 0;
    const db = parseOrderUtcDate(a.created_at || a.timestamp || a.updated_at)?.getTime() || 0;
    return da - db;
  });
}

async function renderCompletedTab(showSpinner = true) {
  const container = document.getElementById('tab-content');
  if (!container) return;

  if (showSpinner) {
    container.innerHTML = `
      <div class="flex items-center justify-center p-12">
        <div class="spinner"></div>
      </div>
    `;
    await fetchCompletedOrders();
  } else {
    await fetchCompletedOrders();
  }

  const allCompleted = state.completedOrders || [];
  const validCompleted = allCompleted.filter(o => !['cancelled'].includes(o.status));
  const todayKey = getManilaDateKey(new Date());

  const todayCompleted = validCompleted.filter(o => getManilaDateKey(o.created_at || o.timestamp || o.updated_at) === todayKey);
  const paidCompleted = validCompleted.filter(o => isOrderPaid(o));
  const totalRev = paidCompleted.reduce((sum, o) => sum + Number(o.total || o.total_amount || 0), 0);
  const cashRev = paidCompleted.filter(o => (o.payment_method || 'cash').toLowerCase().includes('cash'))
                               .reduce((sum, o) => sum + Number(o.total || o.total_amount || 0), 0);
  const gcashRev = paidCompleted.filter(o => (o.payment_method || '').toLowerCase().includes('gcash'))
                                .reduce((sum, o) => sum + Number(o.total || o.total_amount || 0), 0);

  const filtered = getFilteredCompletedOrders();

  container.innerHTML = `
    <!-- Top Action Bar -->
    <div class="flex flex-wrap items-center justify-between gap-4 mb-6">
      <div>
        <h1 class="text-2xl font-bold text-white">Completed Orders</h1>
      </div>

      <div class="flex items-center gap-3">
        <button id="btn-back-to-queue" class="btn btn-secondary flex items-center gap-1.5" title="Switch back to active Queue">
          ${Icons.queue({ size: 15 })} Back to Live Queue
        </button>
        <button id="btn-refresh-completed" class="btn btn-secondary flex items-center gap-1.5" title="Reload completed orders">
          ${Icons.refresh({ size: 15 })} Refresh
        </button>
      </div>
    </div>

    <!-- Stat Cards Bar -->
    <div class="grid-4 mb-6">
      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(16,185,129,0.2); color: var(--emerald-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.checkCircle({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">TOTAL COMPLETED</div>
          <div class="text-3xl font-bold text-emerald-400">${validCompleted.length}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(249,115,22,0.2); color: var(--brand-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.clock({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">COMPLETED TODAY</div>
          <div class="text-3xl font-bold text-white">${todayCompleted.length}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(59,130,246,0.2); color: var(--blue-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.coins({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">REVENUE COLLECTED</div>
          <div class="text-3xl font-bold text-white">₱${totalRev.toFixed(2)}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(168,85,247,0.2); color: #c084fc; display: flex; align-items: center; justify-content: center;">
          ${Icons.creditCard({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">PAYMENT BREAKDOWN</div>
          <div class="text-xl font-bold text-white" style="line-height: 1.3;">
            <span class="text-emerald-400" title="Cash">₱${cashRev.toFixed(0)}</span> <span class="text-dark-400" style="font-size: 13px;">Cash</span> &bull; 
            <span class="text-blue-400" title="GCash">₱${gcashRev.toFixed(0)}</span> <span class="text-dark-400" style="font-size: 13px;">GCash</span>
          </div>
        </div>
      </div>
    </div>

    <!-- Filters and Search Bar -->
    <div class="flex flex-wrap items-center justify-between gap-4 mb-4">
      <div class="flex items-center gap-3 flex-wrap">
        <!-- Date Pills -->
        <div class="tab-bar" id="completed-date-tabs">
          ${['All', 'Today', 'Yesterday', 'Last 7 Days'].map(filter => `
            <button class="tab-btn ${state.completedFilter === filter ? 'active' : ''}" data-completed-date="${filter}">
              ${filter}
            </button>
          `).join('')}
        </div>

        <!-- Payment Filter Select -->
        <select id="completed-payment-filter" class="input" style="width: 130px; height: 38px; padding: 6px 10px; font-size: 13px;">
          <option value="All" ${state.completedPaymentFilter === 'All' ? 'selected' : ''}>All Payments</option>
          <option value="Cash" ${state.completedPaymentFilter === 'Cash' ? 'selected' : ''}>Cash Only</option>
          <option value="GCash" ${state.completedPaymentFilter === 'GCash' ? 'selected' : ''}>GCash QR</option>
        </select>

        <!-- Order Type Filter Select -->
        <select id="completed-type-filter" class="input" style="width: 140px; height: 38px; padding: 6px 10px; font-size: 13px;">
          <option value="All" ${state.completedTypeFilter === 'All' ? 'selected' : ''}>All Types</option>
          <option value="pickup" ${state.completedTypeFilter === 'pickup' ? 'selected' : ''}>Takeout / Pickup</option>
          <option value="dine-in" ${state.completedTypeFilter === 'dine-in' ? 'selected' : ''}>Dine-in</option>
          <option value="delivery" ${state.completedTypeFilter === 'delivery' ? 'selected' : ''}>Delivery (Gatid)</option>
        </select>
      </div>

      <div style="position: relative; width: 280px;">
        <input type="text" id="completed-search" class="input" placeholder="Search customer, queue #, item..." value="${escapeHtml(state.completedSearch || '')}" />
      </div>
    </div>

    <!-- Completed Orders Grid -->
    <div class="completed-orders-grid" id="completed-orders-container">
      ${renderCompletedCards(filtered)}
    </div>

    <!-- Pagination Controls -->
    <div id="completed-pagination-controls" style="margin-top: 16px;"></div>
  `;

  bindCompletedEvents(filtered);
}

function renderCompletedCards(filtered) {
  const perPage = state.completedPerPage || 8;
  const totalFiltered = filtered.length;
  const totalPages = Math.ceil(totalFiltered / perPage);

  if (state.completedPage < 1) state.completedPage = 1;
  if (state.completedPage > totalPages && totalPages > 0) state.completedPage = totalPages;

  const start = (state.completedPage - 1) * perPage;
  const paginated = filtered.slice(start, start + perPage);

  // Pagination Controls Deferred Render
  setTimeout(() => {
    const paginationEl = document.getElementById('completed-pagination-controls');
    if (paginationEl && totalPages > 1) {
      let pagesHtml = `<div class="flex items-center justify-center gap-2" style="flex-wrap: wrap;">`;
      pagesHtml += `<button class="btn btn-secondary btn-completed-page" data-page="${state.completedPage - 1}" ${state.completedPage <= 1 ? 'disabled' : ''} style="padding: 6px 12px;">← Prev</button>`;
      for (let i = 1; i <= totalPages; i++) {
        pagesHtml += `<button class="btn ${i === state.completedPage ? 'btn-primary' : 'btn-secondary'} btn-completed-page" data-page="${i}" style="padding: 6px 12px; min-width: 36px;">${i}</button>`;
      }
      pagesHtml += `<button class="btn btn-secondary btn-completed-page" data-page="${state.completedPage + 1}" ${state.completedPage >= totalPages ? 'disabled' : ''} style="padding: 6px 12px;">Next →</button>`;
      pagesHtml += `<span class="text-xs text-dark-400" style="margin-left: 8px;">Page ${state.completedPage} of ${totalPages} (${totalFiltered} completed orders)</span>`;
      pagesHtml += `</div>`;
      paginationEl.innerHTML = pagesHtml;

      paginationEl.querySelectorAll('.btn-completed-page').forEach(btn => {
        btn.addEventListener('click', (e) => {
          const newPage = parseInt(e.currentTarget.getAttribute('data-page'), 10);
          if (!isNaN(newPage) && newPage >= 1 && newPage <= totalPages) {
            state.completedPage = newPage;
            const container = document.getElementById('completed-orders-container');
            if (container) {
              container.innerHTML = renderCompletedCards(getFilteredCompletedOrders());
              bindCompletedCardButtons();
            }
          }
        });
      });
    } else if (paginationEl) {
      paginationEl.innerHTML = '';
    }
  }, 0);

  if (paginated.length === 0) {
    return `
      <div class="card p-8 text-center" style="grid-column: 1 / -1;">
        <div style="margin-bottom: 8px; color: var(--emerald-400);">${Icons.checkCircle({ size: 40, strokeWidth: 1.5 })}</div>
        <h3 class="text-lg font-bold text-white">No Completed Orders Found</h3>
        <p class="text-sm text-dark-300 mt-1">There are currently no completed orders matching your filters.</p>
      </div>
    `;
  }

  return paginated.map(order => {
    const queueNo = order.queue_no || order.queue_number || order.id;
    const totalVal = Number(order.total || order.total_amount || 0).toFixed(2);
    const dateFormatted = formatOrderDate(order.created_at || order.timestamp || order.updated_at);
    const payMethod = order.payment_method || 'Cash';
    const isGCash = payMethod.toLowerCase().includes('gcash');
    const isPaid = isOrderPaid(order);

    return `
      <div class="completed-card" data-order-id="${order.id}">
        <div>
          <!-- Header: Queue & Order ID & Status -->
          <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
            <div class="flex flex-wrap items-center gap-2">
              <span style="font-size: 16px; font-weight: 800; color: var(--emerald-400);">#${queueNo}</span>
              <span class="badge badge-green" style="font-size: 11px;">Completed</span>
              <span class="badge ${getPaymentStatusBadgeClass(order)}" style="font-size: 11px;">${getPaymentStatusLabel(order)}</span>
              <span class="badge ${order.order_type === 'delivery' ? 'badge-amber' : 'badge-gray'}">${order.order_type === 'delivery' ? 'Delivery (Gatid)' : (order.order_type || order.type || 'Walk-in')}</span>
            </div>
            <span class="text-xs text-dark-400 font-mono">Order #${order.id}</span>
          </div>

          <!-- Customer & Date -->
          <div class="mb-3">
            <div class="font-bold text-white text-base">${escapeHtml(order.customer_name || 'Walk-in Customer')}</div>
            <div class="text-xs text-dark-400 flex items-center gap-1 mt-1">
              ${Icons.clock({ size: 12, color: 'var(--dark-400)' })} ${dateFormatted}
            </div>
            ${order.delivery_address ? `
              <div class="text-xs text-amber-300 mt-2 p-2 rounded bg-amber-950/30 border border-amber-800/40 flex items-start gap-1.5">
                <span class="mt-0.5 text-amber-400">${Icons.pin({ size: 13 })}</span>
                <span><strong>Address:</strong> ${escapeHtml(order.delivery_address)}</span>
              </div>
            ` : ''}
          </div>

          <!-- Items with Units & Thumbnails -->
          <div class="mb-4 pt-2 border-t" style="border-color: rgba(255,255,255,0.06);">
            <div class="text-xs text-dark-300 font-medium mb-1.5">Fulfilled Items:</div>
            <div style="display: flex; flex-direction: column; gap: 6px;">
              ${(order.items && order.items.length) ? order.items.map(i => {
                const qty = i.quantity || i.qty || 1;
                const name = i.product_name || i.name || 'Siomai';
                const unit = i.unit || (name.toLowerCase().includes('royal') ? 'bottles' : (name.toLowerCase().includes('coke') || name.toLowerCase().includes('sprite')) ? 'cans' : (name.toLowerCase().includes('chilli') || name.toLowerCase().includes('soy') || name.toLowerCase().includes('calamansi')) ? 'packs' : 'pcs');
                const price = Number(i.price || 0).toFixed(2);
                const subtotal = Number(i.subtotal || (i.price * qty) || 0).toFixed(2);
                const img = i.image_url || getProductImageUrl(name);
                return `
                  <div style="display: flex; align-items: center; justify-content: space-between; padding: 5px 8px; border-radius: 8px; background: rgba(255,255,255,0.04); font-size: 12px; gap: 8px;">
                    <div style="display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1;">
                      <img src="${escapeHtml(img)}" alt="${escapeHtml(name)}" style="width: 22px; height: 22px; border-radius: 5px; object-fit: cover; flex-shrink: 0;" onerror="this.style.display='none'">
                      <span class="text-white" style="word-break: break-word; line-height: 1.35;">
                        <strong>${qty} ${unit}</strong> &bull; ${escapeHtml(name)}
                      </span>
                    </div>
                    <span class="text-dark-300 font-mono" style="flex-shrink: 0; margin-left: 8px;">₱${subtotal}</span>
                  </div>
                `;
              }).join('') : `
                <div style="font-size: 12px; color: var(--dark-400);">1 order fulfilled</div>
              `}
            </div>
          </div>
        </div>

        <!-- Footer: Total, Payment Method, Confirm Payment, and View Receipt Button -->
        <div class="pt-3 border-t flex flex-wrap items-center justify-between gap-2" style="border-color: rgba(255,255,255,0.08);">
          <div>
            <div class="text-xs text-dark-400 flex items-center gap-1.5">
              <span class="flex items-center gap-1">${isGCash ? `${Icons.creditCard({ size: 13, color: 'var(--blue-400)' })} GCash` : `${Icons.coins({ size: 13, color: 'var(--emerald-400)' })} Cash`}</span>
              <span class="badge ${isPaid ? (isGCash ? 'badge-blue' : 'badge-green') : 'badge-yellow'}" style="font-size: 10px; padding: 1px 6px;">${isPaid ? 'PAID' : 'PENDING PAYMENT'}</span>
            </div>
            <div class="font-bold text-emerald-400 text-lg">₱${totalVal}</div>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            ${!isPaid ? `
              <button class="btn btn-primary btn-confirm-payment flex items-center gap-1.5" data-id="${order.id}" data-method="${escapeHtml(payMethod)}" style="font-size: 12px; padding: 6px 12px;">
                ${Icons.creditCard({ size: 14 })} Confirm Payment
              </button>
            ` : ''}
            <button class="btn btn-secondary btn-view-receipt flex items-center gap-1.5" data-id="${order.id}" style="font-size: 12px; padding: 6px 12px;">
              ${Icons.printer({ size: 14 })} View Receipt
            </button>
          </div>
        </div>
      </div>
    `;
  }).join('');
}

function bindCompletedEvents(filtered) {
  // Back to Live Queue button
  document.getElementById('btn-back-to-queue')?.addEventListener('click', () => {
    state.activeTab = 'queue';
    document.querySelectorAll('.nav-tab').forEach(b => {
      b.classList.toggle('active', b.getAttribute('data-tab') === 'queue');
    });
    renderCurrentTab();
  });

  // Refresh button
  document.getElementById('btn-refresh-completed')?.addEventListener('click', () => {
    renderCompletedTab(true);
  });

  // Date tabs
  document.querySelectorAll('#completed-date-tabs .tab-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const f = e.currentTarget.getAttribute('data-completed-date');
      if (f) {
        state.completedFilter = f;
        state.completedPage = 1;
        document.querySelectorAll('#completed-date-tabs .tab-btn').forEach(b => b.classList.remove('active'));
        e.currentTarget.classList.add('active');
        updateCompletedView();
      }
    });
  });

  // Payment method filter
  document.getElementById('completed-payment-filter')?.addEventListener('change', (e) => {
    state.completedPaymentFilter = e.target.value;
    state.completedPage = 1;
    updateCompletedView();
  });

  // Order type filter
  document.getElementById('completed-type-filter')?.addEventListener('change', (e) => {
    state.completedTypeFilter = e.target.value;
    state.completedPage = 1;
    updateCompletedView();
  });

  // Search input
  document.getElementById('completed-search')?.addEventListener('input', (e) => {
    state.completedSearch = e.target.value;
    state.completedPage = 1;
    updateCompletedView();
  });

  bindCompletedCardButtons();
}

function updateCompletedView() {
  const container = document.getElementById('completed-orders-container');
  if (container) {
    const filtered = getFilteredCompletedOrders();
    container.innerHTML = renderCompletedCards(filtered);
    bindCompletedCardButtons();
  }
}

function bindCompletedCardButtons() {
  document.querySelectorAll('.btn-view-receipt').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const id = e.currentTarget.getAttribute('data-id');
      const order = (state.completedOrders || []).find(o => String(o.id) === String(id));
      if (order) openReceiptModal(order);
    });
  });

  document.querySelectorAll('.btn-confirm-payment').forEach(btn => {
    btn.addEventListener('click', async (e) => {
      const targetBtn = e.currentTarget;
      const id = targetBtn.getAttribute('data-id');
      const method = targetBtn.getAttribute('data-method') || 'Cash';
      await handleConfirmPayment(id, method, targetBtn);
    });
  });
}

function openReceiptModal(order) {
  const modalContainer = document.getElementById('modal-container');
  if (!modalContainer || !order) return;

  const queueNo = order.queue_no || order.queue_number || order.id;
  const totalVal = Number(order.total ?? order.total_amount ?? 0).toFixed(2);
  const dateFormatted = formatOrderDate(order.created_at || order.timestamp || order.updated_at);
  const paymentMethod = order.payment_method || order.payment?.method || 'Cash';
  const isGCash = paymentMethod.toLowerCase().includes('gcash');
  const isPaid = isOrderPaid(order);
  const customerPhone = (order.customer_phone || '').trim();

  modalContainer.innerHTML = `
    <div class="modal-backdrop" id="receipt-modal-backdrop">
      <div class="card modal-box" style="max-width: 440px; padding: 0;" id="receipt-modal-box">
        <div class="modal-header no-print" style="background: var(--dark-800); border-bottom: 1px solid var(--dark-600); padding: 14px 20px;">
          <h2 class="text-lg font-bold text-white flex items-center gap-2">
            ${Icons.printer({ size: 18, color: 'var(--emerald-400)' })} Order Receipt #${order.id}
          </h2>
          <button id="btn-close-receipt-modal" class="btn btn-ghost" style="font-size: 20px;">&times;</button>
        </div>

        <div class="modal-body p-6" style="background: #ffffff; color: #171717;">
          <div id="receipt-printable-area" class="receipt-paper" style="padding: 4px 2px; box-shadow: none;">
            <div class="receipt-header-block" style="text-align: center; margin-bottom: 12px;">
              <div style="display: inline-flex; align-items: center; justify-content: center; background: #171717; padding: 8px 14px; border-radius: 10px; margin-bottom: 6px; -webkit-print-color-adjust: exact; print-color-adjust: exact;">
                ${Icons.brandLockup({ height: 36 })}
              </div>
              <div style="font-size: 11px; color: #525252; margin-top: 2px;">Gatid, Santa Cruz, Laguna &bull; Philippines</div>
              <div style="font-size: 11px; color: #525252;">Contact: +63 921 296 0000</div>
            </div>

            <div class="receipt-dashed-line"></div>

            <div class="receipt-section" style="margin-bottom: 4px;">
              <div class="receipt-row" style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #525252; flex-shrink: 0;">Queue Ticket:</span>
                <strong style="font-size: 14px; color: #dc2626; text-align: right;">#${queueNo}</strong>
              </div>
              <div class="receipt-row" style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #525252; flex-shrink: 0;">Order ID:</span>
                <strong style="text-align: right;">#${order.id}</strong>
              </div>
              <div class="receipt-row" style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #525252; flex-shrink: 0;">Customer:</span>
                <strong style="text-align: right; word-break: break-word;">${escapeHtml(order.customer_name || 'Walk-in Customer')}</strong>
              </div>
              ${customerPhone ? `
              <div class="receipt-row" style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #525252; flex-shrink: 0;">Contact No.:</span>
                <span style="text-align: right;">${escapeHtml(customerPhone)}</span>
              </div>
              ` : ''}
              <div class="receipt-row" style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #525252; flex-shrink: 0;">Order Type:</span>
                <strong style="text-transform: capitalize; text-align: right;">${escapeHtml(order.order_type || order.type || 'Walk-in')}</strong>
              </div>
              <div class="receipt-row" style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #525252; flex-shrink: 0;">Date & Time:</span>
                <span style="text-align: right;">${dateFormatted}</span>
              </div>
              <div class="receipt-row" style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #525252; flex-shrink: 0;">Cashier:</span>
                <span style="text-align: right;">${escapeHtml(state.user?.full_name || state.user?.username || 'Staff')}</span>
              </div>
            </div>

            <div class="receipt-dashed-line"></div>

            <div class="receipt-items-block" style="margin: 8px 0;">
              <div class="receipt-row" style="display: flex; justify-content: space-between; font-size: 11px; font-weight: bold; color: #525252; text-transform: uppercase; margin-bottom: 6px;">
                <span style="flex: 1;">Item [Unit]</span>
                <span style="width: 90px; text-align: center;">Qty &times; Price</span>
                <span style="width: 70px; text-align: right;">Amount</span>
              </div>

              ${(order.items && order.items.length) ? order.items.map(i => {
                const qty = Number(i.quantity ?? i.qty ?? 1);
                const name = i.product_name || i.name || 'Siomai';
                const unit = i.unit || (name.toLowerCase().includes('royal') ? 'bottles' : (name.toLowerCase().includes('coke') || name.toLowerCase().includes('sprite')) ? 'cans' : (name.toLowerCase().includes('chilli') || name.toLowerCase().includes('soy') || name.toLowerCase().includes('calamansi')) ? 'packs' : 'pcs');
                const rawUnitPrice = Number(i.unit_price ?? i.price ?? 0);
                const price = rawUnitPrice.toFixed(2);
                const subtotal = Number(i.subtotal ?? (rawUnitPrice * qty) ?? 0).toFixed(2);
                return `
                  <div class="receipt-item-row" style="display: flex; justify-content: space-between; align-items: flex-start; font-size: 12px; margin-bottom: 5px; line-height: 1.35;">
                    <span style="flex: 1; padding-right: 8px; word-break: break-word;">
                      <strong>${escapeHtml(name)}</strong>
                      <span style="font-size: 11px; color: #525252;"> (${escapeHtml(unit)})</span>
                    </span>
                    <span style="width: 90px; text-align: center; color: #525252; flex-shrink: 0;">
                      ${qty} &times; ₱${price}
                    </span>
                    <span style="width: 70px; text-align: right; font-weight: bold; flex-shrink: 0;">
                      ₱${subtotal}
                    </span>
                  </div>
                `;
              }).join('') : `
                <div style="font-size: 12px; text-align: center; color: #525252;">1 order item</div>
              `}
            </div>

            <div class="receipt-dashed-line"></div>

            <div class="receipt-totals-block">
              <div class="receipt-row" style="display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #525252;">Subtotal:</span>
                <span>₱${totalVal}</span>
              </div>
              <div class="receipt-row" style="display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #525252;">Tax / VAT (12%):</span>
                <span style="color: #525252;">Included</span>
              </div>
              <div class="receipt-row" style="display: flex; justify-content: space-between; font-size: 15px; font-weight: 900; margin-top: 6px;">
                <span>${isPaid ? 'TOTAL PAID:' : 'TOTAL DUE:'}</span>
                <span style="color: ${isPaid ? '#16a34a' : '#d97706'};">₱${totalVal}</span>
              </div>
              <div class="receipt-row" style="display: flex; justify-content: space-between; font-size: 12px; margin-top: 4px;">
                <span style="color: #525252;">Payment Method:</span>
                <strong style="color: ${isPaid ? (isGCash ? '#2563eb' : '#16a34a') : '#d97706'};">${escapeHtml(paymentMethod)} (${isPaid ? 'Paid' : 'Pending Payment'})</strong>
              </div>
            </div>

            <div class="receipt-dashed-line"></div>

            <div class="receipt-footer-block" style="text-align: center; font-size: 11px; color: #525252; margin-top: 10px;">
              <div>Thank you for craving with Kevs Siomai!</div>
              <div style="margin-top: 2px;">*** MARAMING SALAMAT PO! ***</div>
            </div>
          </div>
        </div>

        <div class="modal-footer no-print" style="background: var(--dark-800); border-top: 1px solid var(--dark-600); display: flex; align-items: center; justify-content: space-between; padding: 12px 20px;">
          <button id="btn-print-receipt" class="btn btn-primary flex items-center gap-1.5" style="padding: 8px 18px;">
            ${Icons.printer({ size: 16 })} Print Official Receipt
          </button>
          <button id="btn-close-receipt-bottom" class="btn btn-secondary" style="padding: 8px 18px;">
            Close
          </button>
        </div>
      </div>
    </div>
  `;

  document.getElementById('btn-close-receipt-modal')?.addEventListener('click', () => {
    modalContainer.innerHTML = '';
  });
  document.getElementById('btn-close-receipt-bottom')?.addEventListener('click', () => {
    modalContainer.innerHTML = '';
  });
  document.getElementById('receipt-modal-backdrop')?.addEventListener('click', (e) => {
    if (e.target.id === 'receipt-modal-backdrop') modalContainer.innerHTML = '';
  });

  document.getElementById('btn-print-receipt')?.addEventListener('click', () => {
    window.print();
  });
}

// ==============================================================================
// 3. INVENTORY VIEW (HTML & JS)
// ==============================================================================

function matchInventoryCategory(product, selectedCategory) {
  if (!selectedCategory || selectedCategory === 'All') return true;
  if (!product) return false;

  const cat = (product.category || '').toLowerCase().trim();
  const name = (product.name || '').toLowerCase().trim();

  if (selectedCategory === 'Hotspot Siomai') {
    return cat === 'hotspot siomai' ||
           cat === 'siomai' ||
           cat.includes('siomai') ||
           cat.includes('dumpling') ||
           name.includes('siomai');
  }

  if (selectedCategory === 'Drinks') {
    return cat === 'drinks' ||
           cat === 'drink' ||
           cat.includes('drink') ||
           cat.includes('beverage') ||
           ['coke', 'royal', 'sprite', 'water', 'juice'].some(d => name.includes(d));
  }

  if (selectedCategory === 'Add-ons') {
    return cat === 'add-ons' ||
           cat === 'addons' ||
           cat === 'add ons' ||
           cat === 'sauces' ||
           cat === 'sauce' ||
           cat.includes('add') ||
           cat.includes('sauce') ||
           cat.includes('condiment') ||
           ['chilli', 'chili', 'garlic', 'soy', 'calamansi'].some(s => name.includes(s));
  }

  return cat === selectedCategory.toLowerCase().trim();
}

function getFilteredInventory(products) {
  return (products || []).filter(p => {
    if (!matchInventoryCategory(p, state.inventoryFilter)) return false;
    if (state.inventorySearch) {
      const q = state.inventorySearch.toLowerCase().trim();
      const name = (p.name || '').toLowerCase();
      const desc = (p.description || '').toLowerCase();
      const cat = (p.category || '').toLowerCase();
      return name.includes(q) || desc.includes(q) || cat.includes(q);
    }
    return true;
  });
}

function renderInventoryRows(products) {
  const filtered = getFilteredInventory(products);
  if (filtered.length === 0) {
    return `
      <tr>
        <td colspan="7" class="py-8 text-center text-dark-300">
          <div style="padding: 28px 16px; color: var(--dark-400);">
            No items found in <strong>${escapeHtml(state.inventoryFilter || 'All')}</strong>${state.inventorySearch ? ` matching "<em>${escapeHtml(state.inventorySearch)}</em>"` : ''}.
          </div>
        </td>
      </tr>
    `;
  }

  return filtered.map(p => {
    const isActive = p.is_active !== false;
    const min = Number(p.min_stock || 15);
    const max = Number(p.max_stock || 100);
    const curStock = Number(p.stock ?? 0);
    const pct = max > 0 ? Math.min(100, Math.max(0, Math.round((curStock / max) * 100))) : 0;
    const isLow = curStock <= min && curStock > 0;
    const isOut = curStock <= 0;
    const unitStr = escapeHtml(p.unit || 'pcs');

    return `
      <tr style="border-bottom: 1px solid var(--dark-600); font-size: 14px; ${!isActive ? 'background: rgba(239, 68, 68, 0.05); opacity: 0.8;' : ''}">
        <td class="py-3 px-4 font-bold text-white">
          <div style="display: flex; align-items: center; gap: 10px;">
            ${p.image_url ? `<img src="${escapeHtml(getFreshImageUrl(p.image_url))}" alt="${escapeHtml(p.name)}" style="width: 38px; height: 38px; object-fit: cover; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); ${!isActive ? 'filter: grayscale(80%); opacity: 0.65;' : ''}" onerror="this.style.display='none'">` : ''}
            <div>
              <div class="${isActive ? 'text-white' : 'text-dark-300'}" style="${!isActive ? 'text-decoration: line-through;' : ''}">${escapeHtml(p.name)}</div>
              ${!isActive ? `<div style="font-size: 11px; color: var(--red-400); font-weight: 500;">Hidden from customers</div>` : (p.description ? `<div style="font-size: 11px; font-weight: normal; color: var(--dark-400);">${escapeHtml(p.description)}</div>` : '')}
            </div>
          </div>
        </td>
        <td class="py-3 px-4 text-dark-300">${escapeHtml(p.category || 'Siomai')}</td>
        <td class="py-3 px-4 font-bold text-emerald-400">₱${Number(p.price || 0).toFixed(2)}</td>
        <td class="py-3 px-4" style="min-width: 160px;">
          <div class="flex items-center justify-between text-xs mb-1">
            <span class="font-bold ${isOut ? 'text-red-400' : isLow ? 'text-yellow-400' : 'text-emerald-400'}">
              ${curStock} / ${max} ${unitStr}
            </span>
            <span class="text-dark-400">${pct}%</span>
          </div>
          <div class="stock-bar-track">
            <div class="stock-bar-fill ${isOut ? 'bg-red-500' : isLow ? 'bg-yellow-500' : 'bg-emerald-500'}" style="width: ${pct}%;"></div>
          </div>
        </td>
        <td class="py-3 px-4">
          <div class="flex flex-col gap-1">
            ${isActive 
              ? '<span class="badge badge-green">Active</span>' 
              : '<span class="badge badge-red">Disabled</span>'}
            ${isActive ? (isOut ? '<span class="badge badge-red">Out of Stock</span>' : isLow ? '<span class="badge badge-yellow">Low Stock</span>' : '<span class="badge badge-green">In Stock</span>') : ''}
          </div>
        </td>
        <td class="py-3 px-4 text-center">
          <button class="btn ${isActive ? 'btn-danger' : 'btn-success'} btn-toggle-active flex items-center justify-center gap-1.5" 
                  data-id="${p.id}" 
                  data-name="${escapeHtml(p.name)}" 
                  data-active="${isActive ? 'false' : 'true'}" 
                  style="padding: 5px 12px; font-size: 12px; min-width: 95px; font-weight: 600; margin: 0 auto;" 
                  title="${isActive ? 'Hide from customer menu and prevent ordering' : 'Make available for customers to order'}">
            ${isActive ? `${Icons.ban({ size: 13 })} Disable` : `${Icons.check({ size: 13 })} Enable`}
          </button>
        </td>
        <td class="py-3 px-4 text-center">
          <div class="flex items-center justify-center gap-1.5 flex-wrap">
            <button class="btn btn-secondary btn-edit-product flex items-center gap-1" data-id="${p.id}" style="padding: 4px 10px; font-size: 12px; font-weight: 600;" title="Edit Product details, quantity & units">
              ${Icons.edit({ size: 13 })} Edit
            </button>
            <button class="btn btn-secondary btn-adjust-stock" data-id="${p.id}" data-delta="-1" style="padding: 4px 7px; font-size: 12px;" title="Deduct 1 ${unitStr}">-1</button>
            <button class="btn btn-secondary btn-adjust-stock" data-id="${p.id}" data-delta="10" style="padding: 4px 7px; font-size: 12px;" title="Add 10 ${unitStr}">+10</button>
            <button class="btn btn-primary btn-adjust-stock" data-id="${p.id}" data-delta="50" style="padding: 4px 7px; font-size: 12px;" title="Add 50 ${unitStr}">+50</button>
          </div>
        </td>
      </tr>
    `;
  }).join('');
}

async function renderInventoryTab() {
  const container = document.getElementById('tab-content');
  if (!container) return;

  const searchInput = document.getElementById('inv-search');
  const isSearchFocused = document.activeElement === searchInput;
  const cursorSelectionStart = searchInput ? searchInput.selectionStart : null;
  const cursorSelectionEnd = searchInput ? searchInput.selectionEnd : null;

  if (!state.inventory || state.inventory.length === 0) {
    container.innerHTML = `
      <div class="flex items-center justify-center p-8">
        <div class="spinner"></div>
      </div>
    `;
  }

  let products = [];
  try {
    const res = await api.getProducts(true);
    products = res.data?.products || [];
    state.inventory = products;
  } catch (err) {
    console.error('[Inventory Load Error]', err);
    if (!state.inventory || state.inventory.length === 0) {
      container.innerHTML = `
        <div class="flex flex-col items-center justify-center p-8 sm:p-12 text-center" style="min-height: 380px;">
          <div class="card p-8" style="max-width: 480px; width: 100%; border-top: 4px solid var(--brand-500); box-shadow: 0 10px 25px -5px rgba(0,0,0,0.3);">
            <div class="flex justify-center mb-4">
              <div style="background: rgba(220, 38, 38, 0.15); width: 60px; height: 60px; border-radius: 50%; display: flex; align-items: center; justify-content: center; color: var(--brand-500);">
                ${Icons.alert({ size: 32, color: 'var(--brand-500)' })}
              </div>
            </div>
            <h2 class="text-xl font-bold text-white mb-2">Unable to Load Inventory</h2>
            <p class="text-xs text-dark-300 mb-6 leading-relaxed">
              ${escapeHtml(err?.response?.data?.error || err?.message || 'Could not retrieve inventory items from server.')}
            </p>
            <div class="flex justify-center">
              <button id="btn-retry-inventory" class="btn btn-primary flex items-center gap-2 px-6 py-2.5">
                ${Icons.refresh({ size: 16 })} Retry Loading Inventory
              </button>
            </div>
          </div>
        </div>
      `;
      document.getElementById('btn-retry-inventory')?.addEventListener('click', () => {
        renderInventoryTab();
      });
      return;
    } else {
      showToast('error', 'Inventory Refresh Error', err.message);
      products = state.inventory;
    }
  }

  const activeProducts = products.filter(p => p.is_active !== false);
  const disabledProducts = products.filter(p => p.is_active === false);
  const lowStockCount = activeProducts.filter(p => p.stock <= (p.min_stock || 15)).length;

  container.innerHTML = `
    <div class="flex flex-wrap items-center justify-between gap-4 mb-6">
      <div>
        <h1 class="text-2xl font-bold text-white">Inventory Management</h1>
      </div>

      <div class="flex items-center gap-3">
        <button id="btn-add-product" class="btn btn-primary flex items-center gap-1.5">
          ${Icons.plus({ size: 16 })} Add Product
        </button>
        <button id="btn-refresh-inv" class="btn btn-secondary flex items-center gap-1.5">
          ${Icons.refresh({ size: 15 })} Refresh
        </button>
      </div>
    </div>

    <!-- Inventory Stat Cards -->
    <div class="grid-4 mb-6">
      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(59,130,246,0.2); color: var(--blue-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.package({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">TOTAL PRODUCTS</div>
          <div class="text-3xl font-bold text-white">${products.length}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(16,185,129,0.2); color: var(--emerald-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.checkCircle({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">ACTIVE FOR SALE</div>
          <div class="text-3xl font-bold text-emerald-400">${activeProducts.length}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(239,68,68,0.2); color: var(--red-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.xCircle({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">DISABLED / HIDDEN</div>
          <div class="text-3xl font-bold ${disabledProducts.length > 0 ? 'text-red-400' : 'text-white'}">${disabledProducts.length}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(234,179,8,0.2); color: var(--yellow-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.alert({ size: 24 })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">LOW STOCK ITEMS</div>
          <div class="text-3xl font-bold ${lowStockCount > 0 ? 'text-yellow-400' : 'text-white'}">${lowStockCount}</div>
        </div>
      </div>
    </div>

    <!-- Category Filter and Search Bar (matching Queue section design) -->
    <div class="flex flex-wrap items-center justify-between gap-4 mb-4">
      <div class="tab-bar" id="inv-tab-bar">
        ${['All', 'Hotspot Siomai', 'Drinks', 'Add-ons'].map(cat => {
          const count = cat === 'All'
            ? products.length
            : products.filter(p => matchInventoryCategory(p, cat)).length;
          return `
            <button class="tab-btn ${state.inventoryFilter === cat ? 'active' : ''}" data-inv-filter="${cat}">
              ${cat}
              <span class="tab-count">${count}</span>
            </button>
          `;
        }).join('')}
      </div>

      <div style="position: relative; width: 280px;">
        <input type="text" id="inv-search" class="input" placeholder="Search inventory item..." value="${escapeHtml(state.inventorySearch || '')}" />
      </div>
    </div>

    <!-- Products Table -->
    <div class="card p-6 overflow-hidden">
      <div style="overflow-x: auto;">
        <table style="width: 100%; border-collapse: collapse; text-align: left;">
          <thead>
            <tr style="border-bottom: 1px solid var(--dark-600); color: var(--dark-400); font-size: 12px; text-transform: uppercase;">
              <th class="py-3 px-4">Item Name</th>
              <th class="py-3 px-4">Category</th>
              <th class="py-3 px-4">Price</th>
              <th class="py-3 px-4">Current Stock</th>
              <th class="py-3 px-4">Customer Status</th>
              <th class="py-3 px-4 text-center">Enable / Disable</th>
              <th class="py-3 px-4 text-center">Quick Stock Adjustment</th>
            </tr>
          </thead>
          <tbody id="inventory-table-body">
            ${renderInventoryRows(products)}
          </tbody>
        </table>
      </div>
    </div>
  `;

  bindInventoryEvents();

  if (isSearchFocused) {
    const newSearchInput = document.getElementById('inv-search');
    if (newSearchInput) {
      newSearchInput.focus();
      if (cursorSelectionStart !== null) {
        newSearchInput.setSelectionRange(cursorSelectionStart, cursorSelectionEnd);
      }
    }
  }
}

function bindInventoryEvents() {
  document.getElementById('btn-refresh-inv')?.addEventListener('click', () => {
    renderInventoryTab();
  });

  document.querySelectorAll('#inv-tab-bar .tab-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const filter = e.currentTarget.getAttribute('data-inv-filter');
      if (filter) {
        state.inventoryFilter = filter;
        document.querySelectorAll('#inv-tab-bar .tab-btn').forEach(b => b.classList.remove('active'));
        e.currentTarget.classList.add('active');
        updateInventoryTableBody();
      }
    });
  });

  const searchInput = document.getElementById('inv-search');
  if (searchInput) {
    searchInput.addEventListener('input', (e) => {
      state.inventorySearch = e.target.value;
      updateInventoryTableBody();
    });
  }

  bindInventoryRowActions();

  document.getElementById('btn-add-product')?.addEventListener('click', () => {
    openAddProductModal();
  });
}

function updateInventoryTableBody() {
  const tbody = document.getElementById('inventory-table-body');
  if (tbody) {
    tbody.innerHTML = renderInventoryRows(state.inventory || []);
    bindInventoryRowActions();
  }
}

function bindInventoryRowActions() {
  document.querySelectorAll('.btn-edit-product').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const pid = e.currentTarget.getAttribute('data-id');
      const pr = (state.inventory || []).find(p => String(p.id) === String(pid));
      if (pr) openEditProductModal(pr);
    });
  });

  document.querySelectorAll('.btn-toggle-active').forEach(btn => {
    btn.addEventListener('click', async (e) => {
      const target = e.currentTarget;
      const pid = target.getAttribute('data-id');
      const name = target.getAttribute('data-name') || 'Product';
      const makeActive = target.getAttribute('data-active') === 'true';
      if (!pid) return;

      try {
        target.disabled = true;
        target.innerHTML = `${Icons.spinner({ size: 14 })} Saving...`;
        await api.updateProduct(pid, { is_active: makeActive });
        showToast(
          makeActive ? 'success' : 'warning',
          makeActive ? 'Product Enabled' : 'Product Disabled',
          `${name} is now ${makeActive ? 'AVAILABLE for customers to order' : 'DISABLED and hidden from customers'}.`
        );
        await renderInventoryTab();
      } catch (err) {
        showToast('error', 'Update Failed', err.message);
        await renderInventoryTab();
      }
    });
  });

  document.querySelectorAll('.btn-adjust-stock').forEach(btn => {
    btn.addEventListener('click', async (e) => {
      const pid = e.currentTarget.getAttribute('data-id');
      const delta = parseInt(e.currentTarget.getAttribute('data-delta'), 10);
      if (!pid || isNaN(delta)) return;

      try {
        await api.updateStock(pid, { adjustment: delta });
        showToast('success', 'Stock Adjusted', `Stock adjusted by ${delta > 0 ? '+' : ''}${delta}`);
        await renderInventoryTab();
      } catch (err) {
        showToast('error', 'Adjustment Failed', err.message);
      }
    });
  });
}

function openAddProductModal() {
  const modalContainer = document.getElementById('modal-container');
  modalContainer.innerHTML = `
    <div class="modal-backdrop" id="prod-modal-backdrop">
      <div class="card modal-box" style="max-width: 540px;">
        <div class="modal-header">
          <h2 class="text-xl font-bold text-white flex items-center gap-2">
            ${Icons.package({ size: 20, color: 'var(--brand-400)' })} Add New Product
          </h2>
          <button id="btn-close-prod-modal" class="btn btn-ghost" style="font-size: 20px;">&times;</button>
        </div>

        <form id="add-prod-form">
          <div class="modal-body space-y-4">
            <div>
              <label class="block text-xs text-dark-300 font-medium mb-1">Product Name</label>
              <input type="text" id="prod-name" class="input" placeholder="e.g. Japanese Siomai" required />
            </div>

            <div class="grid-2">
              <div>
                <label class="block text-xs text-dark-300 font-medium mb-1">Category</label>
                <select id="prod-cat" class="input">
                  <option value="Hotspot Siomai">Hotspot Siomai</option>
                  <option value="Drinks">Drinks</option>
                  <option value="Add-ons">Add-ons</option>
                  <option value="Siomai">Siomai</option>
                  <option value="Dumplings">Dumplings</option>
                  <option value="Sauces">Sauces</option>
                </select>
              </div>
              <div>
                <label class="block text-xs text-dark-300 font-medium mb-1">Measurement Unit</label>
                <select id="prod-unit" class="input">
                  <option value="pcs" selected>pcs (Pieces)</option>
                  <option value="bottles">bottles (Bottles)</option>
                  <option value="cans">cans (Cans)</option>
                  <option value="packs">packs (Packets)</option>
                  <option value="servings">servings (Servings)</option>
                </select>
              </div>
            </div>

            <div class="grid-2">
              <div>
                <label class="block text-xs text-dark-300 font-medium mb-1">Price (₱)</label>
                <input type="number" id="prod-price" class="input" placeholder="45.00" step="0.5" min="0" required />
              </div>
              <div>
                <label class="block text-xs text-dark-300 font-medium mb-1">Description</label>
                <input type="text" id="prod-desc" class="input" placeholder="e.g. Fresh handmade siomai" />
              </div>
            </div>

            <!-- Initial Stock with typed input & stepper buttons -->
            <div>
              <div class="flex items-center justify-between mb-1">
                <label class="text-xs text-dark-300 font-medium">Initial Stock Quantity</label>
                <span class="text-xs text-brand-400 font-semibold" id="add-stock-unit-label">pcs</span>
              </div>
              <div class="flex items-center gap-2">
                <button type="button" class="btn btn-secondary btn-add-step" data-target="prod-stock" data-delta="-10" style="padding: 6px 10px; font-size: 13px;">-10</button>
                <button type="button" class="btn btn-secondary btn-add-step" data-target="prod-stock" data-delta="-1" style="padding: 6px 12px; font-size: 15px; font-weight: bold;">-</button>
                <input type="number" id="prod-stock" class="input text-center" value="50" min="0" style="font-weight: bold; font-size: 16px;" required />
                <button type="button" class="btn btn-secondary btn-add-step" data-target="prod-stock" data-delta="1" style="padding: 6px 12px; font-size: 15px; font-weight: bold;">+</button>
                <button type="button" class="btn btn-secondary btn-add-step" data-target="prod-stock" data-delta="10" style="padding: 6px 10px; font-size: 13px;">+10</button>
              </div>
            </div>

            <!-- Max Stock with typed input & stepper buttons -->
            <div>
              <div class="flex items-center justify-between mb-1">
                <label class="text-xs text-dark-300 font-medium">Maximum Stock Capacity</label>
                <span class="text-xs text-dark-400 font-semibold" id="add-max-unit-label">pcs</span>
              </div>
              <div class="flex items-center gap-2">
                <button type="button" class="btn btn-secondary btn-add-step" data-target="prod-max" data-delta="-10" style="padding: 6px 10px; font-size: 13px;">-10</button>
                <button type="button" class="btn btn-secondary btn-add-step" data-target="prod-max" data-delta="-1" style="padding: 6px 12px; font-size: 15px; font-weight: bold;">-</button>
                <input type="number" id="prod-max" class="input text-center" value="100" min="1" style="font-weight: bold; font-size: 16px;" required />
                <button type="button" class="btn btn-secondary btn-add-step" data-target="prod-max" data-delta="1" style="padding: 6px 12px; font-size: 15px; font-weight: bold;">+</button>
                <button type="button" class="btn btn-secondary btn-add-step" data-target="prod-max" data-delta="10" style="padding: 6px 10px; font-size: 13px;">+10</button>
              </div>
            </div>

            <div style="display: flex; align-items: center; gap: 8px; padding: 4px 0;">
              <input type="checkbox" id="prod-active" checked style="width: 16px; height: 16px; accent-color: var(--brand-500); cursor: pointer;" />
              <label for="prod-active" class="text-xs text-dark-200" style="cursor: pointer; margin-bottom: 0;">
                Available immediately for customer orders
              </label>
            </div>
          </div>

          <div class="modal-footer" style="background: var(--dark-800); border-top: 1px solid var(--dark-600); display: flex; align-items: center; justify-content: space-between;">
            <button type="button" id="btn-cancel-add-prod" class="btn btn-secondary" style="padding: 10px 20px;">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary flex items-center gap-1.5" style="padding: 10px 24px; font-size: 15px;">
              ${Icons.save({ size: 16 })} Save Product
            </button>
          </div>
        </form>
      </div>
    </div>
  `;

  document.getElementById('btn-close-prod-modal')?.addEventListener('click', () => { modalContainer.innerHTML = ''; });
  document.getElementById('btn-cancel-add-prod')?.addEventListener('click', () => { modalContainer.innerHTML = ''; });
  document.getElementById('prod-modal-backdrop')?.addEventListener('click', (e) => {
    if (e.target.id === 'prod-modal-backdrop') modalContainer.innerHTML = '';
  });

  document.getElementById('prod-cat')?.addEventListener('change', (e) => {
    const cat = e.target.value.toLowerCase();
    const unitSel = document.getElementById('prod-unit');
    if (!unitSel) return;
    if (cat.includes('drink')) unitSel.value = 'bottles';
    else if (cat.includes('add-on') || cat.includes('sauce')) unitSel.value = 'packs';
    else if (cat.includes('siomai') || cat.includes('dumpling')) unitSel.value = 'pcs';
    else unitSel.value = 'servings';
    updateAddUnitLabels(unitSel.value);
  });

  const updateAddUnitLabels = (unitVal) => {
    const l1 = document.getElementById('add-stock-unit-label');
    const l2 = document.getElementById('add-max-unit-label');
    if (l1) l1.textContent = unitVal;
    if (l2) l2.textContent = unitVal;
  };

  document.getElementById('prod-unit')?.addEventListener('change', (e) => {
    updateAddUnitLabels(e.target.value);
  });

  modalContainer.querySelectorAll('.btn-add-step').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const targetId = e.currentTarget.getAttribute('data-target');
      const delta = parseInt(e.currentTarget.getAttribute('data-delta'), 10);
      const input = document.getElementById(targetId);
      if (input && !isNaN(delta)) {
        const cur = parseInt(input.value, 10) || 0;
        const min = parseInt(input.getAttribute('min') || '0', 10);
        input.value = Math.max(min, cur + delta);
      }
    });
  });

  document.getElementById('add-prod-form')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const nameInput = document.getElementById('prod-name');
    const name = (nameInput?.value || '').trim();
    const price = parseFloat(document.getElementById('prod-price').value);
    const stock = parseInt(document.getElementById('prod-stock').value, 10);
    const maxStock = parseInt(document.getElementById('prod-max').value, 10);

    const nameVal = validateProductName(name);
    if (!nameVal.valid) {
      swal.warning({
        title: 'Invalid Product Name',
        text: nameVal.error
      });
      nameInput?.focus();
      return;
    }

    if (isNaN(price) || price < 0 || price > 100000) {
      swal.warning({
        title: 'Invalid Price',
        text: 'Please enter a valid price between ₱0.00 and ₱100,000.00.'
      });
      return;
    }

    if (isNaN(stock) || stock < 0 || stock > 50000) {
      swal.warning({
        title: 'Invalid Stock Level',
        text: 'Initial stock must be between 0 and 50,000.'
      });
      return;
    }

    if (isNaN(maxStock) || maxStock < 1 || maxStock > 50000) {
      swal.warning({
        title: 'Invalid Max Stock Level',
        text: 'Maximum stock must be between 1 and 50,000.'
      });
      return;
    }

    const payload = {
      name,
      category: document.getElementById('prod-cat').value,
      price,
      stock: stock || 0,
      max_stock: isNaN(maxStock) || maxStock < stock ? stock + 100 : maxStock,
      unit: document.getElementById('prod-unit').value,
      description: document.getElementById('prod-desc')?.value.trim() || '',
      is_active: document.getElementById('prod-active')?.checked ?? true
    };

    swal.loading({
      title: 'Adding Product...',
      text: `Adding ${escapeHtml(payload.name)} to inventory catalog...`
    });

    try {
      await api.createProduct(payload);
      modalContainer.innerHTML = '';
      await swal.success({
        title: 'Product Created!',
        html: `<b>${escapeHtml(payload.name)}</b> (${payload.stock} ${payload.unit}) has been added to catalog.`,
        timer: 2000
      });
      await renderInventoryTab();
    } catch (err) {
      swal.error({
        title: 'Creation Failed',
        text: err.response?.data?.error || err.message
      });
    }
  });
}

function openEditProductModal(product) {
  if (!product) return;
  const modalContainer = document.getElementById('modal-container');
  const initialUnit = product.unit || (product.category === 'Drinks' ? (product.name.toLowerCase().includes('royal') ? 'bottles' : 'cans') : (product.category === 'Add-ons' ? 'packs' : 'pcs'));

  modalContainer.innerHTML = `
    <div class="modal-backdrop" id="edit-prod-modal-backdrop">
      <div class="card modal-box" style="max-width: 540px;">
        <div class="modal-header">
          <h2 class="text-xl font-bold text-white flex items-center gap-2">
            ${Icons.edit({ size: 20, color: 'var(--brand-400)' })} Edit Product — ${escapeHtml(product.name)}
          </h2>
          <button id="btn-close-edit-modal" class="btn btn-ghost" style="font-size: 20px;">&times;</button>
        </div>

        <form id="edit-prod-form">
          <div class="modal-body space-y-4">
            <div>
              <label class="block text-xs text-dark-300 font-medium mb-1">Product Name</label>
              <input type="text" id="edit-prod-name" class="input" value="${escapeHtml(product.name)}" required />
            </div>

            <div class="grid-2">
              <div>
                <label class="block text-xs text-dark-300 font-medium mb-1">Category</label>
                <select id="edit-prod-cat" class="input">
                  <option value="Hotspot Siomai" ${product.category === 'Hotspot Siomai' ? 'selected' : ''}>Hotspot Siomai</option>
                  <option value="Drinks" ${product.category === 'Drinks' ? 'selected' : ''}>Drinks</option>
                  <option value="Add-ons" ${product.category === 'Add-ons' ? 'selected' : ''}>Add-ons</option>
                  <option value="Siomai" ${product.category === 'Siomai' ? 'selected' : ''}>Siomai</option>
                  <option value="Dumplings" ${product.category === 'Dumplings' ? 'selected' : ''}>Dumplings</option>
                  <option value="Sauces" ${product.category === 'Sauces' ? 'selected' : ''}>Sauces</option>
                </select>
              </div>
              <div>
                <label class="block text-xs text-dark-300 font-medium mb-1">Measurement Unit</label>
                <select id="edit-prod-unit" class="input">
                  <option value="pcs" ${initialUnit === 'pcs' ? 'selected' : ''}>pcs (Pieces)</option>
                  <option value="bottles" ${initialUnit === 'bottles' ? 'selected' : ''}>bottles (Bottles)</option>
                  <option value="cans" ${initialUnit === 'cans' ? 'selected' : ''}>cans (Cans)</option>
                  <option value="packs" ${initialUnit === 'packs' ? 'selected' : ''}>packs (Packets)</option>
                  <option value="servings" ${initialUnit === 'servings' ? 'selected' : ''}>servings (Servings)</option>
                </select>
              </div>
            </div>

            <div class="grid-2">
              <div>
                <label class="block text-xs text-dark-300 font-medium mb-1">Price (₱)</label>
                <input type="number" id="edit-prod-price" class="input" value="${Number(product.price).toFixed(2)}" step="0.5" min="0" required />
              </div>
              <div>
                <label class="block text-xs text-dark-300 font-medium mb-1">Description</label>
                <input type="text" id="edit-prod-desc" class="input" value="${escapeHtml(product.description || '')}" placeholder="Optional product description" />
              </div>
            </div>

            <!-- Current Stock with typed input and stepper buttons -->
            <div>
              <div class="flex items-center justify-between mb-1">
                <label class="text-xs text-dark-300 font-medium">Current Stock Quantity</label>
                <span class="text-xs text-brand-400 font-semibold" id="edit-stock-unit-label">${initialUnit}</span>
              </div>
              <div class="flex items-center gap-2">
                <button type="button" class="btn btn-secondary btn-edit-step" data-target="edit-prod-stock" data-delta="-10" style="padding: 6px 10px; font-size: 13px;">-10</button>
                <button type="button" class="btn btn-secondary btn-edit-step" data-target="edit-prod-stock" data-delta="-1" style="padding: 6px 12px; font-size: 15px; font-weight: bold;">-</button>
                <input type="number" id="edit-prod-stock" class="input text-center" value="${product.stock}" min="0" style="font-weight: bold; font-size: 16px;" required />
                <button type="button" class="btn btn-secondary btn-edit-step" data-target="edit-prod-stock" data-delta="1" style="padding: 6px 12px; font-size: 15px; font-weight: bold;">+</button>
                <button type="button" class="btn btn-secondary btn-edit-step" data-target="edit-prod-stock" data-delta="10" style="padding: 6px 10px; font-size: 13px;">+10</button>
              </div>
            </div>

            <!-- Max Stock Capacity with typed input and stepper buttons -->
            <div>
              <div class="flex items-center justify-between mb-1">
                <label class="text-xs text-dark-300 font-medium">Maximum Stock Capacity</label>
                <span class="text-xs text-dark-400 font-semibold" id="edit-max-unit-label">${initialUnit}</span>
              </div>
              <div class="flex items-center gap-2">
                <button type="button" class="btn btn-secondary btn-edit-step" data-target="edit-prod-max" data-delta="-10" style="padding: 6px 10px; font-size: 13px;">-10</button>
                <button type="button" class="btn btn-secondary btn-edit-step" data-target="edit-prod-max" data-delta="-1" style="padding: 6px 12px; font-size: 15px; font-weight: bold;">-</button>
                <input type="number" id="edit-prod-max" class="input text-center" value="${product.max_stock || 100}" min="1" style="font-weight: bold; font-size: 16px;" required />
                <button type="button" class="btn btn-secondary btn-edit-step" data-target="edit-prod-max" data-delta="1" style="padding: 6px 12px; font-size: 15px; font-weight: bold;">+</button>
                <button type="button" class="btn btn-secondary btn-edit-step" data-target="edit-prod-max" data-delta="10" style="padding: 6px 10px; font-size: 13px;">+10</button>
              </div>
            </div>

            <div style="display: flex; align-items: center; gap: 8px; padding: 4px 0;">
              <input type="checkbox" id="edit-prod-active" ${product.is_active !== false ? 'checked' : ''} style="width: 16px; height: 16px; accent-color: var(--brand-500); cursor: pointer;" />
              <label for="edit-prod-active" class="text-xs text-dark-200" style="cursor: pointer; margin-bottom: 0;">
                Product is active and available for customer ordering
              </label>
            </div>
          </div>

          <div class="modal-footer" style="background: var(--dark-800); border-top: 1px solid var(--dark-600); display: flex; align-items: center; justify-content: space-between;">
            <button type="button" id="btn-cancel-edit" class="btn btn-secondary" style="padding: 10px 20px;">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary flex items-center gap-1.5" style="padding: 10px 24px; font-size: 15px;">
              ${Icons.save({ size: 16 })} Update Product
            </button>
          </div>
        </form>
      </div>
    </div>
  `;

  document.getElementById('btn-close-edit-modal')?.addEventListener('click', () => { modalContainer.innerHTML = ''; });
  document.getElementById('btn-cancel-edit')?.addEventListener('click', () => { modalContainer.innerHTML = ''; });
  document.getElementById('edit-prod-modal-backdrop')?.addEventListener('click', (e) => {
    if (e.target.id === 'edit-prod-modal-backdrop') modalContainer.innerHTML = '';
  });

  document.getElementById('edit-prod-cat')?.addEventListener('change', (e) => {
    const cat = e.target.value.toLowerCase();
    const unitSel = document.getElementById('edit-prod-unit');
    if (!unitSel) return;
    if (cat.includes('drink')) unitSel.value = 'bottles';
    else if (cat.includes('add-on') || cat.includes('sauce')) unitSel.value = 'packs';
    else if (cat.includes('siomai') || cat.includes('dumpling')) unitSel.value = 'pcs';
    else unitSel.value = 'servings';
    updateUnitLabels(unitSel.value);
  });

  const updateUnitLabels = (unitVal) => {
    const l1 = document.getElementById('edit-stock-unit-label');
    const l2 = document.getElementById('edit-max-unit-label');
    if (l1) l1.textContent = unitVal;
    if (l2) l2.textContent = unitVal;
  };

  document.getElementById('edit-prod-unit')?.addEventListener('change', (e) => {
    updateUnitLabels(e.target.value);
  });

  modalContainer.querySelectorAll('.btn-edit-step').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const targetId = e.currentTarget.getAttribute('data-target');
      const delta = parseInt(e.currentTarget.getAttribute('data-delta'), 10);
      const input = document.getElementById(targetId);
      if (input && !isNaN(delta)) {
        const cur = parseInt(input.value, 10) || 0;
        const min = parseInt(input.getAttribute('min') || '0', 10);
        input.value = Math.max(min, cur + delta);
      }
    });
  });

  document.getElementById('edit-prod-form')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const nameInput = document.getElementById('edit-prod-name');
    const name = (nameInput?.value || '').trim();
    const price = parseFloat(document.getElementById('edit-prod-price').value);
    const stock = parseInt(document.getElementById('edit-prod-stock').value, 10);
    const maxStock = parseInt(document.getElementById('edit-prod-max').value, 10);

    const nameVal = validateProductName(name);
    if (!nameVal.valid) {
      swal.warning({
        title: 'Invalid Product Name',
        text: nameVal.error
      });
      nameInput?.focus();
      return;
    }

    if (isNaN(price) || price < 0 || price > 100000) {
      swal.warning({
        title: 'Invalid Price',
        text: 'Please enter a valid price between ₱0.00 and ₱100,000.00.'
      });
      return;
    }

    if (isNaN(stock) || stock < 0 || stock > 50000) {
      swal.warning({
        title: 'Invalid Stock Level',
        text: 'Stock level must be between 0 and 50,000.'
      });
      return;
    }

    if (isNaN(maxStock) || maxStock < 1 || maxStock > 50000) {
      swal.warning({
        title: 'Invalid Max Stock Level',
        text: 'Maximum stock must be between 1 and 50,000.'
      });
      return;
    }

    const payload = {
      name,
      category: document.getElementById('edit-prod-cat').value,
      price,
      stock: stock || 0,
      max_stock: isNaN(maxStock) || maxStock < stock ? stock + 100 : maxStock,
      unit: document.getElementById('edit-prod-unit').value,
      description: document.getElementById('edit-prod-desc').value.trim(),
      is_active: document.getElementById('edit-prod-active')?.checked ?? true
    };

    swal.loading({
      title: 'Saving Changes...',
      text: `Updating ${escapeHtml(payload.name)}...`
    });

    try {
      await api.updateProduct(product.id, payload);
      modalContainer.innerHTML = '';
      await swal.success({
        title: 'Product Updated!',
        html: `Changes to <b>${escapeHtml(payload.name)}</b> (${payload.stock} ${payload.unit}) have been saved.`,
        timer: 2000
      });
      await renderInventoryTab();
    } catch (err) {
      swal.error({
        title: 'Update Failed',
        text: err.response?.data?.error || err.message
      });
    }
  });
}

// ── Export Analytics CSV Modal & Handler ──────────────────────────────────────
async function openExportCsvModal() {
  const isLight = document.body.classList.contains('light-theme') || document.body.classList.contains('light-mode');
  const modalBg = isLight ? '#ffffff' : '#18181b';
  const textColor = isLight ? '#0f172a' : '#f8fafc';
  const subtextColor = isLight ? '#475569' : '#94a3b8';
  const borderColor = isLight ? '#e2e8f0' : '#27272a';
  const inputBg = isLight ? '#f1f5f9' : '#27272a';

  const today = getManilaDateKey(new Date());

  const modalHtml = `
    <div style="text-align: left; font-size: 13px; color: ${textColor};">
      <p style="color: ${subtextColor}; margin-bottom: 16px; font-size: 13px; line-height: 1.5;">
        Export actual database sales and customer order records directly from <strong>Firebase Cloud Firestore</strong>. Forecasted and predicted figures are strictly excluded.
      </p>

      <div style="margin-bottom: 14px;">
        <label style="display: block; font-weight: 600; margin-bottom: 6px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; color: ${textColor};">Date Range Filter</label>
        <select id="export-date-range" class="input" style="width: 100%; padding: 8px 12px; border-radius: 8px; border: 1px solid ${borderColor}; background: ${inputBg}; color: ${textColor}; font-size: 13px;">
          <option value="all" selected>All Records (Historical & Real-time)</option>
          <option value="today">Today's Transactions</option>
          <option value="yesterday">Yesterday's Transactions</option>
          <option value="7d">Last 7 Days</option>
          <option value="30d">Last 30 Days</option>
          <option value="custom">Custom Date Range...</option>
        </select>
      </div>

      <div id="export-custom-dates" style="display: none; margin-bottom: 14px; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div>
          <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 11px; color: ${subtextColor};">Start Date</label>
          <input type="date" id="export-start-date" class="input" value="${today}" style="width: 100%; padding: 7px 10px; border-radius: 8px; border: 1px solid ${borderColor}; background: ${inputBg}; color: ${textColor}; font-size: 12px;">
        </div>
        <div>
          <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 11px; color: ${subtextColor};">End Date</label>
          <input type="date" id="export-end-date" class="input" value="${today}" style="width: 100%; padding: 7px 10px; border-radius: 8px; border: 1px solid ${borderColor}; background: ${inputBg}; color: ${textColor}; font-size: 12px;">
        </div>
      </div>

      <div style="margin-bottom: 14px;">
        <label style="display: block; font-weight: 600; margin-bottom: 6px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; color: ${textColor};">Order Status Filter</label>
        <select id="export-order-status" class="input" style="width: 100%; padding: 8px 12px; border-radius: 8px; border: 1px solid ${borderColor}; background: ${inputBg}; color: ${textColor}; font-size: 13px;">
          <option value="all" selected>All Statuses (Pending, Preparing, Completed, etc.)</option>
          <option value="completed">Completed / Fulfilled Only</option>
          <option value="pending">Pending Only</option>
          <option value="cancelled">Cancelled Only</option>
        </select>
      </div>

      <div style="margin-bottom: 16px;">
        <label style="display: block; font-weight: 600; margin-bottom: 6px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; color: ${textColor};">Payment Method Filter</label>
        <select id="export-payment-method" class="input" style="width: 100%; padding: 8px 12px; border-radius: 8px; border: 1px solid ${borderColor}; background: ${inputBg}; color: ${textColor}; font-size: 13px;">
          <option value="all" selected>All Payment Methods (Cash & GCash)</option>
          <option value="Cash">Cash Only</option>
          <option value="GCash">GCash Only</option>
        </select>
      </div>

      <div style="background: rgba(220, 38, 38, 0.08); border: 1px solid rgba(220, 38, 38, 0.25); border-radius: 8px; padding: 10px 12px; font-size: 12px; color: ${subtextColor}; display: flex; align-items: flex-start; gap: 8px;">
        <span style="color: var(--brand-500); display: flex; margin-top: 1px;">${Icons.download({ size: 16 })}</span>
        <span>Exports transaction date, order ID, customer details, products, quantities, payment method, order status, and total revenue in standard RFC 4180 CSV with UTF-8 BOM encoding.</span>
      </div>
    </div>
  `;

  if (!window.Swal) {
    window.location.href = api.exportSalesCsv({ range: 'all', status: 'all' });
    return;
  }

  const result = await window.Swal.fire({
    title: '<span style="font-size: 18px; font-weight: bold;">Export Sales & Order Records</span>',
    html: modalHtml,
    showCancelButton: true,
    confirmButtonText: `${Icons.download({ size: 16 })} Download CSV`,
    cancelButtonText: 'Cancel',
    confirmButtonColor: '#dc2626',
    cancelButtonColor: '#4b5563',
    background: modalBg,
    color: textColor,
    didOpen: () => {
      const selectRange = document.getElementById('export-date-range');
      const customDates = document.getElementById('export-custom-dates');
      selectRange?.addEventListener('change', (e) => {
        if (e.target.value === 'custom') {
          customDates.style.display = 'grid';
        } else {
          customDates.style.display = 'none';
        }
      });
    },
    preConfirm: () => {
      const range = document.getElementById('export-date-range')?.value || 'all';
      const status = document.getElementById('export-order-status')?.value || 'all';
      const paymentMethod = document.getElementById('export-payment-method')?.value || 'all';
      const startDate = document.getElementById('export-start-date')?.value || '';
      const endDate = document.getElementById('export-end-date')?.value || '';

      if (range === 'custom') {
        if (!startDate || !endDate) {
          window.Swal.showValidationMessage('Please select both Start Date and End Date.');
          return false;
        }
        if (startDate > endDate) {
          window.Swal.showValidationMessage('Start Date cannot be later than End Date.');
          return false;
        }
      }

      return { range, status, paymentMethod, startDate, endDate };
    }
  });

  if (!result.isConfirmed || !result.value) return;

  const { range, status, paymentMethod, startDate, endDate } = result.value;

  swal.loading({
    title: 'Generating CSV Export...',
    text: 'Fetching latest actual transaction records from Firebase Cloud Firestore...'
  });

  try {
    const params = { range, status, payment_method: paymentMethod };
    if (range === 'custom') {
      params.start_date = startDate;
      params.end_date = endDate;
    }

    const { blob, filename, recordCount, totalRevenue } = await api.downloadSalesCsv(params);
    const count = parseInt(recordCount || '0', 10);
    const revenue = parseFloat(totalRevenue || '0.00');

    if (count === 0) {
      swal.warning({
        title: 'No Records Found',
        text: 'There are no sales or order transactions matching your selected date and status filters.'
      });
      return;
    }

    // Trigger instant browser file download
    const downloadUrl = window.URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = downloadUrl;
    link.download = filename || `kevs_siomai_sales_${today}.csv`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    window.URL.revokeObjectURL(downloadUrl);

    // Show success dialog
    if (window.Swal) {
      window.Swal.fire({
        icon: 'success',
        title: 'Export Completed!',
        html: `
          <div style="text-align: center; font-size: 13px; color: ${subtextColor};">
            <p style="margin-bottom: 8px;">Downloaded <strong>${count}</strong> actual transaction record(s) from Firebase Cloud Firestore.</p>
            <p style="font-weight: 600; color: var(--emerald-400); font-size: 15px;">Verified Revenue: ₱${revenue.toFixed(2)}</p>
            <p style="margin-top: 10px; font-size: 12px; color: ${subtextColor};">Filename: <code style="background: rgba(255,255,255,0.08); padding: 2px 6px; border-radius: 4px;">${escapeHtml(filename)}</code></p>
          </div>
        `,
        confirmButtonColor: '#dc2626',
        background: modalBg,
        color: textColor,
        timer: 4500,
        timerProgressBar: true
      });
    } else {
      showToast('success', 'Export Completed', `Downloaded ${count} records (₱${revenue.toFixed(2)})`);
    }
  } catch (err) {
    console.error('[Export CSV Error]', err);
    swal.error({
      title: 'Export Failed',
      text: err.message || 'An error occurred while exporting data from Firebase Cloud Firestore.'
    });
  }
}

// ==============================================================================
// 4. ANALYTICS & DECISION SUPPORT SYSTEM (HTML & JS)
// ==============================================================================
async function renderAnalyticsTab() {
  const container = document.getElementById('tab-content');
  if (!container) return;

  // 1. Initial Loading State
  container.innerHTML = `
    <div id="analytics-loading-state" class="flex flex-col items-center justify-center p-16 text-center" style="min-height: 380px;">
      <div class="spinner mb-4"></div>
      <p class="text-xs text-dark-300 font-medium">Loading revenue data, forecasts, and reports...</p>
    </div>
  `;

  try {
    const [dRes, pRes, prRes] = await Promise.all([
      api.getDescriptive(),
      api.getPredictive().catch((err) => {
        console.warn('[Predictive API Notice]', err);
        return { data: {} };
      }),
      api.getPrescriptive().catch((err) => {
        console.warn('[Prescriptive API Notice]', err);
        return { data: {} };
      })
    ]);

    const desc = (dRes && dRes.data) || {};
    const pred = (pRes && pRes.data) || {};
    const presc = (prRes && prRes.data) || {};

    // Active sub-report filter: 'all' | 'descriptive' | 'predictive' | 'prescriptive'
    state.analyticsSection = state.analyticsSection || 'all';
    state.analyticsTimeframe = state.analyticsTimeframe || 'daily';

    // Last updated timestamp in Philippine Time (Asia/Manila)
    const lastUpdatedStr = new Date().toLocaleTimeString('en-US', {
      timeZone: 'Asia/Manila',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    });

    // Descriptive metrics derived from actual database records
    const totalRev = Number(desc.total_sales ?? desc.summary?.total_revenue ?? 0);
    const todayRev = Number(desc.today_sales ?? desc.summary?.today_sales ?? desc.summary?.today_revenue ?? 0);
    const cashRev = Number(desc.summary?.cash_revenue ?? (desc.channel_breakdown?.payment?.find(p => p.name === 'Cash')?.value ?? 0));
    const gcashRev = Number(desc.summary?.gcash_revenue ?? (desc.channel_breakdown?.payment?.find(p => p.name === 'GCash')?.value ?? 0));
    const totalOrders = Number(desc.total_orders ?? desc.summary?.total_orders ?? 0);
    const totalCompleted = Number(desc.total_completed ?? desc.summary?.total_completed ?? 0);
    const avgOrderVal = Number(desc.average_order_value ?? (totalCompleted > 0 ? totalRev / totalCompleted : 0));

    // Products breakdown & rankings
    const topProducts = Array.isArray(desc.top_products) ? desc.top_products : [];
    const topRevenueProduct = topProducts.length > 0
      ? [...topProducts].sort((a, b) => (Number(b.revenue) || 0) - (Number(a.revenue) || 0))[0]
      : null;
    const topVolumeProduct = desc.top_selling_product?.name
      || (topProducts.length > 0 ? topProducts[0].name : 'None');

    // Peak hours profile
    const actualPeaks = Array.isArray(desc.actual_peak_hours)
      ? desc.actual_peak_hours
      : (Array.isArray(desc.peak_hours) ? desc.peak_hours : []);

    const getRecIcon = (r) => {
      const cat = (r.category || '').toUpperCase();
      if (cat.includes('INVENTORY') || cat.includes('STOCK')) return Icons.package({ size: 20, color: 'var(--brand-500)' });
      if (cat.includes('KITCHEN') || cat.includes('BATCH')) return Icons.cook({ size: 20, color: 'var(--purple-400)' });
      if (cat.includes('PEAK') || cat.includes('SERVICE')) return Icons.clock({ size: 20, color: 'var(--blue-400)' });
      if (cat.includes('PAYMENT') || cat.includes('CASH') || cat.includes('GCASH')) return Icons.creditCard({ size: 20, color: 'var(--emerald-400)' });
      if (r.priority === 'critical') return Icons.alert({ size: 20, color: 'var(--brand-500)' });
      return Icons.sparkles({ size: 20, color: 'var(--yellow-400)' });
    };

  container.innerHTML = `
    <!-- Analytics Header & Report Navigation -->
    <div class="flex flex-wrap items-center justify-between gap-4 mb-6">
      <div>
        <h1 class="text-2xl font-bold text-white">Analytics</h1>
      </div>
      <div class="flex items-center gap-3">
        <span class="text-xs text-dark-300 hidden sm:inline">Refreshed: ${lastUpdatedStr}</span>
        <button id="btn-export-analytics-csv" class="btn btn-secondary flex items-center gap-1.5" style="border: 1px solid var(--dark-500); cursor: pointer;" title="Export sales and order records to CSV">
          ${Icons.download({ size: 15 })} Export CSV
        </button>
        <button id="btn-refresh-analytics" class="btn btn-secondary flex items-center gap-1.5">
          ${Icons.refresh({ size: 15 })} Refresh
        </button>
      </div>
    </div>

    <!-- Segmented Report Filter Pills -->
    <div class="flex flex-wrap items-center gap-2 mb-6 p-1.5 rounded-xl" style="background: var(--dark-800); border: 1px solid var(--dark-600); width: fit-content;">
      <button class="analytics-tab-btn btn-sm ${state.analyticsSection === 'all' ? 'active' : ''}" data-section="all" style="padding: 6px 14px; border-radius: 8px; font-size: 13px; font-weight: 600; cursor: pointer; transition: all .2s; border: none; background: ${state.analyticsSection === 'all' ? 'var(--brand-500)' : 'transparent'}; color: ${state.analyticsSection === 'all' ? '#ffffff' : 'var(--dark-300)'};">
        All
      </button>
      <button class="analytics-tab-btn btn-sm ${state.analyticsSection === 'descriptive' ? 'active' : ''}" data-section="descriptive" style="padding: 6px 14px; border-radius: 8px; font-size: 13px; font-weight: 600; cursor: pointer; transition: all .2s; border: none; background: ${state.analyticsSection === 'descriptive' ? 'var(--brand-500)' : 'transparent'}; color: ${state.analyticsSection === 'descriptive' ? '#ffffff' : 'var(--dark-300)'};">
        Descriptive
      </button>
      <button class="analytics-tab-btn btn-sm ${state.analyticsSection === 'predictive' ? 'active' : ''}" data-section="predictive" style="padding: 6px 14px; border-radius: 8px; font-size: 13px; font-weight: 600; cursor: pointer; transition: all .2s; border: none; background: ${state.analyticsSection === 'predictive' ? 'var(--brand-500)' : 'transparent'}; color: ${state.analyticsSection === 'predictive' ? '#ffffff' : 'var(--dark-300)'};">
        Predictive
      </button>
      <button class="analytics-tab-btn btn-sm ${state.analyticsSection === 'prescriptive' ? 'active' : ''}" data-section="prescriptive" style="padding: 6px 14px; border-radius: 8px; font-size: 13px; font-weight: 600; cursor: pointer; transition: all .2s; border: none; background: ${state.analyticsSection === 'prescriptive' ? 'var(--brand-500)' : 'transparent'}; color: ${state.analyticsSection === 'prescriptive' ? '#ffffff' : 'var(--dark-300)'};">
        Prescriptive
      </button>
    </div>

    <!-- ======================================================================== -->
    <!-- UNIFIED REVENUE: DESCRIPTIVE ACTUALS & PREDICTIVE FORECAST               -->
    <!-- ======================================================================== -->
    <div class="card p-6 mb-6" id="card-unified-revenue" style="border: 1px solid var(--dark-500); box-shadow: 0 8px 24px -4px rgba(0,0,0,0.25);">
      <div class="flex flex-wrap items-center justify-between gap-4 mb-3">
        <div class="flex flex-wrap items-center gap-3">
          <h2 class="text-lg font-bold text-white flex items-center gap-2">
            ${Icons.trendUp({ size: 20, color: 'var(--brand-500)' })}
            <span>Revenue: Actual vs. Forecast</span>
          </h2>
          <div class="flex items-center gap-1 p-1 rounded-lg" style="background: var(--dark-800); border: 1px solid var(--dark-600);">
            ${['daily', 'weekly', 'monthly'].map(tf => `
              <button class="analytics-tf-btn" data-timeframe="${tf}" style="padding: 3px 10px; border-radius: 6px; font-size: 11px; font-weight: 600; text-transform: capitalize; cursor: pointer; border: none; background: ${state.analyticsTimeframe === tf ? 'var(--brand-500)' : 'transparent'}; color: ${state.analyticsTimeframe === tf ? '#ffffff' : 'var(--dark-300)'};">
                ${tf}
              </button>
            `).join('')}
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-xs font-semibold px-3 py-1.5 rounded-full flex items-center gap-1.5" style="background: rgba(16,185,129,0.15); color: var(--emerald-400); border: 1px solid rgba(16,185,129,0.35);">
            <span style="display:inline-block; width:8px; height:8px; border-radius:50%; background:#10b981;"></span>
            <span>Total Actual: ₱${totalRev.toFixed(2)}</span>
          </span>
          <span class="text-xs font-semibold px-3 py-1.5 rounded-full flex items-center gap-1.5" style="background: rgba(59,130,246,0.15); color: var(--blue-400); border: 1px solid rgba(59,130,246,0.35);">
            <span style="display:inline-block; width:8px; height:8px; border-radius:50%; background:#3b82f6;"></span>
            <span>Forecast: ₱${Number(pred.predicted_sales || 0).toFixed(2)}</span>
          </span>
        </div>
      </div>

      <!-- Statistical Reliability & Status Banner -->
      ${pred.has_sufficient_data ? `
        <div class="mb-4 px-3.5 py-2.5 rounded-xl flex items-center justify-between text-xs" style="background: rgba(59,130,246,0.08); border: 1px solid rgba(59,130,246,0.25); color: var(--blue-400);">
          <span class="flex items-center gap-2">
            ${Icons.cpu({ size: 16 })}
            <span><strong>Linear Regression:</strong> <code>y = ${pred.trend_slope}x + ${pred.trend_intercept}</code> (${pred.current_days_count} daily records, R² = ${pred.confidence})</span>
          </span>
          <span class="badge badge-blue hidden sm:inline" style="font-size: 10px;">OLS Active</span>
        </div>
      ` : (pred.is_preliminary ? `
        <div class="mb-4 px-3.5 py-2.5 rounded-xl flex items-center justify-between text-xs" style="background: rgba(234,179,8,0.08); border: 1px solid rgba(234,179,8,0.3); color: var(--yellow-400);">
          <span class="flex items-center gap-2">
            ${Icons.alert({ size: 16 })}
            <span><strong>Preliminary Baseline:</strong> ${pred.current_days_count} of ${pred.min_required_days} required operating days. Dashed line reflects daily run-rate average (₱${Number(pred.predicted_sales || 0).toFixed(2)}/day).</span>
          </span>
          <span class="badge badge-yellow hidden sm:inline" style="font-size: 10px;">Preliminary</span>
        </div>
      ` : `
        <div class="mb-4 px-3.5 py-2.5 rounded-xl flex items-center justify-between text-xs" style="background: rgba(148,163,184,0.08); border: 1px solid rgba(148,163,184,0.2); color: var(--dark-300);">
          <span class="flex items-center gap-2">
            ${Icons.info({ size: 16 })}
            <span>Complete customer orders to begin plotting verified actuals and demand forecasts.</span>
          </span>
          <span class="badge badge-gray hidden sm:inline" style="font-size: 10px;">Awaiting Data</span>
        </div>
      `)}

      <!-- Visual Legend Guide -->
      <div class="flex flex-wrap items-center justify-between gap-3 mb-3 pb-3 border-b border-dark-600 text-xs">
        <div class="flex flex-wrap items-center gap-4">
          <div class="flex items-center gap-2">
            <span style="display:inline-block; width: 20px; height: 3px; background: #10b981; border-radius: 2px;"></span>
            <span class="text-white font-semibold">Solid Green:</span>
            <span class="text-dark-300">Actual Revenue</span>
          </div>
          <div class="flex items-center gap-2">
            <span style="display:inline-block; width: 20px; height: 3px; border-top: 3px dashed #3b82f6;"></span>
            <span class="text-white font-semibold">Dashed Blue:</span>
            <span class="text-dark-300">Forecast (${pred.has_sufficient_data ? 'OLS Regression' : (pred.is_preliminary ? 'Preliminary Run-Rate' : 'Awaiting Data')})</span>
          </div>
        </div>
      </div>

      <!-- Main Combined Revenue Chart Canvas -->
      <div class="chart-container" style="height: 290px;">
        <canvas id="revenueChart"></canvas>
      </div>

      <!-- Prescriptive Directives Strip -->
      <div class="mt-4 pt-4 border-t border-dark-600">
        <div class="flex items-center gap-2 mb-3">
          ${Icons.sparkles({ size: 16, color: 'var(--purple-400)' })}
          <span class="text-xs font-bold uppercase tracking-wider text-white">Directives</span>
        </div>
        <div class="grid-3" style="gap: 12px;">
          <div class="p-3 rounded-xl" style="background: rgba(16,185,129,0.06); border: 1px solid rgba(16,185,129,0.25);">
            <div class="flex items-center gap-1.5 text-xs font-semibold text-emerald-400 mb-1">
              ${Icons.receipt({ size: 14, color: 'var(--emerald-400)' })} <span>Verified Velocity</span>
            </div>
            <div class="text-xs text-dark-200">
              <strong>₱${todayRev.toFixed(2)}</strong> today across <strong>${totalCompleted}</strong> orders.
              ${topRevenueProduct ? `${escapeHtml(topRevenueProduct.name)} generated ₱${Number(topRevenueProduct.revenue).toFixed(2)}.` : ''}
            </div>
          </div>

          <div class="p-3 rounded-xl" style="background: rgba(59,130,246,0.06); border: 1px solid rgba(59,130,246,0.25);">
            <div class="flex items-center gap-1.5 text-xs font-semibold text-blue-400 mb-1">
              ${Icons.target({ size: 14, color: 'var(--blue-400)' })} <span>Forecast Target</span>
            </div>
            <div class="text-xs text-dark-200">
              Next period target: <strong>₱${Number(pred.predicted_sales || 0).toFixed(2)}</strong> (~${pred.predicted_orders || 25} orders).
              ${pred.has_sufficient_data ? `Trend: ${pred.trend_slope > 0 ? '+' : ''}₱${pred.trend_slope}/day.` : 'Empirical daily run-rate.'}
            </div>
          </div>

          <div class="p-3 rounded-xl" style="background: rgba(168,85,247,0.06); border: 1px solid rgba(168,85,247,0.25);">
            <div class="flex items-center gap-1.5 text-xs font-semibold text-purple-400 mb-1">
              ${Icons.cook({ size: 14, color: 'var(--purple-400)' })} <span>Kitchen Action</span>
            </div>
            <div class="text-xs text-dark-200">
              ${actualPeaks.length > 0 ? `Stage counter at ${((actualPeaks[0].hour - 1) % 24)}:30 prior to peak (${actualPeaks[0].label}).` : 'Maintain baseline 40-pc steamer tray for instant walk-in dispatch.'}
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- ======================================================================== -->
    <!-- SECTION 1: DESCRIPTIVE ANALYTICS                                         -->
    <!-- ======================================================================== -->
    <div id="section-descriptive" style="display: ${state.analyticsSection === 'all' || state.analyticsSection === 'descriptive' ? 'block' : 'none'};">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-bold text-white">Descriptive Analytics</h2>
      </div>

      <!-- Primary Financial KPI Cards -->
      <div class="grid-4 mb-6">
        <div class="card stat-card" style="border-left: 4px solid var(--emerald-500);">
          <div class="stat-icon" style="background: rgba(16,185,129,0.2); color: var(--emerald-400);">
            ${Icons.coins({ size: 24 })}
          </div>
          <div>
            <div class="text-xs text-dark-300 font-medium">TOTAL REVENUE</div>
            <div class="text-2xl font-bold text-white">₱${totalRev.toFixed(2)}</div>
          </div>
        </div>

        <div class="card stat-card" style="border-left: 4px solid var(--blue-500);">
          <div class="stat-icon" style="background: rgba(59,130,246,0.2); color: var(--blue-400);">
            ${Icons.clock({ size: 24 })}
          </div>
          <div>
            <div class="text-xs text-dark-300 font-medium">TODAY'S REVENUE</div>
            <div class="text-2xl font-bold text-white">₱${todayRev.toFixed(2)}</div>
          </div>
        </div>

        <div class="card stat-card" style="border-left: 4px solid var(--brand-500);">
          <div class="stat-icon" style="background: rgba(220,38,38,0.2); color: var(--brand-400);">
            ${Icons.queue({ size: 24 })}
          </div>
          <div>
            <div class="text-xs text-dark-300 font-medium">TOTAL ORDERS</div>
            <div class="text-2xl font-bold text-white">${totalOrders}</div>
          </div>
        </div>

        <div class="card stat-card" style="border-left: 4px solid var(--purple-500);">
          <div class="stat-icon" style="background: rgba(168,85,247,0.2); color: var(--purple-400);">
            ${Icons.analytics({ size: 24 })}
          </div>
          <div>
            <div class="text-xs text-dark-300 font-medium">AVG ORDER VALUE</div>
            <div class="text-2xl font-bold text-white">₱${avgOrderVal.toFixed(2)}</div>
          </div>
        </div>
      </div>

      <!-- Secondary Operational KPI Cards -->
      <div class="grid-4 mb-6">
        <div class="card stat-card">
          <div class="stat-icon" style="background: rgba(234,179,8,0.15); color: var(--yellow-400);">
            ${Icons.coins({ size: 24 })}
          </div>
          <div>
            <div class="text-xs text-dark-300 font-medium">CASH REVENUE</div>
            <div class="text-2xl font-bold text-white">₱${cashRev.toFixed(2)}</div>
          </div>
        </div>

        <div class="card stat-card">
          <div class="stat-icon" style="background: rgba(59,130,246,0.15); color: var(--blue-400);">
            ${Icons.creditCard({ size: 24 })}
          </div>
          <div>
            <div class="text-xs text-dark-300 font-medium">GCASH REVENUE</div>
            <div class="text-2xl font-bold text-white">₱${gcashRev.toFixed(2)}</div>
          </div>
        </div>

        <div class="card stat-card">
          <div class="stat-icon" style="background: rgba(16,185,129,0.15); color: var(--emerald-400);">
            ${Icons.star({ size: 24 })}
          </div>
          <div style="min-width: 0; flex: 1;">
            <div class="text-xs text-dark-300 font-medium">TOP REVENUE ITEM</div>
            <div class="text-base font-bold text-white" style="line-height: 1.3; word-break: break-word;" title="${topRevenueProduct ? escapeHtml(topRevenueProduct.name) : 'None'}">
              ${topRevenueProduct ? escapeHtml(topRevenueProduct.name) : 'None'}
            </div>
          </div>
        </div>

        <div class="card stat-card">
          <div class="stat-icon" style="background: rgba(192,132,252,0.15); color: var(--purple-400);">
            ${Icons.package({ size: 24 })}
          </div>
          <div style="min-width: 0; flex: 1;">
            <div class="text-xs text-dark-300 font-medium">TOP VOLUME SELLER</div>
            <div class="text-base font-bold text-white" style="line-height: 1.3; word-break: break-word;" title="${escapeHtml(topVolumeProduct)}">
              ${escapeHtml(topVolumeProduct)}
            </div>
          </div>
        </div>
      </div>

      <div class="grid-2 mb-6">
        <!-- Peak Hours Profile -->
        <div class="card p-6">
          <div class="flex items-center justify-between mb-3">
            <h3 class="text-base font-bold text-white flex items-center gap-2">
              ${Icons.clock({ size: 18, color: 'var(--blue-500)' })}
              <span>Hourly Order Distribution</span>
            </h3>
          </div>
          <div class="chart-container" style="height: 240px;">
            <canvas id="salesChart"></canvas>
          </div>
        </div>

        <!-- Product Revenue Share -->
        <div class="card p-6">
          <div class="flex items-center justify-between mb-3">
            <h3 class="text-base font-bold text-white flex items-center gap-2">
              ${Icons.pieChart({ size: 18, color: 'var(--purple-500)' })}
              <span>Revenue Contribution</span>
            </h3>
          </div>
          <div class="chart-container" style="height: 240px;">
            <canvas id="productChart"></canvas>
          </div>
        </div>
      </div>

      <!-- Descriptive Table: Product Sales Breakdown -->
      <div class="card p-6 mb-6 overflow-hidden">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-base font-bold text-white flex items-center gap-2">
            ${Icons.receipt({ size: 18, color: 'var(--brand-500)' })}
            <span>Menu Performance</span>
          </h3>
          <span class="text-xs text-dark-300">${topProducts.length} item(s)</span>
        </div>

        <div style="overflow-x: auto;">
          <table style="width: 100%; border-collapse: collapse; text-align: left;">
            <thead>
              <tr style="border-bottom: 1px solid var(--dark-600); color: var(--dark-400); font-size: 12px; text-transform: uppercase;">
                <th class="py-3 px-4">Menu Item</th>
                <th class="py-3 px-4 text-center">Units Sold</th>
                <th class="py-3 px-4 text-right">Revenue</th>
                <th class="py-3 px-4 text-center">Share</th>
                <th class="py-3 px-4 text-center">Status</th>
              </tr>
            </thead>
            <tbody>
              ${topProducts.length > 0 ? topProducts.map(p => {
                const pRev = Number(p.revenue || 0);
                const pQty = Number(p.quantity || 0);
                const sharePct = totalRev > 0 ? Math.round((pRev / totalRev) * 100) : 0;
                const isTop = topRevenueProduct && topRevenueProduct.name === p.name && pRev > 0;

                return `
                  <tr style="border-bottom: 1px solid var(--dark-600); font-size: 14px;">
                    <td class="py-3 px-4 font-bold text-white">
                      <div style="display: flex; align-items: center; gap: 8px;">
                        <span>${pRev > 0 ? Icons.siomai({ size: 16, color: 'var(--brand-500)' }) : Icons.package({ size: 16, color: 'var(--dark-400)' })}</span>
                        <span>${escapeHtml(p.name)}</span>
                      </div>
                    </td>
                    <td class="py-3 px-4 text-center text-dark-200 font-semibold">${pQty} pcs</td>
                    <td class="py-3 px-4 text-right font-bold text-emerald-400">₱${pRev.toFixed(2)}</td>
                    <td class="py-3 px-4 text-center">
                      <div style="display: flex; align-items: center; justify-content: center; gap: 6px;">
                        <div style="width: 60px; height: 6px; background: rgba(0,0,0,0.08); border-radius: 999px; overflow: hidden;">
                          <div style="width: ${sharePct}%; height: 100%; background: var(--emerald-500); border-radius: 999px;"></div>
                        </div>
                        <span class="text-xs text-dark-300 font-semibold">${sharePct}%</span>
                      </div>
                    </td>
                    <td class="py-3 px-4 text-center">
                      ${isTop ? `<span class="badge badge-success flex items-center gap-1" style="font-size: 11px;">${Icons.crown({ size: 12, color: 'currentColor' })} Top Earner</span>` : (pRev > 0 ? '<span class="badge" style="background: rgba(59,130,246,0.15); color: var(--blue-400); font-size: 11px;">Active</span>' : '<span class="badge" style="background: rgba(148,163,184,0.15); color: #94a3b8; font-size: 11px;">Add-on</span>')}
                    </td>
                  </tr>
                `;
              }).join('') : `
                <tr>
                  <td colspan="5" class="py-6 text-center text-dark-400 text-sm">
                    No completed product sales recorded in the database yet.
                  </td>
                </tr>
              `}
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <!-- ======================================================================== -->
    <!-- SECTION 2: PREDICTIVE ANALYTICS                                          -->
    <!-- ======================================================================== -->
    <div id="section-predictive" style="display: ${state.analyticsSection === 'all' || state.analyticsSection === 'predictive' ? 'block' : 'none'};" class="mb-8">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-bold text-white">Predictive Analytics</h2>
      </div>

      ${pred.has_sufficient_data ? `
        <!-- ACTIVE PREDICTIVE MODEL -->
        <div class="grid-4 mb-6">
          <div class="card stat-card" style="border-left: 4px solid var(--blue-500);">
            <div class="stat-icon" style="background: rgba(59,130,246,0.2); color: var(--blue-400);">
              ${Icons.calendar({ size: 24 })}
            </div>
            <div>
              <div class="text-xs text-dark-300 font-medium">NEXT FORECAST</div>
              <div class="text-2xl font-bold text-white">₱${Number(pred.predicted_sales || 0).toFixed(2)}</div>
            </div>
          </div>

          <div class="card stat-card" style="border-left: 4px solid var(--brand-500);">
            <div class="stat-icon" style="background: rgba(220,38,38,0.2); color: var(--brand-400);">
              ${Icons.queue({ size: 24 })}
            </div>
            <div>
              <div class="text-xs text-dark-300 font-medium">PROJECTED ORDERS</div>
              <div class="text-2xl font-bold text-white">${pred.predicted_orders ?? 1}</div>
            </div>
          </div>

          <div class="card stat-card" style="border-left: 4px solid var(--emerald-500);">
            <div class="stat-icon" style="background: rgba(168,85,247,0.2); color: var(--purple-400);">
              ${Icons.trendUp({ size: 24 })}
            </div>
            <div>
              <div class="text-xs text-dark-300 font-medium">DAILY TREND SLOPE</div>
              <div class="text-2xl font-bold text-white">${pred.trend_slope > 0 ? '+' : ''}₱${pred.trend_slope}/day</div>
            </div>
          </div>

          <div class="card stat-card" style="border-left: 4px solid var(--purple-500);">
            <div class="stat-icon" style="background: rgba(168,85,247,0.2); color: var(--purple-400);">
              ${Icons.cpu({ size: 24 })}
            </div>
            <div>
              <div class="text-xs text-dark-300 font-medium">MODEL FIT (R²)</div>
              <div class="text-2xl font-bold text-white">${(Number(pred.confidence || 0) * 100).toFixed(1)}%</div>
            </div>
          </div>
        </div>

        <!-- 7-Day Statistical Revenue Forecast -->
        <div class="card p-6 mb-6">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-base font-bold text-white flex items-center gap-2">
              ${Icons.cpu({ size: 18, color: 'var(--blue-500)' })}
              <span>7-Day Statistical Forecast</span>
            </h3>
            <span class="badge badge-blue">${pred.current_days_count} Daily Records</span>
          </div>

          <div class="grid-4" style="gap: 10px;">
            ${(pred.forecast_labels || []).map((label, idx) => `
              <div class="p-3 rounded-xl text-center" style="background: rgba(59,130,246,0.06); border: 1px solid rgba(59,130,246,0.2);">
                <div class="text-xs text-dark-300">${label}</div>
                <div class="text-base font-bold text-white mt-1">₱${Number(pred.forecast_data?.[idx] || 0).toFixed(2)}</div>
                <div class="text-xs text-blue-400 mt-0.5" style="font-size: 10px;">Projection</div>
              </div>
            `).join('')}
          </div>
        </div>
      ` : (pred.is_preliminary ? `
        <!-- PRELIMINARY RUN-RATE MODEL -->
        <div class="grid-4 mb-6">
          <div class="card stat-card" style="border-left: 4px solid var(--yellow-500);">
            <div class="stat-icon" style="background: rgba(234,179,8,0.2); color: var(--yellow-400);">
              ${Icons.calendar({ size: 24 })}
            </div>
            <div>
              <div class="text-xs text-dark-300 font-medium">PRELIMINARY FORECAST</div>
              <div class="text-2xl font-bold text-white">₱${Number(pred.predicted_sales || 0).toFixed(2)}</div>
            </div>
          </div>

          <div class="card stat-card" style="border-left: 4px solid var(--brand-500);">
            <div class="stat-icon" style="background: rgba(220,38,38,0.2); color: var(--brand-400);">
              ${Icons.queue({ size: 24 })}
            </div>
            <div>
              <div class="text-xs text-dark-300 font-medium">ESTIMATED ORDERS</div>
              <div class="text-2xl font-bold text-white">${pred.predicted_orders ?? 1}</div>
            </div>
          </div>

          <div class="card stat-card" style="border-left: 4px solid var(--blue-500);">
            <div class="stat-icon" style="background: rgba(59,130,246,0.2); color: var(--blue-400);">
              ${Icons.trendUp({ size: 24 })}
            </div>
            <div>
              <div class="text-xs text-dark-300 font-medium">EMPIRICAL RUN-RATE</div>
              <div class="text-2xl font-bold text-white">₱${Number(pred.predicted_sales || 0).toFixed(2)}/day</div>
            </div>
          </div>

          <div class="card stat-card" style="border-left: 4px solid var(--purple-500);">
            <div class="stat-icon" style="background: rgba(168,85,247,0.2); color: var(--purple-400);">
              ${Icons.cpu({ size: 24 })}
            </div>
            <div>
              <div class="text-xs text-dark-300 font-medium">CALIBRATION PROGRESS</div>
              <div class="text-2xl font-bold text-white">${pred.current_days_count} / ${pred.min_required_days} Days</div>
            </div>
          </div>
        </div>

        <!-- 7-Day Baseline Projections -->
        <div class="card p-6 mb-6" style="border: 1px solid rgba(234,179,8,0.25);">
          <div class="flex flex-wrap items-center justify-between gap-4 mb-4">
            <h3 class="text-base font-bold text-white">7-Day Baseline Projections</h3>
            <span class="badge badge-yellow">Need ${pred.min_required_days - pred.current_days_count} More Day(s) for OLS</span>
          </div>

          <!-- Progress Bar to ML Threshold -->
          <div class="mb-4">
            <div class="flex items-center justify-between text-xs text-dark-300 mb-1">
              <span>Data Depth Calibration</span>
              <span>${Math.round((pred.current_days_count / pred.min_required_days) * 100)}%</span>
            </div>
            <div style="width: 100%; height: 8px; background: rgba(0,0,0,0.2); border-radius: 999px; overflow: hidden;">
              <div style="width: ${Math.round((pred.current_days_count / pred.min_required_days) * 100)}%; height: 100%; background: var(--yellow-500); border-radius: 999px; transition: width .5s;"></div>
            </div>
          </div>

          <div class="grid-4" style="gap: 10px;">
            ${(pred.forecast_labels || []).map((label, idx) => `
              <div class="p-3 rounded-xl text-center" style="background: rgba(234,179,8,0.06); border: 1px solid rgba(234,179,8,0.2);">
                <div class="text-xs text-dark-300">${label}</div>
                <div class="text-base font-bold text-white mt-1">₱${Number(pred.forecast_data?.[idx] || 0).toFixed(2)}</div>
                <div class="text-xs text-yellow-400 mt-0.5" style="font-size: 10px;">Run-Rate Est.</div>
              </div>
            `).join('')}
          </div>
        </div>
      ` : `
        <!-- AWAITING DATA -->
        <div class="card p-6 mb-6 text-center text-dark-300">
          <div class="flex items-center justify-center gap-2 mb-2">
            ${Icons.info({ size: 20, color: 'var(--blue-400)' })}
            <span class="text-base font-bold text-white">Data Collection Phase</span>
          </div>
          <p class="text-xs text-dark-300">
            Complete customer orders to begin plotting verified actuals and statistical forecasts.
          </p>
        </div>
      `)}
    </div>

    <!-- ======================================================================== -->
    <!-- SECTION 3: PRESCRIPTIVE RECOMMENDATIONS                                  -->
    <!-- ======================================================================== -->
    <div id="section-prescriptive" style="display: ${state.analyticsSection === 'all' || state.analyticsSection === 'prescriptive' ? 'block' : 'none'};" class="mb-8">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-bold text-white">Prescriptive Recommendations</h2>
        <div class="flex items-center gap-2">
          ${presc.summary?.critical_count > 0 ? `<span class="badge badge-red">${presc.summary.critical_count} Critical</span>` : ''}
          ${presc.summary?.warning_count > 0 ? `<span class="badge badge-yellow">${presc.summary.warning_count} Warnings</span>` : ''}
          <span class="badge badge-blue">${presc.summary?.info_count || 0} Notes</span>
        </div>
      </div>

      <!-- Prescriptive Action Cards Grid -->
      <div class="space-y-4 mb-6">
        ${(presc.recommendations || []).length > 0 ? (presc.recommendations || []).map(r => {
          const isCritical = r.priority === 'critical';
          const isWarning = r.priority === 'warning';
          const borderColor = isCritical ? 'var(--brand-500)' : (isWarning ? 'var(--yellow-500)' : 'var(--blue-500)');
          const badgeClass = isCritical ? 'badge-red' : (isWarning ? 'badge-yellow' : 'badge-blue');

          return `
            <div class="card p-5" style="border-left: 4px solid ${borderColor};">
              <div class="flex flex-wrap items-start justify-between gap-3 mb-2">
                <div class="flex items-center gap-2.5">
                  <div style="display: flex; align-items: center; justify-content: center;">
                    ${getRecIcon(r)}
                  </div>
                  <div>
                    <div class="flex items-center gap-2">
                      <span class="text-sm font-bold text-white">${escapeHtml(r.product || 'General')}</span>
                      <span class="badge ${badgeClass}" style="font-size: 10px;">${escapeHtml(r.badge || r.category || 'ACTION')}</span>
                    </div>
                  </div>
                </div>
                <span class="text-xs font-semibold px-2.5 py-0.5 rounded-full" style="background: rgba(255,255,255,0.06); color: var(--dark-200);">
                  ${r.priority.toUpperCase()}
                </span>
              </div>

              <div class="text-sm font-medium text-white mb-2">
                ${escapeHtml(r.message)}
              </div>

              <div class="p-3 rounded-lg mb-2" style="background: rgba(0,0,0,0.04); border: 1px solid var(--dark-600); font-size: 13px;">
                <span class="font-bold text-white">Action:</span>
                <span class="text-dark-200"> ${escapeHtml(r.action)}</span>
              </div>

              ${r.rationale ? `
                <div class="text-xs text-dark-400">
                  <em>Rationale:</em> ${escapeHtml(r.rationale)}
                </div>
              ` : ''}
            </div>
          `;
        }).join('') : `
          <div class="card p-6 text-center text-dark-300">
            All inventory levels and operations are currently within normal baseline parameters.
          </div>
        `}
      </div>
    </div>
  `;

  // Attach Filter Pill click handlers
  container.querySelectorAll('.analytics-tab-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const section = e.currentTarget.getAttribute('data-section');
      state.analyticsSection = section;
      const descEl = document.getElementById('section-descriptive');
      const predEl = document.getElementById('section-predictive');
      const prescEl = document.getElementById('section-prescriptive');
      const unifiedEl = document.getElementById('card-unified-revenue');

      if (descEl) descEl.style.display = (section === 'all' || section === 'descriptive') ? 'block' : 'none';
      if (predEl) predEl.style.display = (section === 'all' || section === 'predictive') ? 'block' : 'none';
      if (prescEl) prescEl.style.display = (section === 'all' || section === 'prescriptive') ? 'block' : 'none';
      if (unifiedEl) unifiedEl.style.display = (section === 'all' || section === 'descriptive' || section === 'predictive') ? 'block' : 'none';

      container.querySelectorAll('.analytics-tab-btn').forEach(b => {
        const isCurrent = b.getAttribute('data-section') === section;
        b.style.background = isCurrent ? 'var(--brand-500)' : 'transparent';
        b.style.color = isCurrent ? '#ffffff' : 'var(--dark-300)';
      });
    });
  });

  // Attach Timeframe Pill click handlers (Daily / Weekly / Monthly in Asia/Manila)
  container.querySelectorAll('.analytics-tf-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const tf = e.currentTarget.getAttribute('data-timeframe') || 'daily';
      state.analyticsTimeframe = tf;
      container.querySelectorAll('.analytics-tf-btn').forEach(b => {
        const isCurrent = b.getAttribute('data-timeframe') === tf;
        b.style.background = isCurrent ? 'var(--brand-500)' : 'transparent';
        b.style.color = isCurrent ? '#ffffff' : 'var(--dark-300)';
      });
      initAnalyticsCharts(desc, pred, presc);
    });
  });

  // Attach Export CSV button
  document.getElementById('btn-export-analytics-csv')?.addEventListener('click', () => {
    openExportCsvModal();
  });

  // Attach Refresh button
  document.getElementById('btn-refresh-analytics')?.addEventListener('click', () => {
    renderAnalyticsTab();
  });

  // Render Charts with Chart.js
  setTimeout(() => {
    initAnalyticsCharts(desc, pred, presc);
  }, 60);

  } catch (err) {
    console.error('[Analytics Load Error]', err);
    const errorMsg = err?.response?.data?.message || err?.message || 'Unable to retrieve verified analytics records from the database.';
    container.innerHTML = `
      <div class="flex flex-col items-center justify-center p-8 sm:p-12 text-center" style="min-height: 380px;">
        <div class="card p-8" style="max-width: 480px; width: 100%; border-top: 4px solid var(--brand-500); box-shadow: 0 10px 25px -5px rgba(0,0,0,0.3);">
          <div class="flex justify-center mb-4">
            <div style="background: rgba(220, 38, 38, 0.15); width: 60px; height: 60px; border-radius: 50%; display: flex; align-items: center; justify-content: center; color: var(--brand-500);">
              ${Icons.alert({ size: 32, color: 'var(--brand-500)' })}
            </div>
          </div>
          <h2 class="text-xl font-bold text-white mb-2">Unable to Load Analytics</h2>
          <p class="text-xs text-dark-300 mb-6 leading-relaxed">
            ${escapeHtml(errorMsg)}
          </p>
          <div class="flex justify-center">
            <button id="btn-retry-analytics" class="btn btn-primary flex items-center gap-2 px-6 py-2.5">
              ${Icons.refresh({ size: 16 })} Retry Data Retrieval
            </button>
          </div>
        </div>
      </div>
    `;

    document.getElementById('btn-retry-analytics')?.addEventListener('click', () => {
      renderAnalyticsTab();
    });
  }
}

function initAnalyticsCharts(desc = {}, pred = {}, presc = {}) {
  try {
    if (typeof Chart === 'undefined') return;

  // Destroy previous instances if any
  if (state.charts.revenue) { state.charts.revenue.destroy(); state.charts.revenue = null; }
  if (state.charts.sales) { state.charts.sales.destroy(); state.charts.sales = null; }
  if (state.charts.products) { state.charts.products.destroy(); state.charts.products = null; }

  const isLight = document.body.classList.contains('light-mode');
  const gridColor = isLight ? 'rgba(0, 0, 0, 0.06)' : 'rgba(255, 255, 255, 0.06)';
  const tickColor = isLight ? '#475569' : '#94a3b8';

  // 1. Unified Revenue Timeline Chart: Descriptive Actuals (Solid) & Predictive Forecasts (Dashed)
  const revenueCanvas = document.getElementById('revenueChart');
  if (revenueCanvas) {
    const tf = state.analyticsTimeframe || 'daily';
    const salesSeries = tf === 'weekly'
      ? (desc?.weekly_sales || desc?.daily_sales)
      : (tf === 'monthly' ? (desc?.monthly_sales || desc?.daily_sales) : desc?.daily_sales);
    const rawHistLabels = salesSeries?.labels ? salesSeries.labels : [];
    const rawHistData = salesSeries?.data ? salesSeries.data : [];

    // Slice last 14 historical intervals for clean readability
    const histLabels = rawHistLabels.slice(-14);
    const histData = rawHistData.slice(-14);

    const fLabels = (tf === 'daily' && pred && Array.isArray(pred.forecast_labels)) ? pred.forecast_labels : [];
    const fData = (tf === 'daily' && pred && Array.isArray(pred.forecast_data)) ? pred.forecast_data : [];

    const formatDate = (str) => {
      if (!str) return '';
      try {
        const parts = str.split('-');
        if (parts.length === 3) {
          const mNames = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
          return `${mNames[parseInt(parts[1], 10) - 1]} ${parseInt(parts[2], 10)}`;
        }
      } catch (e) {}
      return str;
    };

    let combinedLabels = [];
    let actualSeries = [];
    let forecastSeries = [];
    const nHist = histLabels.length;

    if (nHist === 0 && fLabels.length === 0) {
      combinedLabels = ['No Sales Recorded'];
      actualSeries = [0];
      forecastSeries = [0];
    } else {
      // Historical actual labels + Future forecast labels with distinct [Est] indicator
      combinedLabels = [
        ...histLabels.map(formatDate),
        ...fLabels.map(l => `${formatDate(l)} [Est]`)
      ];

      // Actual Series: Verified Firestore data on historical dates, null on future forecast dates
      actualSeries = [
        ...histData,
        ...fLabels.map(() => null)
      ];

      // Forecast Series: null on past dates, seamlessly bridged at the latest actual date, and forecasted values on future dates
      if (fData.length > 0) {
        if (nHist > 0) {
          const lastActualVal = histData[nHist - 1];
          const nullsBeforeBridge = Array(Math.max(0, nHist - 1)).fill(null);
          forecastSeries = [...nullsBeforeBridge, lastActualVal, ...fData];
        } else {
          forecastSeries = [...fData];
        }
      } else {
        forecastSeries = combinedLabels.map(() => null);
      }
    }

    const ctx = revenueCanvas.getContext('2d');
    let actualGradient = null;
    let forecastGradient = null;
    if (ctx) {
      actualGradient = ctx.createLinearGradient(0, 0, 0, 260);
      actualGradient.addColorStop(0, 'rgba(16, 185, 129, 0.28)');
      actualGradient.addColorStop(1, 'rgba(16, 185, 129, 0.0)');

      forecastGradient = ctx.createLinearGradient(0, 0, 0, 260);
      forecastGradient.addColorStop(0, 'rgba(59, 130, 246, 0.12)');
      forecastGradient.addColorStop(1, 'rgba(59, 130, 246, 0.0)');
    }

    const forecastMethodLabel = pred.has_sufficient_data
      ? 'Forecasted Revenue (OLS Linear Regression)'
      : (pred.is_preliminary
        ? 'Forecasted Revenue (Preliminary Run-Rate Baseline)'
        : 'Forecasted Revenue (Awaiting Sales Data)');

    state.charts.revenue = new Chart(revenueCanvas, {
      type: 'line',
      data: {
        labels: combinedLabels,
        datasets: [
          {
            label: 'Actual Revenue (Verified Firestore)',
            data: actualSeries,
            borderColor: '#10b981',
            borderWidth: 2.8,
            borderDash: [],
            backgroundColor: actualGradient || 'rgba(16, 185, 129, 0.08)',
            fill: true,
            tension: 0.25,
            pointBackgroundColor: '#10b981',
            pointBorderColor: '#ffffff',
            pointBorderWidth: 1.5,
            pointRadius: 4.5,
            pointHoverRadius: 7,
            pointStyle: 'circle',
            spanGaps: false
          },
          {
            label: forecastMethodLabel,
            data: forecastSeries,
            borderColor: '#3b82f6',
            borderWidth: 2.5,
            borderDash: [6, 6],
            backgroundColor: forecastGradient || 'rgba(59, 130, 246, 0.04)',
            fill: false,
            tension: 0.25,
            pointBackgroundColor: '#3b82f6',
            pointBorderColor: '#ffffff',
            pointBorderWidth: 1.5,
            pointRadius: 5,
            pointHoverRadius: 7.5,
            pointStyle: 'rectRot',
            spanGaps: false
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: {
          mode: 'index',
          intersect: false
        },
        plugins: {
          legend: {
            display: true,
            position: 'top',
            align: 'end',
            labels: {
              color: isLight ? '#334155' : '#cbd5e1',
              usePointStyle: true,
              pointStyleWidth: 12,
              padding: 14,
              font: {
                size: 11,
                weight: '600',
                family: 'Inter, sans-serif'
              }
            }
          },
          tooltip: {
            backgroundColor: 'rgba(15, 23, 42, 0.95)',
            titleColor: '#ffffff',
            bodyColor: '#cbd5e1',
            borderColor: 'rgba(255, 255, 255, 0.12)',
            borderWidth: 1,
            padding: 10,
            callbacks: {
              label: function(context) {
                const val = context.raw;
                if (val === null || val === undefined) return null;
                const formatted = `₱${Number(val).toFixed(2)}`;
                if (context.datasetIndex === 0) {
                  return ` Actual Revenue: ${formatted}`;
                } else {
                  if (context.dataIndex === (nHist - 1) && nHist > 0) {
                    return ` Baseline Bridge: ${formatted}`;
                  }
                  const tag = pred.has_sufficient_data ? 'OLS Regression' : (pred.is_preliminary ? 'Run-Rate Baseline' : 'Projection');
                  return ` Forecast (${tag}): ${formatted}`;
                }
              },
              afterBody: function(tooltipItems) {
                if (!tooltipItems || tooltipItems.length === 0) return '';
                const idx = tooltipItems[0].dataIndex;
                if (idx >= nHist && nHist > 0) {
                  return ['\nForecast: Projected estimate based on historical trends.'];
                }
                return '';
              }
            }
          }
        },
        scales: {
          x: {
            grid: { color: gridColor },
            ticks: {
              color: tickColor,
              font: { size: 11 }
            }
          },
          y: {
            beginAtZero: true,
            ticks: {
              color: tickColor,
              font: { size: 11 },
              callback: (value) => `₱${value}`
            },
            grid: { color: gridColor }
          }
        }
      }
    });
  }

  // 2. Sales Chart from Peak Hours or Daily Sales
  const salesCanvas = document.getElementById('salesChart');
  if (salesCanvas) {
    let hours = [];
    let salesData = [];

    if (desc.peak_hours && desc.peak_hours.length > 0) {
      // Filter shop operating hours (7am to 10pm)
      const filteredHours = desc.peak_hours.filter(h => h.hour >= 7 && h.hour <= 22);
      hours = filteredHours.map(h => h.label);
      salesData = filteredHours.map(h => h.orders);
    } else {
      hours = ['08:00', '10:00', '12:00', '14:00', '16:00', '18:00', '20:00', '22:00'];
      salesData = [0, 0, 0, 0, 0, 0, 0, 0];
    }

    state.charts.sales = new Chart(salesCanvas, {
      type: 'bar',
      data: {
        labels: hours,
        datasets: [{
          label: 'Orders',
          data: salesData,
          backgroundColor: '#dc2626',
          borderRadius: 6
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false }
        },
        scales: {
          x: { grid: { color: 'rgba(0,0,0,0.06)' }, ticks: { color: '#64748b' } },
          y: { 
            beginAtZero: true,
            ticks: { color: '#64748b', stepSize: 1 }, 
            grid: { color: 'rgba(0,0,0,0.06)' } 
          }
        }
      }
    });
  }

  // 3. Product Revenue Share Chart
  const productCanvas = document.getElementById('productChart');
  if (productCanvas) {
    let labels = [];
    let revValues = [];
    let bgColors = ['#10b981', '#3b82f6', '#dc2626', '#a855f7', '#eab308', '#ec4899', '#06b6d4'];

    const topProductsWithRev = (desc.top_products || []).filter(p => Number(p.revenue || 0) > 0);

    if (topProductsWithRev.length > 0) {
      labels = topProductsWithRev.map(p => `${p.name} (₱${Number(p.revenue).toFixed(2)})`);
      revValues = topProductsWithRev.map(p => Number(p.revenue));
    } else if (desc.top_products && desc.top_products.length > 0) {
      labels = desc.top_products.map(p => `${p.name} (${p.quantity} sold)`);
      revValues = desc.top_products.map(p => p.quantity);
    } else {
      labels = ['No Completed Sales Recorded'];
      revValues = [1];
      bgColors = ['rgba(148, 163, 184, 0.2)'];
    }

    state.charts.products = new Chart(productCanvas, {
      type: 'doughnut',
      data: {
        labels: labels,
        datasets: [{
          data: revValues,
          backgroundColor: bgColors.slice(0, revValues.length),
          borderWidth: 0
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: 'bottom', labels: { color: '#64748b', boxWidth: 12 } },
          tooltip: {
            callbacks: {
              label: (context) => ` ${context.label}`
            }
          }
        }
      }
    });
  }
  } catch (chartErr) {
    console.error('[Analytics Chart Error]', chartErr);
  }
}

// ==============================================================================
// 5. HARDWARE SIMULATOR (ESP32 & OLED) (HTML & JS)
// ==============================================================================
async function renderSimulatorTab() {
  const container = document.getElementById('tab-content');
  if (!container) return;

  let displayData = { now_serving: 0, next_queue: 0, now_serving_status: 'ready' };
  try {
    const res = await api.getQueueDisplay();
    displayData = res.data;
  } catch (e) {}

  container.innerHTML = `
    <div class="flex flex-wrap items-center justify-between gap-4 mb-6">
      <div>
        <h1 class="text-2xl font-bold text-white">Hardware Simulator</h1>
      </div>
    </div>

    <div class="grid-2 mb-6">
      <!-- OLED Display Module -->
      <div class="card p-6">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-base font-bold text-white flex items-center gap-2">
            ${Icons.hardware({ size: 18, color: 'var(--emerald-400)' })} OLED Queue Display
          </h3>
          <span class="badge badge-green" id="esp32-status-badge">ESP32 Connected</span>
        </div>

        <div class="oled-display mb-4 text-center">
          <div style="font-size: 13px; letter-spacing: 2px; color: #4ade80;">=== KEVS SIOMAI QUEUE ===</div>
          <div style="font-size: 11px; margin: 4px 0; color: #22c55e;">━━━━━━━━━━━━━━━━━━━━━━━━━</div>
          <div class="flex justify-around items-center my-3">
            <div>
              <div style="font-size: 10px; opacity: 0.8;">NOW SERVING</div>
              <div style="font-size: 32px; font-weight: bold; color: #4ade80;" id="sim-oled-now">#${displayData.now_serving || '—'}</div>
            </div>
            <div style="width: 1px; height: 40px; background: #166534;"></div>
            <div>
              <div style="font-size: 10px; opacity: 0.8;">NEXT QUEUE</div>
              <div style="font-size: 32px; font-weight: bold; color: #4ade80;" id="sim-oled-next">#${displayData.next_queue || 1}</div>
            </div>
          </div>
          <div style="font-size: 11px; letter-spacing: 1px; color: #86efac;" id="sim-oled-msg">PLEASE PROCEED TO COUNTER</div>
        </div>

        <!-- Simulator Pushbuttons -->
        <div class="flex flex-wrap gap-3">
          <button id="btn-sim-press-walkin" class="btn btn-primary flex-1 justify-center flex items-center gap-1.5">
            ${Icons.plusCircle({ size: 16 })} Walk-in Ticket
          </button>
          <button id="btn-sim-call-next" class="btn btn-success flex-1 justify-center flex items-center gap-1.5">
            ${Icons.bullhorn({ size: 16 })} Call Next
          </button>
          <button id="btn-sim-beep" class="btn btn-secondary justify-center flex items-center gap-1.5">
            ${Icons.bellRing({ size: 16 })} Test Buzzer
          </button>
        </div>
      </div>

      <!-- ESP32 Serial Monitor Log -->
      <div class="card p-6">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-base font-bold text-white flex items-center gap-2">
            ${Icons.terminal({ size: 18, color: 'var(--blue-400)' })} Serial Monitor
          </h3>
          <button id="btn-clear-serial" class="btn btn-ghost" style="font-size: 12px; padding: 4px 8px;">
            Clear Log
          </button>
        </div>

        <div class="serial-log" id="sim-serial-log">
          <div style="color: #64748b;">[00:00:00] [BOOT] ESP32-WROOM-32 booting up...</div>
          <div style="color: #64748b;">[00:00:01] [WIFI] Connected to AP (SSID: Kevs_WiFi_POS, RSSI: -54 dBm)</div>
          <div style="color: #64748b;">[00:00:01] [OLED] SSD1306 initialized via I2C at 0x3C</div>
          <div style="color: #64748b;">[00:00:02] [HTTP] GET /api/queue/display -> 200 OK</div>
          <div style="color: #22c55e;">[00:00:02] [READY] Queue system synchronized. Ready for hardware triggers.</div>
        </div>
      </div>
    </div>
  `;

  bindSimulatorEvents();
}

async function updateSimulatorOLED() {
  try {
    const res = await api.getQueueDisplay();
    const data = res.data;
    const oledNow = document.getElementById('sim-oled-now');
    const oledNext = document.getElementById('sim-oled-next');
    if (oledNow) oledNow.textContent = `#${data.now_serving || '—'}`;
    if (oledNext) oledNext.textContent = `#${data.next_queue || 1}`;
  } catch (e) {}
}

function appendSerialLog(msg, color = '#4ade80') {
  const log = document.getElementById('sim-serial-log');
  if (!log) return;
  const time = new Date().toLocaleTimeString();
  const line = document.createElement('div');
  line.style.color = color;
  line.textContent = `[${time}] ${msg}`;
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
}

function bindSimulatorEvents() {
  document.getElementById('btn-sim-beep')?.addEventListener('click', () => {
    playBeep();
    appendSerialLog('[BUZZER] Piezo active: Frequency 1000Hz, Duration 300ms', '#facc15');
    showToast('info', 'Buzzer', 'Piezo buzzer simulated successfully!');
  });

  document.getElementById('btn-sim-press-walkin')?.addEventListener('click', async () => {
    playBeep();
    appendSerialLog('[GPIO] Button pin 14 pressed (Active LOW, Debounce: 50ms)', '#38bdf8');
    appendSerialLog('[HTTP] POST /api/queue/add (Walk-in button trigger)', '#818cf8');

    try {
      const res = await api.addToQueue({
        type: 'walk-in',
        order_type: 'pickup',
        customer_name: 'Walk-in (ESP32 Button)',
        payment_method: 'Cash',
        items: [{ product_id: 1, quantity: 1 }],
        notes: 'ESP32 Physical Button'
      });

      const queueNo = res.data?.order?.queue_no || res.data?.queue?.current_queue_no;
      appendSerialLog(`[OLED] Ticket #${queueNo} issued! Rendering frame buffer...`, '#22c55e');
      showToast('success', 'ESP32 Ticket', `Issued ticket #${queueNo} from hardware button!`);
      await updateSimulatorOLED();
    } catch (e) {
      appendSerialLog(`[ERROR] HTTP POST failed: ${e.message}`, '#ef4444');
      showToast('error', 'ESP32 Error', e.message);
    }
  });

  document.getElementById('btn-sim-call-next')?.addEventListener('click', async () => {
    playBeep();
    appendSerialLog('[HTTP] POST /api/queue/call-next (Advancing queue ticket)', '#38bdf8');
    try {
      const res = await api.callNextOrder();
      appendSerialLog(`[OLED] ${res.data?.message || 'Now calling next ticket'}`, '#22c55e');
      showToast('info', 'Customer Called', res.data?.message || 'Now calling next ticket!');
      await updateSimulatorOLED();
    } catch (e) {
      appendSerialLog(`[ERROR] Call Next failed: ${e.message}`, '#ef4444');
    }
  });

  document.getElementById('btn-clear-serial')?.addEventListener('click', async () => {
    const log = document.getElementById('sim-serial-log');
    if (!log) return;
    if (log.children.length > 1) {
      const confirmed = await swal.confirm({
        title: 'Clear Serial Output?',
        text: 'Are you sure you want to clear the simulated hardware serial monitor log?',
        icon: 'warning',
        confirmText: 'Yes, Clear Log',
        cancelText: 'Cancel'
      });
      if (!confirmed) return;
    }
    log.innerHTML = '<div style="color: #64748b;">Log cleared.</div>';
    showToast('info', 'Console Cleared', 'Serial log buffer reset.');
  });
}

// ==============================================================================
// 6. FIREWALL & SECURITY DASHBOARD (HTML & JS)
// ==============================================================================
async function renderFirewallTab() {
  const container = document.getElementById('tab-content');
  if (!container) return;

  container.innerHTML = `
    <div class="flex items-center justify-center p-8">
      <div class="spinner"></div>
    </div>
  `;

  let stats = {
    status: 'active',
    total_scanned: 0,
    total_blocked: 0,
    threat_counts: {},
    rules_count: 28,
    active_engines: {},
    banned_ips: [],
    blacklisted_ips: []
  };
  let logs = [];

  try {
    const [statsRes, logsRes] = await Promise.all([
      api.getFirewallStats(),
      api.getFirewallLogs()
    ]);
    stats = statsRes.data;
    logs = logsRes.data?.logs || [];
    state.firewallStats = stats;
    state.firewallLogs = logs;
  } catch (err) {
    console.warn('Firewall API fetch failed:', err);
  }

  container.innerHTML = `
    <!-- Top Header Banner -->
    <div class="card p-6 mb-6 firewall-shield-card">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div class="flex items-center gap-4">
          <div style="width: 56px; height: 56px; border-radius: 16px; background: rgba(16, 185, 129, 0.2); border: 1px solid rgba(16, 185, 129, 0.4); display: flex; align-items: center; justify-content: center; color: var(--emerald-400);">
            ${Icons.shield({ size: 30, color: 'var(--emerald-400)' })}
          </div>
          <div>
            <div class="flex items-center gap-2">
              <h1 class="text-2xl font-bold text-white">Web Application Firewall</h1>
              <span class="badge badge-green flex items-center gap-1">
                <span class="waf-pulse"></span> Active
              </span>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-3">
          <button id="btn-refresh-waf" class="btn btn-secondary flex items-center gap-1.5">
            ${Icons.refresh({ size: 15 })} Refresh Status
          </button>
        </div>
      </div>
    </div>

    <!-- 4 Firewall Stat Metrics -->
    <div class="grid-4 mb-6">
      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(59,130,246,0.2); color: var(--blue-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.activity({ size: 24, color: 'var(--blue-500)' })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">REQUESTS SCANNED</div>
          <div class="text-3xl font-bold text-white">${stats.total_scanned || 0}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(239,68,68,0.2); color: var(--red-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.shieldAlert({ size: 24, color: 'var(--red-500)' })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">THREATS INTERCEPTED</div>
          <div class="text-3xl font-bold text-red-400">${stats.total_blocked || 0}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(234,179,8,0.2); color: var(--yellow-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.lock({ size: 24, color: 'var(--yellow-600)' })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">BANNED IPS</div>
          <div class="text-3xl font-bold text-white">${(stats.banned_ips_count || 0) + (stats.blacklisted_ips_count || 0)}</div>
        </div>
      </div>

      <div class="card stat-card">
        <div class="stat-icon" style="background: rgba(16,185,129,0.2); color: var(--emerald-400); display: flex; align-items: center; justify-content: center;">
          ${Icons.shieldCheck({ size: 24, color: 'var(--emerald-500)' })}
        </div>
        <div>
          <div class="text-xs text-dark-300 font-medium">ACTIVE RULES</div>
          <div class="text-3xl font-bold text-emerald-400">${stats.rules_count || 28} Rules</div>
        </div>
      </div>
    </div>

    <!-- Active Engines Badges -->
    <div class="card p-5 mb-6">
      <h3 class="text-sm font-bold text-white mb-3 flex items-center gap-2">
        ${Icons.sliders({ size: 16, color: 'var(--brand-500)' })} Active Inspection Engines
      </h3>
      <div class="grid-3 gap-3">
        <div class="waf-engine-badge active">
          <span class="waf-pulse"></span>
          <div>
            <div class="text-white text-xs font-bold">SQL Injection (SQLi) Engine</div>
            <div class="text-dark-400 text-[11px]">Tautology, union, stacked queries</div>
          </div>
        </div>

        <div class="waf-engine-badge active">
          <span class="waf-pulse"></span>
          <div>
            <div class="text-white text-xs font-bold">Cross-Site Scripting (XSS) Engine</div>
            <div class="text-dark-400 text-[11px]">Script tags, event handlers, DOM injection</div>
          </div>
        </div>

        <div class="waf-engine-badge active">
          <span class="waf-pulse"></span>
          <div>
            <div class="text-white text-xs font-bold">Path Traversal & LFI Filter</div>
            <div class="text-dark-400 text-[11px]">Directory climbing, sensitive files</div>
          </div>
        </div>

        <div class="waf-engine-badge active">
          <span class="waf-pulse"></span>
          <div>
            <div class="text-white text-xs font-bold">Vulnerability Scanner Blocker</div>
            <div class="text-dark-400 text-[11px]">sqlmap, nikto, dirbuster, gobuster</div>
          </div>
        </div>

        <div class="waf-engine-badge active">
          <span class="waf-pulse"></span>
          <div>
            <div class="text-white text-xs font-bold">Sliding-Window Rate Limiter</div>
            <div class="text-dark-400 text-[11px]">120 req/min general, 15 req/min auth</div>
          </div>
        </div>

        <div class="waf-engine-badge active">
          <span class="waf-pulse"></span>
          <div>
            <div class="text-white text-xs font-bold">OWASP Security Headers</div>
            <div class="text-dark-400 text-[11px]">CSP, X-Frame, XSS-Protection, HSTS</div>
          </div>
        </div>
      </div>
    </div>

    <!-- Interactive Penetration Test Suite -->
    <!-- Threat Simulation -->
    <div class="card p-6 mb-6 threat-test-card">
      <div class="flex items-center gap-3 mb-2">
        <div style="width: 44px; height: 44px; border-radius: 12px; background: rgba(220, 38, 38, 0.12); display: flex; align-items: center; justify-content: center; color: var(--brand-500); flex-shrink: 0;">
          ${Icons.target({ size: 24, color: 'var(--brand-500)' })}
        </div>
        <div>
          <h3 class="text-lg font-bold text-white">Threat Simulation</h3>
        </div>
      </div>

      <div class="flex flex-wrap gap-3 mt-4">
        <button class="btn btn-secondary btn-test-waf flex items-center gap-2" data-type="sqli" style="border-color: rgba(220,38,38,0.4);">
          ${Icons.database({ size: 15, color: '#dc2626' })} SQL Injection
        </button>
        <button class="btn btn-secondary btn-test-waf flex items-center gap-2" data-type="xss" style="border-color: rgba(245,158,11,0.4);">
          ${Icons.zap({ size: 15, color: '#ca8a04' })} XSS Script
        </button>
        <button class="btn btn-secondary btn-test-waf flex items-center gap-2" data-type="path_traversal" style="border-color: rgba(168,85,247,0.4);">
          ${Icons.folder({ size: 15, color: '#9333ea' })} Path Traversal
        </button>
        <button class="btn btn-secondary btn-test-waf flex items-center gap-2" data-type="scanner" style="border-color: rgba(59,130,246,0.4);">
          ${Icons.bot({ size: 15, color: '#2563eb' })} Scanner Bot
        </button>
        <button class="btn btn-secondary btn-test-waf flex items-center gap-2" data-type="rce" style="border-color: rgba(220,38,38,0.4);">
          ${Icons.terminal({ size: 15, color: '#dc2626' })} RCE Command
        </button>
      </div>

      <!-- Live Test Result Banner -->
      <div id="waf-test-result" class="waf-test-result" style="display: none;"></div>
    </div>

    <!-- Security Event Logs Table -->
    <div class="card p-6 overflow-hidden">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-base font-bold text-white flex items-center gap-2">
          ${Icons.fileText({ size: 18, color: 'var(--brand-500)' })} <span>Security Incident Log</span>
        </h3>
        <span class="text-xs text-dark-400">${logs.length} incidents</span>
      </div>

      <div style="overflow-x: auto;">
        <table style="width: 100%; border-collapse: collapse; text-align: left;">
          <thead>
            <tr style="border-bottom: 1px solid var(--dark-600); color: var(--dark-400); font-size: 12px; text-transform: uppercase;">
              <th class="py-3 px-4">Timestamp</th>
              <th class="py-3 px-4">Client IP</th>
              <th class="py-3 px-4">Threat Type</th>
              <th class="py-3 px-4">Endpoint</th>
              <th class="py-3 px-4">Action</th>
              <th class="py-3 px-4">Incident Details</th>
            </tr>
          </thead>
          <tbody id="waf-logs-tbody">
            ${logs.length === 0 ? `
              <tr>
                <td colspan="6" class="py-8 text-center text-dark-400 text-sm">
                  <div class="flex items-center justify-center gap-2">
                    ${Icons.shieldCheck({ size: 18, color: 'var(--emerald-500)' })}
                    <span>No security violations recorded yet. All traffic clean!</span>
                  </div>
                </td>
              </tr>
            ` : logs.map(log => `
              <tr style="border-bottom: 1px solid var(--dark-600); font-size: 13px;">
                <td class="py-3 px-4 text-dark-300 font-mono">${new Date(log.timestamp).toLocaleTimeString()}</td>
                <td class="py-3 px-4 font-bold text-white font-mono">${escapeHtml(log.ip)}</td>
                <td class="py-3 px-4">
                  <span class="threat-tag threat-${(log.threat_type || '').toLowerCase()}">${escapeHtml(log.threat_type)}</span>
                </td>
                <td class="py-3 px-4 text-dark-300 font-mono">${escapeHtml(log.method || 'GET')} ${escapeHtml(log.path || '/')}</td>
                <td class="py-3 px-4">
                  <span class="badge badge-red">BLOCKED 403</span>
                </td>
                <td class="py-3 px-4 text-dark-300 font-mono text-xs" style="max-width: 280px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                  ${escapeHtml(log.details || 'Attack signature matched')}
                </td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      </div>
    </div>
  `;

  bindFirewallEvents();
}

function bindFirewallEvents() {
  document.getElementById('btn-refresh-waf')?.addEventListener('click', () => {
    showToast('info', 'Refreshing', 'Updating firewall telemetry...');
    renderFirewallTab();
  });

  document.querySelectorAll('.btn-test-waf').forEach(btn => {
    btn.addEventListener('click', async (e) => {
      const type = e.currentTarget.getAttribute('data-type');
      if (!type) return;

      e.currentTarget.disabled = true;
      e.currentTarget.innerHTML = `${Icons.spinner({ size: 14 })} Testing...`;

      try {
        const res = await api.testFirewallThreat({ threat_type: type });
        playBeep();
        showToast('success', 'Firewall Intercepted!', `Simulated ${type.toUpperCase()} attack blocked with HTTP 403!`);

        const resultBox = document.getElementById('waf-test-result');
        if (resultBox) {
          resultBox.style.display = 'block';
          resultBox.innerHTML = `
            <div style="color: #16a34a; font-weight: bold; margin-bottom: 6px; display: flex; align-items: center; gap: 6px;">
              ${Icons.shieldCheck({ size: 16, color: '#16a34a' })} [FIREWALL BLOCKED] Simulated ${type.toUpperCase()} Intercepted!
            </div>
            <div class="waf-test-payload" style="margin-bottom: 4px;"><strong>Payload Tested:</strong> <code class="waf-payload-code">${escapeHtml(res.data?.result?.payload)}</code></div>
            <div class="waf-test-action" style="margin-top: 4px;"><strong>Firewall Action:</strong> <span style="color: #dc2626; font-weight: bold;">${escapeHtml(res.data?.result?.firewall_action)}</span></div>
            <div class="text-xs text-dark-400" style="margin-top: 6px;">Incident successfully recorded in live security log.</div>
          `;
        }

        // Re-render logs in table
        const logsRes = await api.getFirewallLogs();
        const tbody = document.getElementById('waf-logs-tbody');
        if (tbody && logsRes.data?.logs) {
          tbody.innerHTML = logsRes.data.logs.map(log => `
            <tr style="border-bottom: 1px solid var(--dark-600); font-size: 13px;">
              <td class="py-3 px-4 text-dark-300 font-mono">${new Date(log.timestamp).toLocaleTimeString()}</td>
              <td class="py-3 px-4 font-bold text-white font-mono">${escapeHtml(log.ip)}</td>
              <td class="py-3 px-4">
                <span class="threat-tag threat-${(log.threat_type || '').toLowerCase()}">${escapeHtml(log.threat_type)}</span>
              </td>
              <td class="py-3 px-4 text-dark-300 font-mono">${escapeHtml(log.method || 'GET')} ${escapeHtml(log.path || '/')}</td>
              <td class="py-3 px-4">
                <span class="badge badge-red">BLOCKED 403</span>
              </td>
              <td class="py-3 px-4 text-dark-300 font-mono text-xs" style="max-width: 280px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                ${escapeHtml(log.details || 'Attack signature matched')}
              </td>
            </tr>
          `).join('');
        }
      } catch (err) {
        showToast('error', 'Test Failed', err.message);
      } finally {
        e.currentTarget.disabled = false;
        const testLabels = {
          sqli: { label: 'SQL Injection', icon: Icons.database({ size: 15, color: '#dc2626' }) },
          xss: { label: 'XSS Script', icon: Icons.zap({ size: 15, color: '#ca8a04' }) },
          path_traversal: { label: 'Path Traversal', icon: Icons.folder({ size: 15, color: '#9333ea' }) },
          scanner: { label: 'Scanner Bot', icon: Icons.bot({ size: 15, color: '#2563eb' }) },
          rce: { label: 'RCE Command', icon: Icons.terminal({ size: 15, color: '#dc2626' }) }
        };
        const conf = testLabels[type] || { label: type.toUpperCase(), icon: Icons.target({ size: 15 }) };
        e.currentTarget.innerHTML = `${conf.icon} ${conf.label}`;
      }
    });
  });
}
