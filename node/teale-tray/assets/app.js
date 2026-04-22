const STATUS_COLORS = {
  serving: "#2db767",
  downloading: "#c97f12",
  loading: "#c97f12",
  paused_user: "#6e6e6e",
  paused_battery: "#d93c35",
  needs_model: "#d93c35",
  starting: "#6e6e6e",
  error: "#d93c35",
};

const els = {
  statusChip: document.getElementById("status-chip"),
  statusReason: document.getElementById("status-reason"),
  deviceName: document.getElementById("device-name"),
  deviceRam: document.getElementById("device-ram"),
  deviceBackend: document.getElementById("device-backend"),
  devicePower: document.getElementById("device-power"),
  currentModel: document.getElementById("current-model"),
  unloadButton: document.getElementById("unload-button"),
  recommendedPanel: document.getElementById("recommended-panel"),
  recommendedName: document.getElementById("recommended-name"),
  recommendedMeta: document.getElementById("recommended-meta"),
  recommendedAction: document.getElementById("recommended-action"),
  transferPanel: document.getElementById("transfer-panel"),
  transferLabel: document.getElementById("transfer-label"),
  transferPercent: document.getElementById("transfer-percent"),
  transferBar: document.getElementById("transfer-bar"),
  modelsList: document.getElementById("models-list"),
};

let currentSnapshot = null;

function labelForState(state) {
  switch (state) {
    case "serving":
      return "Serving";
    case "downloading":
      return "Downloading";
    case "loading":
      return "Loading";
    case "paused_user":
      return "Paused";
    case "paused_battery":
      return "Waiting for AC";
    case "needs_model":
      return "Choose a Model";
    case "starting":
      return "Starting";
    default:
      return "Not Ready";
  }
}

async function post(path, body = null) {
  const init = {
    method: "POST",
    headers: { "Content-Type": "application/json" },
  };
  if (body) {
    init.body = JSON.stringify(body);
  }
  const res = await fetch(`http://127.0.0.1:11437${path}`, init);
  if (!res.ok) {
    const payload = await res.json().catch(() => ({}));
    throw new Error(payload.error || `Request failed: ${res.status}`);
  }
  return res.json();
}

function render(snapshot) {
  currentSnapshot = snapshot;
  const { device, loaded_model_id, active_transfer, models } = snapshot;

  els.statusChip.textContent = labelForState(snapshot.service_state);
  els.statusChip.style.background = `${STATUS_COLORS[snapshot.service_state] || "#6e6e6e"}22`;
  els.statusChip.style.color = STATUS_COLORS[snapshot.service_state] || "#1d2a26";
  els.statusReason.textContent = snapshot.state_reason || "Teale is ready locally.";

  els.deviceName.textContent = device.display_name;
  els.deviceRam.textContent = `${Math.round(device.hardware.totalRAMGB)} GB`;
  els.deviceBackend.textContent = device.gpu_backend || device.hardware.gpuBackend || "-";
  els.devicePower.textContent = device.on_ac ? "Plugged In" : "Battery";

  els.currentModel.textContent = loaded_model_id || "No model loaded";
  els.unloadButton.disabled = !loaded_model_id;

  const recommended = models.find((model) => model.recommended) || models[0];
  if (recommended) {
    els.recommendedName.textContent = recommended.display_name;
    els.recommendedMeta.textContent = `${Math.round(recommended.required_ram_gb)} GB RAM minimum • ${recommended.size_gb.toFixed(1)} GB download`;
    els.recommendedAction.disabled = Boolean(active_transfer);
    els.recommendedAction.textContent = recommended.downloaded
      ? recommended.loaded
        ? "Already Loaded"
        : "Load and Start Supplying"
      : "Download and Start Supplying";
    els.recommendedAction.onclick = async () => {
      try {
        if (recommended.downloaded) {
          await post("/v1/app/models/load", { model: recommended.id });
        } else {
          await post("/v1/app/models/download", { model: recommended.id });
        }
        await refresh();
      } catch (error) {
        alert(error.message);
      }
    };
  }

  if (active_transfer) {
    els.transferPanel.hidden = false;
    const percent = active_transfer.bytes_total
      ? Math.round((active_transfer.bytes_downloaded / active_transfer.bytes_total) * 100)
      : 0;
    els.transferPercent.textContent = `${percent}%`;
    els.transferLabel.textContent = `${active_transfer.model_id} • ${active_transfer.phase}`;
    els.transferBar.style.width = `${percent}%`;
  } else {
    els.transferPanel.hidden = true;
  }

  els.modelsList.innerHTML = "";
  for (const model of models) {
    const card = document.createElement("article");
    card.className = `model-card${model.loaded ? " is-loaded" : ""}`;

    const left = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = model.display_name;
    const meta = document.createElement("p");
    meta.className = "muted";
    meta.textContent = `Demand rank #${model.demand_rank} • ${Math.round(model.required_ram_gb)} GB RAM • ${model.size_gb.toFixed(1)} GB`;
    const pills = document.createElement("div");
    pills.className = "pill-row";
    [
      model.recommended ? "Recommended" : null,
      model.downloaded ? "Downloaded" : "Not downloaded",
      model.loaded ? "Loaded" : null,
      model.last_error ? `Error: ${model.last_error}` : null,
    ]
      .filter(Boolean)
      .forEach((text) => {
        const pill = document.createElement("span");
        pill.className = "pill";
        pill.textContent = text;
        pills.appendChild(pill);
      });
    left.append(title, meta, pills);

    const button = document.createElement("button");
    button.className = "button";
    button.disabled = Boolean(active_transfer);
    if (model.loaded) {
      button.textContent = "Loaded";
      button.disabled = true;
    } else if (model.download_progress != null) {
      button.textContent = `Downloading ${Math.round(model.download_progress * 100)}%`;
      button.disabled = true;
    } else if (model.downloaded) {
      button.textContent = "Load";
      button.onclick = async () => {
        try {
          await post("/v1/app/models/load", { model: model.id });
          await refresh();
        } catch (error) {
          alert(error.message);
        }
      };
    } else {
      button.textContent = "Download";
      button.onclick = async () => {
        try {
          await post("/v1/app/models/download", { model: model.id });
          await refresh();
        } catch (error) {
          alert(error.message);
        }
      };
    }

    card.append(left, button);
    els.modelsList.appendChild(card);
  }
}

async function refresh() {
  const res = await fetch("http://127.0.0.1:11437/v1/app");
  if (!res.ok) {
    throw new Error(`Teale status failed: ${res.status}`);
  }
  const snapshot = await res.json();
  render(snapshot);
}

els.unloadButton.addEventListener("click", async () => {
  try {
    await post("/v1/app/models/unload");
    await refresh();
  } catch (error) {
    alert(error.message);
  }
});

let intervalHandle = null;

function startPolling() {
  if (intervalHandle) {
    clearInterval(intervalHandle);
  }
  const everyMs = document.hidden ? 5000 : 1000;
  intervalHandle = setInterval(() => {
    refresh().catch((error) => {
      els.statusReason.textContent = error.message;
    });
  }, everyMs);
}

document.addEventListener("visibilitychange", startPolling);

refresh()
  .then(startPolling)
  .catch((error) => {
    els.statusReason.textContent = error.message;
    startPolling();
  });
