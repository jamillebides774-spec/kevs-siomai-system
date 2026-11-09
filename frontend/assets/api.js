// ─── API Service (vanilla JS replacement of axios) ─────────────────────────

const BASE = '/api';

async function request(method, path, data = null, params = null) {
  let url = BASE + path;
  if (params) {
    const qs = new URLSearchParams(params).toString();
    if (qs) url += '?' + qs;
  }
  const opts = {
    method,
    headers: { 'Content-Type': 'application/json' },
  };
  if (data) opts.body = JSON.stringify(data);

  const res = await fetch(url, opts);
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(json.error || `HTTP ${res.status}`);
    err.response = { data: json, status: res.status };
    throw err;
  }
  return { data: json, status: res.status };
}

// Auth
export const login            = (creds) => request('POST', '/auth/login', creds);
export const getMe            = ()      => request('GET',  '/auth/me');

// Dashboard
export const getDashboardStats = ()     => request('GET',  '/dashboard/stats');

// Queue
export const getQueue         = ()      => request('GET',  '/queue');
export const getAllOrders      = (p)    => request('GET',  '/queue/all', null, p);
export const addToQueue        = (d)    => request('POST', '/queue/add', d);
export const removeFromQueue   = (id)  => request('POST', '/queue/remove', { order_id: id });
export const callNextOrder     = ()    => request('POST', '/queue/call-next');
export const resetQueue        = ()    => request('POST', '/queue/reset');
export const getQueueDisplay   = ()    => request('GET',  '/queue/display');

// Orders
export const getOrders         = (p)   => request('GET',  '/orders', null, p);
export const getOrder          = (id)  => request('GET',  `/orders/${id}`);
export const createOrder       = (d)   => request('POST', '/orders', d);
export const updateOrderStatus = (id, d) => request('PUT', `/orders/${id}`, d);
export const clearAllOrders    = ()    => request('POST', '/orders/clear');

// Products
export const getProducts   = (all = false) => request('GET', '/products', null, { all: all ? 'true' : 'false' });
export const createProduct = (d)  => request('POST', '/products', d);
export const updateProduct = (id, d) => request('PUT', `/products/${id}`, d);
export const deleteProduct = (id) => request('DELETE', `/products/${id}`);
export const updateStock   = (id, d) => request('PUT', `/inventory/${id}`, d);

// Payments & Receiving Account Management
export const initiateGCash  = (orderId, accountId = null) => request('POST', '/payments/gcash', { order_id: orderId, payment_account_id: accountId });
export const gcashCallback  = (d)       => request('POST', '/payments/gcash/callback', d);
export const confirmPayment = (id, method, accountId = null) => request('PUT', `/payments/confirm/${id}`, { payment_method: method, payment_account_id: accountId });
export const getPaymentAccounts        = ()        => request('GET',    '/payment-accounts');
export const createPaymentAccount      = (d)       => request('POST',   '/payment-accounts', d);
export const updatePaymentAccount      = (id, d)   => request('PUT',    `/payment-accounts/${id}`, d);
export const togglePaymentAccount      = (id, val = null) => request('PUT', `/payment-accounts/${id}/toggle`, val !== null ? { is_active: val } : {});
export const deletePaymentAccount      = (id)      => request('DELETE', `/payment-accounts/${id}`);
export const selectOrderPaymentAccount = (orderId, accountId) => request('PUT', `/orders/${orderId}/payment-account`, { payment_account_id: accountId });

// Analytics
export const getDescriptive   = () => request('GET', '/analytics/descriptive');
export const getPredictive    = () => request('GET', '/analytics/predictive');
export const getPrescriptive  = () => request('GET', '/analytics/prescriptive');
export const exportSalesCsv   = (params) => {
  let url = BASE + '/analytics/export-csv';
  if (params) {
    const qs = new URLSearchParams(params).toString();
    if (qs) url += '?' + qs;
  }
  return url;
};
export const downloadSalesCsv = async (params) => {
  let url = BASE + '/analytics/export-csv';
  if (params) {
    const qs = new URLSearchParams(params).toString();
    if (qs) url += '?' + qs;
  }
  const res = await fetch(url);
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.error || `Export failed with HTTP ${res.status}`);
  }
  const blob = await res.blob();
  const disposition = res.headers.get('content-disposition') || '';
  let filename = 'kevs_siomai_sales.csv';
  const match = disposition.match(/filename="?([^";]+)"?/);
  if (match && match[1]) filename = match[1];
  return { blob, filename, recordCount: res.headers.get('x-record-count'), totalRevenue: res.headers.get('x-total-revenue') };
};

// Offline Sync
export const syncOffline = (d) => request('POST', '/offline/sync', d);

// Firewall & Security
export const getFirewallStats    = ()  => request('GET',  '/firewall/stats');
export const getFirewallLogs     = ()  => request('GET',  '/firewall/logs');
export const testFirewallThreat  = (d) => request('POST', '/firewall/test', d);
export const blockFirewallIp     = (d) => request('POST', '/firewall/block-ip', d);
export const unblockFirewallIp   = (d) => request('POST', '/firewall/unblock-ip', d);
export const toggleFirewall      = (d) => request('POST', '/firewall/toggle', d);

// Reviews
export const getReviews          = (includeDisabled = true) => request('GET', '/reviews', null, { include_disabled: includeDisabled ? 'true' : 'false' });
export const createReview        = (d) => request('POST', '/reviews', d);
export const replyReview         = (id, replyText) => request('POST', `/reviews/${id}/reply`, { reply: replyText });
export const toggleReviewStatus  = (id, isDisabled = null) => request('POST', `/reviews/${id}/toggle-status`, isDisabled !== null ? { is_disabled: isDisabled } : {});
export const clearAllReviews     = () => request('POST', '/reviews/clear');
export const deleteReview        = (id) => request('DELETE', `/reviews/${id}`);



