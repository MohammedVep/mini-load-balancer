(function () {
  const cfg = window.__MINILB_CONFIG || { proxyPrefix: "/proxy", aiProvider: "heuristic" };
  const proxyPrefix = cfg.proxyPrefix || "/proxy";
  const configuredAIProvider = cfg.aiProvider || "heuristic";

  const strategyLabel = document.getElementById("strategy-label");
  const backendGrid = document.getElementById("backend-grid");
  const statusMessage = document.getElementById("status-message");
  const metricsMessage = document.getElementById("metrics-message");
  const proxyLabel = document.getElementById("proxy-label");
  const costLabel = document.getElementById("cost-label");
  const refreshBtn = document.getElementById("refresh-btn");
  const strategyChips = Array.from(document.querySelectorAll("[data-strategy]"));
  const aiProviderLabel = document.getElementById("ai-provider-label");
  const aiQuestion = document.getElementById("ai-question");
  const aiAskBtn = document.getElementById("ai-ask-btn");
  const aiAnswer = document.getElementById("ai-answer");
  const aiPromptButtons = Array.from(document.querySelectorAll(".ai-prompt"));
  const metricElements = {
    requests: document.getElementById("metric-requests"),
    inflight: document.getElementById("metric-inflight"),
    retries: document.getElementById("metric-retries"),
    failovers: document.getElementById("metric-failovers"),
    upstreamErrors: document.getElementById("metric-upstream-errors"),
    circuitOpens: document.getElementById("metric-circuit-opens"),
  };
  const statusBars = document.getElementById("status-bars");
  const selectionBars = document.getElementById("selection-bars");
  const latencyTable = document.getElementById("latency-table");

  proxyLabel.textContent = proxyPrefix + "/";
  aiProviderLabel.textContent = configuredAIProvider;

  function setStatus(target, text, isError) {
    if (!target) {
      return;
    }
    target.textContent = text;
    target.style.color = isError ? "var(--danger)" : "var(--muted)";
  }

  async function fetchJSON(url, init) {
    const response = await fetch(url, init);
    if (!response.ok) {
      throw new Error("HTTP " + response.status + " " + response.statusText);
    }
    return response.json();
  }

  function markActiveChip(strategy) {
    strategyChips.forEach((chip) => {
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
      const circuitOpen = Boolean(backend.circuit_open);
      const aliveClass = backend.alive && !circuitOpen ? "alive" : "down";
      const aliveText = circuitOpen ? "CIRCUIT OPEN" : backend.alive ? "HEALTHY" : "UNHEALTHY";
      card.innerHTML = [
        "<p><strong>" + escapeHTML(shortBackendName(backend.url)) + "</strong></p>",
        "<p class='" + aliveClass + "'>" + aliveText + "</p>",
        "<p>Weight: <strong>" + Number(backend.weight || 1) + "</strong></p>",
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

      const healthy = (backendData.backends || []).filter((item) => item.alive && !item.circuit_open).length;
      const total = (backendData.backends || []).length;
      setStatus(statusMessage, "Healthy backends: " + healthy + " / " + total + " | Last refresh: " + new Date().toLocaleTimeString(), false);
      await Promise.all([refreshCost(), refreshMetricsDashboard()]);
    } catch (error) {
      setStatus(statusMessage, "Unable to fetch control-plane data: " + error.message, true);
      await Promise.all([refreshCost(), refreshMetricsDashboard()]);
    }
  }

  async function refreshCost() {
    if (!costLabel) {
      return;
    }
    try {
      const data = await fetchJSON("/admin/cost");
      const estimated = Number(data.estimated_cost_usd || 0);
      const requests = Number(data.http_requests_total || 0);
      costLabel.textContent = formatUSD(estimated) + " (" + formatNumber(requests) + " req)";
    } catch (error) {
      costLabel.textContent = String(error.message || "").includes("401") ? "auth required" : "unavailable";
    }
  }

  async function refreshMetricsDashboard() {
    try {
      const data = await fetchJSON("/admin/metrics-summary");
      renderMetricsDashboard(data);
      setStatus(metricsMessage, "Metrics refreshed at " + new Date().toLocaleTimeString(), false);
    } catch (error) {
      setStatus(metricsMessage, "Metrics unavailable: " + error.message, true);
    }
  }

  function renderMetricsDashboard(data) {
    metricElements.requests.textContent = formatNumber(data.requests_total || 0);
    metricElements.inflight.textContent = formatNumber(data.in_flight_requests || 0);
    metricElements.retries.textContent = formatNumber(data.retries_total || 0);
    metricElements.failovers.textContent = formatNumber(data.failovers_total || 0);
    metricElements.upstreamErrors.textContent = formatNumber(data.upstream_errors_total || 0);
    metricElements.circuitOpens.textContent = formatNumber(data.circuit_opens_total || 0);

    renderBars(statusBars, Object.entries(data.status_classes || {}).map(([label, count]) => ({
      label,
      value: Number(count || 0),
    })));
    renderBars(selectionBars, (data.backend_selections || []).map((item) => ({
      label: shortBackendName(item.backend) + " / " + item.strategy,
      value: Number(item.count || 0),
    })));
    renderLatencyRows(data.latencies || []);
  }

  function renderBars(container, rows) {
    if (!container) {
      return;
    }
    const max = rows.reduce((largest, item) => Math.max(largest, item.value), 0);
    if (rows.length === 0 || max === 0) {
      container.innerHTML = "<p class='small-copy'>No samples yet.</p>";
      return;
    }

    container.innerHTML = "";
    rows
      .filter((item) => item.value > 0)
      .sort((a, b) => b.value - a.value)
      .slice(0, 6)
      .forEach((item) => {
        const row = document.createElement("div");
        row.className = "bar-row";
        const width = Math.max(6, Math.round((item.value / max) * 100));
        row.innerHTML = [
          "<div class='bar-meta'><span>" + escapeHTML(item.label) + "</span><strong>" + formatNumber(item.value) + "</strong></div>",
          "<div class='bar-track'><span style='width:" + width + "%'></span></div>",
        ].join("");
        container.appendChild(row);
      });
  }

  function renderLatencyRows(latencies) {
    if (!latencyTable) {
      return;
    }
    const rows = latencies
      .slice()
      .sort((a, b) => Number(b.count || 0) - Number(a.count || 0))
      .slice(0, 6);
    if (rows.length === 0) {
      latencyTable.innerHTML = "<tr><td colspan='4'>No latency samples yet.</td></tr>";
      return;
    }
    latencyTable.innerHTML = rows.map((item) => [
      "<tr>",
      "<td><code>" + escapeHTML(item.route || "unknown") + "</code></td>",
      "<td>" + escapeHTML(item.method || "GET") + "</td>",
      "<td>" + formatNumber(item.count || 0) + "</td>",
      "<td>" + formatLatency(item.average_ms || 0) + "</td>",
      "</tr>",
    ].join("")).join("");
  }

  async function switchStrategy(strategy) {
    try {
      await fetchJSON("/admin/strategy", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: strategy }),
      });
      await refreshControlPlane();
      setStatus(statusMessage, "Routing strategy switched to " + strategy, false);
    } catch (error) {
      setStatus(statusMessage, "Strategy switch failed: " + error.message, true);
    }
  }

  async function refreshAIStatus() {
    try {
      const data = await fetchJSON("/ai/status");
      aiProviderLabel.textContent = String(data.provider || configuredAIProvider);
    } catch (error) {
      aiProviderLabel.textContent = configuredAIProvider + " (status unavailable)";
    }
  }

  async function askAI(question) {
    const trimmed = String(question || "").trim();
    if (!trimmed) {
      aiAnswer.textContent = "Enter a question first.";
      return;
    }
    aiAnswer.textContent = "Thinking...";
    try {
      const data = await fetchJSON("/ai/analyze", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ question: trimmed }),
      });
      const provider = data.provider || "heuristic";
      const suffix = data.used_fallback ? "\n\n(OpenAI unavailable, heuristic fallback used.)" : "";
      aiAnswer.textContent = "[" + provider + "]\n" + String(data.answer || "No response.") + suffix;
      aiProviderLabel.textContent = provider;
    } catch (error) {
      aiAnswer.textContent = "AI request failed: " + error.message;
    }
  }

  strategyChips.forEach((chip) => {
    chip.addEventListener("click", function () {
      const strategy = chip.getAttribute("data-strategy");
      if (strategy) {
        switchStrategy(strategy);
      }
    });
  });

  refreshBtn.addEventListener("click", refreshControlPlane);
  aiAskBtn.addEventListener("click", function () {
    askAI(aiQuestion.value);
  });
  aiQuestion.addEventListener("keydown", function (event) {
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
      askAI(aiQuestion.value);
    }
  });
  aiPromptButtons.forEach((btn) => {
    btn.addEventListener("click", function () {
      const prompt = btn.getAttribute("data-prompt") || "";
      aiQuestion.value = prompt;
      askAI(prompt);
    });
  });

  refreshControlPlane();
  refreshAIStatus();
  window.setInterval(refreshControlPlane, 7000);

  function escapeHTML(input) {
    return String(input)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function shortBackendName(value) {
    try {
      const parsed = new URL(String(value));
      return parsed.hostname || String(value);
    } catch (error) {
      return String(value || "backend");
    }
  }

  function formatUSD(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) {
      return "$0.00";
    }
    if (Math.abs(number) >= 1) {
      return "$" + number.toFixed(2);
    }
    return "$" + number.toFixed(6);
  }

  function formatNumber(value) {
    return Number(value || 0).toLocaleString();
  }

  function formatLatency(value) {
    const number = Number(value || 0);
    if (number >= 1000) {
      return (number / 1000).toFixed(2) + "s";
    }
    return number.toFixed(number >= 10 ? 1 : 2) + "ms";
  }
})();
