/**
 * main.js — Application Bootstrap (Vanilla JavaScript)
 * No JSX, No React — Pure DOM instantiation!
 */

import { KevsApp } from './App.js';

document.addEventListener('DOMContentLoaded', () => {
  const root = document.getElementById('root') || document.getElementById('app');
  if (root) {
    new KevsApp(root);
  }
});
