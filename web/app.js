(function () {
  const cfg = window.__MINILB_CONFIG || { proxyPrefix: "/proxy" };
  const proxyPrefix = cfg.proxyPrefix || "/proxy";
  const strategyLabel = document.getElementById("strategy-label");
  const backendGrid = document.getElementById("backend-grid");
  const statusMessage = document.getElementById("status-message");
  const proxyLabel = document.getElementById("proxy-label");
  const refreshBtn = document.getElementById("refresh-btn");
  const chips = Array.from(document.querySelectorAll(".chip"));
  const hashBtn = document.getElementById("hash-btn");
  const hashInput = document.getElementById("client-key");
  const hashResult = document.getElementById("hash-result");

  proxyLabel.textContent = proxyPrefix + "/";

  function setStatus(text, isError) {
    statusMessage.textContent = text;
    statusMessage.style.color = isError ? "var(--danger)" : "var(--muted)";
  }

  async function fetchJSON(url, init) {
    const response = await fetch(url, init);
    if (!response.ok) {
      throw new Error("HTTP " + response.status + " " + response.statusText);
    }
    return response.json();
  }

  function markActiveChip(strategy) {
    chips.forEach((chip) => {
      const active = chip.getAttribute("data-strategy") === strategy;
      chip.classList.toggle("active", active);
    });
  }

  function renderBackends(backends) {
    if (!Array.isArray(backends) || backends.length === 0) {
      backendGrid.innerHTML = "<p class='small-copy'>No backends configured.</p>";
      return;
    }

    backendGrid.innerHTML = "";
    backends.forEach((backend) => {
      const card = document.createElement("article");
      card.className = "backend-card";
      const aliveClass = backend.alive ? "alive" : "down";
      const aliveText = backend.alive ? "HEALTHY" : "UNHEALTHY";
      card.innerHTML = [
        "<p><strong>" + escapeHTML(backend.url) + "</strong></p>",
        "<p class='" + aliveClass + "'>" + aliveText + "</p>",
        "<p>Active connections: <strong>" + Number(backend.active_connections || 0) + "</strong></p>",
      ].join("");
      backendGrid.appendChild(card);
    });
  }

  async function refreshControlPlane() {
    try {
      const [strategyData, backendData] = await Promise.all([
        fetchJSON("/admin/strategy"),
        fetchJSON("/admin/backends"),
      ]);
      const strategy = String(strategyData.strategy || backendData.strategy || "unknown");
      strategyLabel.textContent = strategy;
      markActiveChip(strategy);
      renderBackends(backendData.backends);

      const healthy = (backendData.backends || []).filter((item) => item.alive).length;
      const total = (backendData.backends || []).length;
      setStatus("Healthy backends: " + healthy + " / " + total + " | Last refresh: " + new Date().toLocaleTimeString(), false);
    } catch (error) {
      setStatus("Unable to fetch control-plane data: " + error.message, true);
    }
  }

  async function switchStrategy(strategy) {
    try {
      await fetchJSON("/admin/strategy", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: strategy }),
      });
      await refreshControlPlane();
      setStatus("Routing strategy switched to " + strategy, false);
    } catch (error) {
      setStatus("Strategy switch failed: " + error.message, true);
    }
  }

  function runHashLab() {
    const key = (hashInput.value || "").trim();
    if (!key) {
      hashResult.textContent = "Enter a client key first.";
      return;
    }

    const backendCards = Array.from(document.querySelectorAll(".backend-card strong"));
    const candidates = backendCards.map((node) => node.textContent).filter(Boolean);
    if (candidates.length === 0) {
      hashResult.textContent = "No backends available from control-plane data.";
      return;
    }

    const hash = crc32(key);
    const selected = candidates[hash % candidates.length];
    hashResult.textContent = "Key '" + key + "' maps to " + selected + " (hash=" + hash + ").";
  }

  chips.forEach((chip) => {
    chip.addEventListener("click", function () {
      const strategy = chip.getAttribute("data-strategy");
      if (strategy) {
        switchStrategy(strategy);
      }
    });
  });

  refreshBtn.addEventListener("click", refreshControlPlane);
  hashBtn.addEventListener("click", runHashLab);
  hashInput.addEventListener("keydown", function (event) {
    if (event.key === "Enter") {
      runHashLab();
    }
  });

  refreshControlPlane();
  window.setInterval(refreshControlPlane, 7000);

  function escapeHTML(input) {
    return String(input)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  const crcTable = buildCRCTable();
  function crc32(str) {
    let crc = -1;
    for (let i = 0; i < str.length; i++) {
      crc = (crc >>> 8) ^ crcTable[(crc ^ str.charCodeAt(i)) & 0xff];
    }
    return (crc ^ -1) >>> 0;
  }

  function buildCRCTable() {
    const table = [];
    for (let i = 0; i < 256; i++) {
      let c = i;
      for (let j = 0; j < 8; j++) {
        if ((c & 1) !== 0) {
          c = 0xedb88320 ^ (c >>> 1);
        } else {
          c = c >>> 1;
        }
      }
      table[i] = c >>> 0;
    }
    return table;
  }
})();
