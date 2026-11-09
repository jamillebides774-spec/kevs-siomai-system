/**
 * Sync Manager (Vanilla JS)
 * Syncs offline IndexedDB orders to Flask backend upon reconnect.
 */

import { getUnsynced, markAsSynced } from './indexedDb.js';
import { syncOffline } from './api.js';

export let isOnline = navigator.onLine;
let syncInProgress = false;
let onStatusChange = null;
let onSyncComplete = null;

function generateUUID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

export function initSyncManager({ onStatusChange: statusCb, onSyncComplete: syncCb } = {}) {
  onStatusChange = statusCb;
  onSyncComplete = syncCb;

  window.addEventListener('online', handleOnline);
  window.addEventListener('offline', handleOffline);

  if (onStatusChange) onStatusChange(navigator.onLine);

  return () => {
    window.removeEventListener('online', handleOnline);
    window.removeEventListener('offline', handleOffline);
  };
}

function handleOnline() {
  isOnline = true;
  if (onStatusChange) onStatusChange(true);
  setTimeout(() => syncOfflineData(), 1000);
}

function handleOffline() {
  isOnline = false;
  if (onStatusChange) onStatusChange(false);
}

export async function syncOfflineData() {
  if (syncInProgress || !navigator.onLine) return { synced: 0 };
  syncInProgress = true;

  try {
    const unsynced = await getUnsynced();
    if (!unsynced || unsynced.length === 0) {
      syncInProgress = false;
      return { synced: 0, message: 'Nothing to sync' };
    }

    const batchId = generateUUID();
    const payload = {
      batch_id: batchId,
      source: 'admin_pwa',
      orders: unsynced.map(o => ({
        type: o.type || 'walk-in',
        order_type: o.order_type || 'pickup',
        customer_name: o.customer_name || 'Offline Walk-in',
        customer_phone: o.customer_phone || '',
        items: o.items || [],
        total: o.total || 0,
        status: o.status || 'completed',
        payment_status: o.payment_status || 'confirmed',
        payment_method: o.payment_method || 'Cash',
        notes: o.notes || '',
        created_at: o.created_at,
      }))
    };

    const res = await syncOffline(payload);
    const localIds = unsynced.map(o => o.local_id);
    await markAsSynced(localIds);

    const result = {
      synced: res.data?.orders_synced ?? unsynced.length,
      batch_id: batchId,
      message: res.data?.message || 'Sync successful'
    };

    if (onSyncComplete) onSyncComplete(result);
    return result;
  } catch (err) {
    console.error('[SyncManager] Sync error:', err.message);
    return { synced: 0, error: err.message };
  } finally {
    syncInProgress = false;
  }
}

export function getOnlineStatus() {
  return navigator.onLine;
}
