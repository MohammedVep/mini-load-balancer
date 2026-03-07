(function () {
  const cfg = window.__MINILB_CONFIG || { proxyPrefix: "/proxy", aiProvider: "heuristic" };
  const proxyPrefix = cfg.proxyPrefix || "/proxy";
  const configuredAIProvider = cfg.aiProvider || "heuristic";
  const strategyLabel = document.getElementById("strategy-label");
  const backendGrid = document.getElementById("backend-grid");
  const statusMessage = document.getElementById("status-message");
  const proxyLabel = document.getElementById("proxy-label");
  const costLabel = document.getElementById("cost-label");
  const refreshBtn = document.getElementById("refresh-btn");
  const chips = Array.from(document.querySelectorAll(".chip"));
  const aiProviderLabel = document.getElementById("ai-provider-label");
  const aiQuestion = document.getElementById("ai-question");
  const aiAskBtn = document.getElementById("ai-ask-btn");
  const aiAnswer = document.getElementById("ai-answer");
  const aiPromptButtons = Array.from(document.querySelectorAll(".ai-prompt"));

  proxyLabel.textContent = proxyPrefix + "/";
  aiProviderLabel.textContent = configuredAIProvider;

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

      const healthy = (backendData.backends || []).filter((item) => item.alive).length;
      const total = (backendData.backends || []).length;
      setStatus("Healthy backends: " + healthy + " / " + total + " | Last refresh: " + new Date().toLocaleTimeString(), false);
      await refreshCost();
    } catch (error) {
      setStatus("Unable to fetch control-plane data: " + error.message, true);
      await refreshCost();
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
      costLabel.textContent = formatUSD(estimated) + " (" + requests + " req)";
    } catch (error) {
      if (String(error.message || "").includes("401")) {
        costLabel.textContent = "auth required";
        return;
      }
      costLabel.textContent = "unavailable";
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

  chips.forEach((chip) => {
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

  function formatUSD(value) {
    if (!Number.isFinite(value)) {
      return "$0.00";
    }
    if (Math.abs(value) >= 1) {
      return "$" + value.toFixed(2);
    }
    return "$" + value.toFixed(6);
  }
})();
