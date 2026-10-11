/**
 * LightRecorder Landing Page - Lightweight vanilla interactive scripts
 */

document.addEventListener('DOMContentLoaded', () => {
  initTheme();
  initCopyButtons();
  initSimulator();
  initModeTabs();
});

/* ==========================================================================
   1. Theme Toggle Management
   ========================================================================== */
function initTheme() {
  const themeToggleBtn = document.getElementById('theme-toggle-btn');
  const sunIcon = document.getElementById('sun-icon');
  const moonIcon = document.getElementById('moon-icon');

  function getPreferredTheme() {
    const saved = localStorage.getItem('theme');
    if (saved) return saved;
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  function applyTheme(theme) {
    if (theme === 'dark') {
      document.documentElement.setAttribute('data-theme', 'dark');
      if (sunIcon && moonIcon) {
        sunIcon.style.display = 'block';
        moonIcon.style.display = 'none';
      }
    } else {
      document.documentElement.setAttribute('data-theme', 'light');
      if (sunIcon && moonIcon) {
        sunIcon.style.display = 'none';
        moonIcon.style.display = 'block';
      }
    }
    localStorage.setItem('theme', theme);
  }

  // Initial setup
  const currentTheme = getPreferredTheme();
  applyTheme(currentTheme);

  // Toggle button click
  if (themeToggleBtn) {
    themeToggleBtn.addEventListener('click', () => {
      const active = document.documentElement.getAttribute('data-theme') || currentTheme;
      applyTheme(active === 'dark' ? 'light' : 'dark');
    });
  }

  // Listen to system changes
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
    if (!localStorage.getItem('theme')) {
      applyTheme(e.matches ? 'dark' : 'light');
    }
  });
}

/* ==========================================================================
   2. Copy to Clipboard with Toast Feedback
   ========================================================================== */
function initCopyButtons() {
  const copyButtons = document.querySelectorAll('[data-copy]');
  const toast = document.getElementById('toast');
  const toastText = document.getElementById('toast-text');
  let toastTimer = null;

  function showToast(message) {
    if (!toast) return;
    if (toastText) toastText.textContent = message || 'Copied to clipboard!';
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      toast.classList.remove('show');
    }, 2500);
  }

  copyButtons.forEach((btn) => {
    btn.addEventListener('click', async (e) => {
      e.preventDefault();
      const textToCopy = btn.getAttribute('data-copy');
      if (!textToCopy) return;

      try {
        await navigator.clipboard.writeText(textToCopy);
        showToast(`Copied "${textToCopy}"`);
      } catch (err) {
        // Fallback
        const textarea = document.createElement('textarea');
        textarea.value = textToCopy;
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
        showToast(`Copied to clipboard!`);
      }
    });
  });
}

/* ==========================================================================
   3. Interactive macOS Menu Bar & HUD Simulator
   ========================================================================== */
function initSimulator() {
  const simRecordBtn = document.getElementById('sim-record-btn');
  const simStatusTimer = document.getElementById('sim-status-timer');
  const simHudTimer = document.getElementById('sim-hud-timer');
  const simDot = document.getElementById('sim-rec-dot');
  const simSelectionBox = document.getElementById('sim-selection-box');
  const simModeButtons = document.querySelectorAll('.hud-mode-btn');
  const simSwitches = document.querySelectorAll('.hud-switch');

  let isRecording = false;
  let timerInterval = null;
  let elapsedSeconds = 0;

  function formatTime(totalSeconds) {
    const mins = Math.floor(totalSeconds / 60).toString().padStart(2, '0');
    const secs = (totalSeconds % 60).toString().padStart(2, '0');
    return `00:${mins}:${secs}`;
  }

  function startRecording() {
    isRecording = true;
    elapsedSeconds = 0;
    if (simRecordBtn) {
      simRecordBtn.classList.add('recording');
      simRecordBtn.innerHTML = `
        <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
          <rect x="5" y="5" width="14" height="14" rx="2" />
        </svg>
        Stop Recording
      `;
    }
    if (simDot) simDot.classList.add('pulsing');
    if (simStatusTimer) simStatusTimer.textContent = '00:00:00';
    if (simHudTimer) simHudTimer.textContent = '00:00:00';

    timerInterval = setInterval(() => {
      elapsedSeconds++;
      const timeStr = formatTime(elapsedSeconds);
      if (simStatusTimer) simStatusTimer.textContent = timeStr;
      if (simHudTimer) simHudTimer.textContent = timeStr;
    }, 1000);
  }

  function stopRecording() {
    isRecording = false;
    clearInterval(timerInterval);
    if (simRecordBtn) {
      simRecordBtn.classList.remove('recording');
      simRecordBtn.innerHTML = `
        <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
          <circle cx="12" cy="12" r="8" />
        </svg>
        Start Recording
      `;
    }
    if (simDot) simDot.classList.remove('pulsing');
    if (simStatusTimer) simStatusTimer.textContent = 'Ready';
    if (simHudTimer) simHudTimer.textContent = '00:00:00';
  }

  if (simRecordBtn) {
    simRecordBtn.addEventListener('click', () => {
      if (isRecording) {
        stopRecording();
      } else {
        startRecording();
      }
    });
  }

  // Switches interactivity
  simSwitches.forEach((sw) => {
    sw.addEventListener('click', () => {
      sw.classList.toggle('on');
    });
  });

  // Mode selection tabs in HUD
  simModeButtons.forEach((btn) => {
    btn.addEventListener('click', () => {
      simModeButtons.forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');

      const mode = btn.getAttribute('data-sim-mode');
      if (simSelectionBox) {
        if (mode === 'area') {
          simSelectionBox.classList.add('visible');
        } else {
          simSelectionBox.classList.remove('visible');
        }
      }
    });
  });
}

/* ==========================================================================
   4. Capture Modes Showcase Tabs
   ========================================================================== */
function initModeTabs() {
  const tabButtons = document.querySelectorAll('.modes-tab-btn');
  const panels = document.querySelectorAll('.mode-content-panel');

  tabButtons.forEach((btn) => {
    btn.addEventListener('click', () => {
      const targetMode = btn.getAttribute('data-mode-tab');
      if (!targetMode) return;

      tabButtons.forEach((b) => b.classList.remove('active'));
      panels.forEach((p) => p.classList.remove('active'));

      btn.classList.add('active');
      const activePanel = document.getElementById(`panel-${targetMode}`);
      if (activePanel) {
        activePanel.classList.add('active');
      }
    });
  });
}
