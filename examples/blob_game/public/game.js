// Gobble's client: one WebSocket. It sends where the pointer is and draws the views the server pushes; the
// server owns the game, and this only smooths the motion between views.
"use strict";

const canvas = document.getElementById("arena");
const context = canvas.getContext("2d");
const startForm = document.getElementById("start");
const message = document.getElementById("message");
const board = document.getElementById("board");
const topList = document.getElementById("top");
const massLabel = document.getElementById("mass");

const SEND_INTERVAL = 50;           // ms between pointer updates
const START_RADIUS = 6 * Math.sqrt(10);

let socket = null;                  // open while playing
let latest = null;                  // the last view the server sent
let pointer = { x: 0, y: 0 };       // screen offset from the centre
let lastSent = "";
const shown = new Map();            // blob id -> {x, y, r} as drawn, easing toward the server's
const camera = { x: 1500, y: 1500, scale: 1 };

function resize() {
  const ratio = window.devicePixelRatio || 1;
  canvas.width = innerWidth * ratio;
  canvas.height = innerHeight * ratio;
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
}
addEventListener("resize", resize);
resize();

canvas.addEventListener("pointermove", (event) => {
  pointer = { x: event.clientX - innerWidth / 2, y: event.clientY - innerHeight / 2 };
});
canvas.addEventListener("pointerdown", (event) => {
  pointer = { x: event.clientX - innerWidth / 2, y: event.clientY - innerHeight / 2 };
});

function join(name) {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  socket = new WebSocket(`${scheme}//${location.host}/api/play?name=${encodeURIComponent(name)}`);
  latest = null;
  shown.clear();
  socket.addEventListener("open", () => {
    startForm.hidden = true;
    board.hidden = massLabel.hidden = false;
  });
  socket.addEventListener("message", (event) => {
    latest = JSON.parse(event.data);
    updatePanels();
    if (!latest.you.alive && startForm.hidden) {
      message.textContent = `Eaten by ${latest.you.eaten_by}. Again?`;
      startForm.hidden = false;
    }
  });
  socket.addEventListener("close", () => {
    socket = null;
    message.textContent = "Disconnected from the arena. Again?";
    startForm.hidden = false;
  });
}

startForm.addEventListener("submit", (event) => {
  event.preventDefault();
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send("respawn");         // still connected: back in with the same name
    startForm.hidden = true;
  } else {
    join(document.getElementById("name").value.trim() || "Blob");
  }
});

// Where the pointer is, in world units, whenever it has changed.
setInterval(() => {
  if (!socket || socket.readyState !== WebSocket.OPEN || !latest || !latest.you.alive) return;
  const target = `${Math.round(latest.you.x + pointer.x / camera.scale)} ` +
                 `${Math.round(latest.you.y + pointer.y / camera.scale)}`;
  if (target !== lastSent) {
    socket.send(target);
    lastSent = target;
  }
}, SEND_INTERVAL);

function updatePanels() {
  topList.replaceChildren(...latest.top.map(([name, mass, isMe]) => {
    const item = document.createElement("li");
    item.textContent = `${name} · ${mass}`;
    if (isMe) item.className = "me";
    return item;
  }));
  massLabel.textContent = `Mass ${latest.you.mass}`;
}

// Hue to a fill and a darker outline.
const fill = (hue) => `hsl(${hue} 70% 55%)`;
const outline = (hue) => `hsl(${hue} 65% 38%)`;

function ease(current, target, rate, seconds) {
  return current + (target - current) * (1 - Math.exp(-rate * seconds));
}

let lastTime = performance.now();
function draw(now) {
  const seconds = Math.min(0.1, (now - lastTime) / 1000);
  lastTime = now;
  const width = innerWidth, height = innerHeight;

  if (latest) {
    const you = latest.you;
    // A radius-r blob sees 800 * (r / r0)^0.35 world units top to bottom; the server sends a wider square
    // (Arena.View_Half), so wide screens are covered too.
    const viewHeight = 800 * Math.pow(Math.max(you.r, START_RADIUS) / START_RADIUS, 0.35);
    camera.scale = ease(camera.scale, height / viewHeight, 4, seconds);
    camera.x = ease(camera.x, you.x, 12, seconds);
    camera.y = ease(camera.y, you.y, 12, seconds);
  }

  context.fillStyle = "#f3f4f6";
  context.fillRect(0, 0, width, height);
  context.save();
  context.translate(width / 2, height / 2);
  context.scale(camera.scale, camera.scale);
  context.translate(-camera.x, -camera.y);

  drawGrid(latest ? latest.size : 3000, width, height);
  if (latest) {
    for (const [x, y, hue] of latest.pellets) {
      context.fillStyle = fill(hue);
      context.beginPath();
      context.arc(x, y, 5, 0, Math.PI * 2);
      context.fill();
    }

    const present = new Set();
    const blobs = latest.blobs.map(([id, x, y, r, hue, name]) => {
      present.add(id);
      const blob = shown.get(id) || { x, y, r };
      blob.x = ease(blob.x, x, 14, seconds);
      blob.y = ease(blob.y, y, 14, seconds);
      blob.r = ease(blob.r, r, 8, seconds);
      shown.set(id, blob);
      return { ...blob, hue, name, id };
    });
    for (const id of shown.keys()) if (!present.has(id)) shown.delete(id);

    blobs.sort((a, b) => a.r - b.r);   // small ones underneath
    for (const blob of blobs) drawBlob(blob, blob.id === latest.you.id);
  }
  context.restore();
  requestAnimationFrame(draw);
}

function drawGrid(size, width, height) {
  const left = camera.x - width / 2 / camera.scale, right = camera.x + width / 2 / camera.scale;
  const top = camera.y - height / 2 / camera.scale, bottom = camera.y + height / 2 / camera.scale;
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, size, size);
  context.strokeStyle = "#e5e7eb";
  context.lineWidth = 1 / camera.scale;
  context.beginPath();
  for (let x = Math.max(0, Math.floor(left / 50) * 50); x <= Math.min(size, right); x += 50) {
    context.moveTo(x, Math.max(0, top));
    context.lineTo(x, Math.min(size, bottom));
  }
  for (let y = Math.max(0, Math.floor(top / 50) * 50); y <= Math.min(size, bottom); y += 50) {
    context.moveTo(Math.max(0, left), y);
    context.lineTo(Math.min(size, right), y);
  }
  context.stroke();
  context.strokeStyle = "#9ca3af";
  context.lineWidth = 4 / camera.scale;
  context.strokeRect(0, 0, size, size);
}

function drawBlob(blob, isMe) {
  context.fillStyle = fill(blob.hue);
  context.strokeStyle = isMe ? "#111827" : outline(blob.hue);
  context.lineWidth = Math.max(2, blob.r * 0.08);
  context.beginPath();
  context.arc(blob.x, blob.y, blob.r, 0, Math.PI * 2);
  context.fill();
  context.stroke();
  if (blob.r > 14 && blob.name) {
    const size = Math.max(10, blob.r * 0.4);
    context.font = `600 ${size}px system-ui, sans-serif`;
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.lineWidth = size * 0.18;
    context.strokeStyle = "rgba(0, 0, 0, 0.55)";
    context.strokeText(blob.name, blob.x, blob.y);
    context.fillStyle = "#ffffff";
    context.fillText(blob.name, blob.x, blob.y);
  }
}

requestAnimationFrame(draw);
