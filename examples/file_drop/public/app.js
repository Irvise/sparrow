// File drop: uploads with progress, the list kept current by an event stream. No libraries.
"use strict";

const zone = document.getElementById("zone");
const picker = document.getElementById("picker");
const progressList = document.getElementById("progress");
const fileList = document.getElementById("files");
let mode = "local";

// Writes carry X-Requested-With: a cross-site form cannot send it, which is the server's CSRF check.
const writeHeaders = { "X-Requested-With": "fetch" };

function size(bytes) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  while (bytes >= 1024 && index < units.length - 1) { bytes /= 1024; index++; }
  return `${bytes.toFixed(index ? 1 : 0)} ${units[index]}`;
}

async function refresh() {
  const answer = await fetch("/api/files");
  const list = await answer.json();
  mode = list.mode;
  document.getElementById("mode").textContent = mode === "s3"
    ? "Files go straight from your browser to the S3 bucket."
    : "Files stream to the server's disk as they arrive.";
  fileList.replaceChildren(...list.files.map(file => {
    const item = document.createElement("li");
    const link = document.createElement("a");
    link.href = `/files/${encodeURIComponent(file.name)}`;
    link.textContent = file.name;
    const bytes = document.createElement("span");
    bytes.className = "size";
    bytes.textContent = size(file.size);
    const remove = document.createElement("button");
    remove.title = "Delete";
    remove.textContent = "✕";
    remove.onclick = () => fetch(`/api/files/${encodeURIComponent(file.name)}`, { method: "DELETE", headers: writeHeaders });
    item.append(link, bytes, remove);
    return item;
  }));
}

// XMLHttpRequest rather than fetch: it reports upload progress.
function send(method, url, body, headers, bar) {
  return new Promise((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open(method, url);
    for (const [name, value] of Object.entries(headers)) request.setRequestHeader(name, value);
    request.upload.onprogress = event => { if (event.lengthComputable) bar.value = event.loaded / event.total; };
    request.onload = () => (request.status < 300 ? resolve(request) : reject(new Error(request.responseText)));
    request.onerror = () => reject(new Error("the connection failed"));
    request.send(body);
  });
}

async function upload(file) {
  const item = document.createElement("li");
  const bar = document.createElement("progress");
  item.append(file.name, bar);
  progressList.append(item);
  try {
    if (mode === "s3") {
      const type = file.type || "application/octet-stream";
      const answer = await fetch("/api/uploads", {
        method: "POST", headers: { ...writeHeaders, "Content-Type": "application/json" },
        body: JSON.stringify({ name: file.name, type, size: file.size }) });
      if (!answer.ok) throw new Error((await answer.json()).error);
      const target = await answer.json();
      await send("PUT", target.url, file, { "Content-Type": type }, bar);
      await fetch(`/api/uploads/${encodeURIComponent(target.name)}/done`, { method: "POST", headers: writeHeaders });
    } else {
      const form = new FormData();
      form.append("file", file);
      await send("POST", "/api/files", form, writeHeaders, bar);
    }
    item.remove();
  } catch (problem) {
    item.textContent = `${file.name}: ${problem.message}`;
  }
}

function uploadAll(files) { for (const file of files) upload(file); }

picker.onchange = () => { uploadAll(picker.files); picker.value = ""; };
zone.ondragover = event => { event.preventDefault(); zone.classList.add("over"); };
zone.ondragleave = () => zone.classList.remove("over");
zone.ondrop = event => { event.preventDefault(); zone.classList.remove("over"); uploadAll(event.dataTransfer.files); };

// Every page hears of every change, its own included.
new EventSource("/api/events").addEventListener("changed", refresh);
refresh();
