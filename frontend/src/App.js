/**
 * App.js — Main Application Orchestrator (Vanilla JavaScript)
 * Assembles Navbar, Login, Queue, Inventory, Analytics, and Simulator components.
 */

import { renderNavbar } from './components/Navbar.js';
import { renderLoginPage } from './components/LoginPage.js';
import { renderQueueDashboard } from './components/QueueDashboard.js';
import { renderInventoryView } from './components/InventoryView.js';
import { renderAnalyticsView } from './components/AnalyticsView.js';
import { renderHardwareSimulator } from './components/HardwareSimulator.js';
import { showToast } from './components/Toast.js';

import { login as apiLogin } from './services/api.js';
import { initSyncManager, syncOfflineData } from './services/syncManager.js';
import { getUnsyncedCount } from './services/indexedDb.js';

export class KevsApp {
  constructor(rootElement) {
    this.root = rootElement;
    this.user = this.loadSavedUser();
    this.activeTab = 'queue';
    this.isOnline = navigator.onLine;
    this.unsyncedCount = 0;
    this.audioEnabled = true;
    this.socket = null;
    this.queueData = { queue: {}, orders: [] };

    this.init();
  }

  loadSavedUser() {
    try {
      const saved = localStorage.getItem('kevs_user');
      return saved ? JSON.parse(saved) : null;
    } catch (e) {
      return null;
    }
  }

  init() {
    this.initSync();
    this.render();
  }

  initSync() {
    initSyncManager({
      onStatusChange: (online) => {
        this.isOnline = online;
        showToast(online ? 'success' : 'warning', online ? 'Back Online' : 'Offline Mode', online ? 'Syncing pending orders...' : 'Walk-in orders will be cached.');
        this.renderNavbarSection();
      },
      onSyncComplete: (result) => {
        this.refreshUnsyncedCount();
        if (result.synced > 0) {
          showToast('success', 'Sync Complete', `${result.synced} offline order(s) uploaded!`);
          this.renderMainContent();
        }
      }
    });

    this.refreshUnsyncedCount();
  }

  async refreshUnsyncedCount() {
    try {
      this.unsyncedCount = await getUnsyncedCount();
      this.renderNavbarSection();
    } catch (e) {}
  }

  render() {
    if (!this.user) {
      renderLoginPage(this.root, {
        onLogin: async (creds) => {
          const res = await apiLogin(creds);
          this.user = res.data.user;
          localStorage.setItem('kevs_user', JSON.stringify(this.user));
          showToast('success', 'Welcome!', `Signed in as ${this.user.full_name || this.user.username}`);
          this.render();
        }
      });
      return;
    }

    this.root.innerHTML = `
      <div class="min-h-screen bg-dark-800 text-dark-100">
        <div id="navbar-container"></div>
        <main id="view-container" class="max-w-screen-2xl mx-auto px-4 py-6"></main>
        <div id="modal-container"></div>
        <div id="toast-container" class="fixed top-4 right-4 z-50 flex flex-col gap-2 pointer-events-none"></div>
      </div>
    `;

    this.renderNavbarSection();
    this.renderMainContent();
  }

  renderNavbarSection() {
    const navEl = this.root.querySelector('#navbar-container');
    if (!navEl) return;

    renderNavbar(navEl, {
      user: this.user,
      activeTab: this.activeTab,
      onTabChange: (tab) => {
        this.activeTab = tab;
        this.renderNavbarSection();
        this.renderMainContent();
      },
      isOnline: this.isOnline,
      unsyncedCount: this.unsyncedCount,
      onLogout: () => {
        this.user = null;
        localStorage.removeItem('kevs_user');
        showToast('info', 'Logged Out', 'Signed out successfully.');
        this.render();
      },
      onManualSync: async () => {
        const res = await syncOfflineData();
        await this.refreshUnsyncedCount();
        if (res.synced > 0) {
          showToast('success', 'Synced', `${res.synced} offline order(s) synced.`);
          this.renderMainContent();
        } else if (res.error) {
          showToast('error', 'Sync Failed', res.error);
        } else {
          showToast('info', 'Up to Date', 'No pending offline orders.');
        }
      },
      audioEnabled: this.audioEnabled,
      onToggleAudio: () => {
        this.audioEnabled = !this.audioEnabled;
        showToast('info', 'Audio', this.audioEnabled ? 'Sound alerts unmuted' : 'Sound alerts muted');
        this.renderNavbarSection();
      },
      queueData: this.queueData
    });
  }

  renderMainContent() {
    const mainEl = this.root.querySelector('#view-container');
    if (!mainEl) return;

    if (this.activeTab === 'queue') {
      renderQueueDashboard(mainEl, {
        socket: this.socket,
        isOnline: this.isOnline,
        onOfflineOrder: () => this.refreshUnsyncedCount(),
        addToast: showToast
      });
    } else if (this.activeTab === 'inventory') {
      renderInventoryView(mainEl, { addToast: showToast });
    } else if (this.activeTab === 'analytics') {
      renderAnalyticsView(mainEl, { addToast: showToast });
    } else if (this.activeTab === 'simulator') {
      renderHardwareSimulator(mainEl, { addToast: showToast });
    }
  }
}
