// ==UserScript==
// @name         WhatsApp — readable chat export
// @namespace    local.whatsapp.export
// @version      2026.11.07.7
// @description  Export currently loaded messages and available image previews as a readable, self-contained HTML file.
// @match        https://web.whatsapp.com/*
// @run-at       document-idle
// @grant        none
// @noframes
// ==/UserScript==

(function () {
  'use strict';

  const BUTTON_ID = 'wa-readable-export-button';
  if (document.getElementById(BUTTON_ID)) return;

  const escape = value => String(value ?? '').replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[character]);
  const textOf = element => (element?.innerText || element?.textContent || '').trim();
  const valueOf = element => (element?.getAttribute('title') || textOf(element)).trim();
  // Keep outermost matches so nested selectable-text elements are not duplicated.
  const outermost = elements => elements.filter(element =>
    !elements.some(other => other !== element && other.contains(element)));
  const pad = value => String(value).padStart(2, '0');
  const fileTimestamp = date => `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}_${pad(date.getHours())}-${pad(date.getMinutes())}-${pad(date.getSeconds())}`;
  const safeFilename = value => value.replace(/[<>:"/\\|?*\u0000-\u001f\u007f]/g, '_')
    .replace(/\s+/g, ' ').trim().slice(0, 90).replace(/[. ]+$/g, '') || 'Conversation';

  function readMetadata(label) {
    // Keep WhatsApp's local date format; do not guess whether 07/11 means July or November.
    const clean = label.replace(/[\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '').trim();
    const match = clean.match(/^\[([^\]]+)\]\s*(.*)$/);
    return {
      timestamp: match?.[1] || '',
      sender: match ? match[2].replace(/:\s*$/, '').trim() : '',
    };
  }

  function detectDirection(row, root) {
    // Check the row AND its wrappers: WhatsApp can put direction on an ancestor.
    const wrappers = [];
    for (let element = row; element && element !== root; element = element.parentElement) {
      wrappers.push(element);
    }
    const classNodes = [...wrappers, ...row.querySelectorAll('.message-in, .message-out')];
    for (const element of classNodes) {
      if (element.matches('.message-out')) return 'outgoing';
      if (element.matches('.message-in')) return 'incoming';
    }
    // Some layouts use a serialized message key instead of direction classes.
    // Treat this as a fallback; unknown formats remain unknown.
    const idNodes = [...wrappers, ...row.querySelectorAll('[data-id]')];
    for (const element of idNodes) {
      const id = element.getAttribute('data-id') || '';
      if (/^true_[^_]+_.+/.test(id)) return 'outgoing';
      if (/^false_[^_]+_.+/.test(id)) return 'incoming';
    }
    return 'unknown';
  }

  function dateParts(timestamp) {
    const match = timestamp.match(/\b(\d{1,4})[./-](\d{1,2})[./-](\d{1,4})\b/);
    return match ? { a: Number(match[1]), b: Number(match[2]), c: Number(match[3]), iso: match[1].length === 4 } : null;
  }

  function inferDateOrder(messages) {
    const orders = new Set();
    for (const message of messages) {
      const parts = dateParts(message.timestamp);
      if (!parts || parts.iso) continue;
      if (parts.a > 12 && parts.a <= 31 && parts.b >= 1 && parts.b <= 12) orders.add('dmy');
      if (parts.b > 12 && parts.b <= 31 && parts.a >= 1 && parts.a <= 12) orders.add('mdy');
    }
    return orders.size === 1 ? [...orders][0] : '';
  }

  function automaticDateOrder(messages, now) {
    const explicit = inferDateOrder(messages);
    if (explicit) return explicit;
    const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
    function score(order) {
      const dates = messages.map(message => messageDate(message.timestamp, order)).filter(Boolean);
      const future = dates.filter(date => date >= tomorrow).length;
      let backwards = 0;
      for (let i = 1; i < dates.length; i++) if (dates[i] < dates[i - 1]) backwards++;
      const latest = dates.length ? Math.max(...dates.map(Number)) : NaN;
      return { valid: dates.length, future, backwards, age: (now - latest) / 86400000 };
    }
    const dayFirst = score('dmy');
    const monthFirst = score('mdy');
    if (dayFirst.valid !== monthFirst.valid) return dayFirst.valid > monthFirst.valid ? 'dmy' : 'mdy';
    if (dayFirst.future !== monthFirst.future) return dayFirst.future < monthFirst.future ? 'dmy' : 'mdy';
    if (dayFirst.backwards !== monthFirst.backwards) return dayFirst.backwards < monthFirst.backwards ? 'dmy' : 'mdy';
    // A recent, plausible interpretation helps when both numeric formats are valid.
    // Otherwise use the page's language, then the browser's locale.
    if (dayFirst.age >= 0 && dayFirst.age <= 7 && monthFirst.age > 31) return 'dmy';
    if (monthFirst.age >= 0 && monthFirst.age <= 7 && dayFirst.age > 31) return 'mdy';
    try {
      const locale = document.documentElement.lang || navigator.language;
      const parts = new Intl.DateTimeFormat(locale || undefined).formatToParts(new Date(2026, 10, 22));
      return parts.findIndex(part => part.type === 'day') < parts.findIndex(part => part.type === 'month') ? 'dmy' : 'mdy';
    } catch { return 'mdy'; }
  }

  function senderPreference(messages, conversation) {
    const outgoing = [...new Set(messages.filter(message => message.direction === 'outgoing').map(message => message.sender).filter(Boolean))];
    if (outgoing.length === 1) return outgoing[0];
    let saved = null;
    try { saved = localStorage.getItem(`wa-readable-export-sender:${conversation}`); } catch {}
    // Initial preference comes from the sender selected in your screenshot.
    const preferred = saved ?? 'Robert B.';
    return messages.some(message => message.sender === preferred) &&
      !messages.some(message => message.sender === preferred && message.direction === 'incoming') ? preferred : '';
  }

  function messageDate(timestamp, order) {
    const parts = dateParts(timestamp);
    if (!parts) return null;
    const { a, b, c, iso } = parts;
    if (!iso && !order && a !== b && a <= 12 && b <= 12) return null;
    const resolvedOrder = order || (a > 12 ? 'dmy' : 'mdy');
    const year = iso ? a : c < 100 ? 2000 + c : c;
    const month = iso ? b : resolvedOrder === 'dmy' ? b : a;
    const day = iso ? c : resolvedOrder === 'dmy' ? a : b;
    const date = new Date(year, month - 1, day);
    return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day ? date : null;
  }

  function selectRange(messages, daysAgo, order, now) {
    if (daysAgo === 'all') return { messages, missingDates: 0, start: null, end: null };
    const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - Number(daysAgo));
    const end = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
    let missingDates = 0;
    const selected = messages.filter(message => {
      const date = messageDate(message.timestamp, order);
      if (!date) { missingDates++; return false; }
      return date >= start && date < end;
    });
    return { messages: selected, missingDates, start, end };
  }

  function confirmExport(messages, conversation, now) {
    const names = [...new Set(messages.map(message => message.sender).filter(Boolean))];
    const needsSender = messages.some(message => message.direction === 'unknown') && names.length;
    const order = automaticDateOrder(messages, now);
    const preferredSender = senderPreference(messages, conversation);
    return new Promise(resolve => {
      const dialog = document.createElement('dialog');
      dialog.style.cssText = 'background:#fff;color:#183c36;border:1px solid #c9decc;border-radius:18px;padding:28px;max-width:480px;width:calc(100% - 40px);max-height:85vh;overflow:auto;font:15px/1.6 system-ui;box-shadow:0 16px 60px #0005;';
      const selectStyle = 'display:block;width:100%;margin:8px 0 18px;padding:10px;font:inherit;color:#183c36;background:white;border:1px solid #b8cfc2;border-radius:8px';
      dialog.innerHTML = `<form method="dialog">
        <h2 style="margin:0 0 8px;font-size:22px">Export conversation</h2>
        <p style="margin:0 0 20px" dir="auto">${escape(conversation)}</p>
        <label for="wa-export-range">How much should I export?</label>
        <select id="wa-export-range" style="${selectStyle}">
          <option value="all">All loaded messages</option>
          <option value="0">Today only</option>
          <option value="1">Since yesterday — 2 calendar days</option>
          <option value="2">From 2 days ago — 3 calendar days</option>
          <option value="3">From 3 days ago — 4 calendar days</option>
          <option value="6">Last 7 calendar days</option>
        </select>
        ${needsSender ? `<label for="wa-export-own-sender">Which sender is you?</label>
        <select id="wa-export-own-sender" style="${selectStyle}">
          <option value="">My name is not listed / keep automatic detection</option>
          ${names.map((name, index) => `<option value="${index}"${name === preferredSender ? ' selected' : ''}>${escape(name)}</option>`).join('')}
        </select>` : ''}
        <label style="display:flex;align-items:center;gap:12px;margin:18px 0 4px;cursor:pointer">
          <input id="wa-export-include-details" type="checkbox" role="switch" style="width:20px;height:20px;accent-color:#146b50;flex-shrink:0">
          Include conversation details
        </label>
        <p style="margin:0 0 16px;font-size:12px;color:#526961">Off: messages only. On: add the conversation heading, export information, counts, and navigation.</p>
        <p id="wa-export-count" role="status" aria-live="polite" style="background:#e8f3ec;padding:12px 14px;border-radius:10px"></p>
        <p style="font-size:12px;color:#526961">Calendar days use this device’s local time. Only messages already loaded in the page can be exported. This does not load older history. Newest messages appear first.</p>
        <div style="display:flex;justify-content:flex-end;gap:12px">
          <button type="submit" value="cancel" style="padding:10px 16px;font:inherit">Cancel</button>
          <button id="wa-export-confirm" type="submit" value="export" style="padding:10px 16px;font:inherit;background:#146b50;color:white;border:0;border-radius:8px">Export</button>
        </div>
      </form>`;
      const rangeSelect = dialog.querySelector('#wa-export-range');
      const exportButton = dialog.querySelector('#wa-export-confirm');
      let choice;
      function updateCount() {
        const selection = selectRange(messages, rangeSelect.value, order, now);
        const count = selection.messages.length;
        const rangeLabel = rangeSelect.selectedOptions[0].textContent;
        const formatDate = date => date.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
        const windowLabel = selection.start ? `${formatDate(selection.start)} – ${formatDate(now)}` : 'All loaded dates';
        choice = { ...selection, rangeLabel, windowLabel, daysAgo: rangeSelect.value, order };
        exportButton.disabled = count === 0;
        exportButton.style.opacity = count ? '1' : '0.5';
        exportButton.textContent = `Export ${count} message${count === 1 ? '' : 's'}`;
        dialog.querySelector('#wa-export-count').textContent = `${count} of ${messages.length} loaded messages selected. ${windowLabel}.${selection.missingDates ? ` ${selection.missingDates} excluded because their dates could not be read.` : ''}${count === 0 ? ' Choose a wider range, or cancel and load messages from these dates in WhatsApp.' : ''}`;
      }
      rangeSelect.addEventListener('change', updateCount);
      dialog.querySelector('form').addEventListener('submit', event => {
        if (event.submitter?.value !== 'cancel' && (!choice || !choice.messages.length)) event.preventDefault();
      });
      dialog.addEventListener('close', () => {
        let result = null;
        if (dialog.returnValue === 'export' && choice?.messages.length) {
          const senderValue = dialog.querySelector('#wa-export-own-sender')?.value;
          const selectedName = senderValue !== undefined && senderValue !== '' ? names[Number(senderValue)] : '';
          if (senderValue !== undefined) {
            try {
              localStorage.setItem(`wa-readable-export-sender:${conversation}`, selectedName);
            } catch {}
          }
          if (selectedName) {
            for (const message of choice.messages) {
              if (message.direction === 'unknown' && message.sender) {
                message.direction = message.sender === selectedName ? 'outgoing' : 'incoming';
              }
            }
          }
          result = { ...choice, includeDetails: dialog.querySelector('#wa-export-include-details').checked };
        }
        dialog.remove();
        resolve(result);
      }, { once: true });
      updateCount();
      document.body.append(dialog);
      dialog.showModal();
    });
  }

  function snapshot(root) {
    const header = root.querySelector('header');
    const headerCopy = header?.cloneNode(true);
    headerCopy?.querySelector(`#${BUTTON_ID}`)?.remove();
    const conversation = [
      '[data-testid="conversation-info-header-chat-title"]',
      '[data-testid="conversation-info-header-chat-title"] span[title]',
      'span[title][dir="auto"]',
      'span[title]'
    ].map(selector => valueOf(header?.querySelector(selector))).find(Boolean) || 'Unknown conversation';
    // This may be group participants, a phone number, or a transient status.
    const headerDetails = [...new Set([
      ...Array.from(header?.querySelectorAll('span[title]') || [], valueOf),
      ...textOf(headerCopy).split('\n').map(value => value.trim())
    ].filter(value => value && value !== conversation))].join(' · ');

    const candidates = [...root.querySelectorAll(
      '.message-in, .message-out, [data-testid^="conv-msg-"]'
    )];
    let rows = outermost(candidates);
    if (!rows.length) {
      rows = outermost([...root.querySelectorAll('[data-pre-plain-text]')].map(element =>
        element.closest('[data-id]') || element));
      rows = [...new Set(rows)];
    }

    const messages = rows.map(row => {
      const metadataElement = row.matches('[data-pre-plain-text]')
        ? row : row.querySelector('[data-pre-plain-text]');
      const rawLabel = metadataElement?.getAttribute('data-pre-plain-text') || '';
      const metadata = readMetadata(rawLabel);
      const direction = detectDirection(row, root);
      const textElements = outermost([...row.querySelectorAll(
        '[data-testid~="selectable-text"], .selectable-text'
      )]);
      const thumbs = outermost([...row.querySelectorAll('[data-testid="image-thumb"]')]);
      return {
        ...metadata,
        direction,
        timeFallback: textOf(row.querySelector('[data-testid="msg-meta"]')),
        text: textElements.map(textOf).filter(Boolean).join('\n'),
        pictures: thumbs.map(thumb => [...new Set([...thumb.querySelectorAll('img')]
          .reverse().map(img => img.currentSrc || img.getAttribute('src'))
          .filter(src => src && /^(blob:|data:image\/)/i.test(src)))])
      };
    });
    return { conversation, headerDetails, messages };
  }

  const toDataURL = blob => new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error || new Error('Could not read image.'));
    reader.readAsDataURL(blob);
  });

  async function embedImage(candidates) {
    for (const src of candidates) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 10000);
      try {
        const response = await fetch(src, { signal: controller.signal });
        if (!response.ok) continue;
        const blob = await response.blob();
        if (!blob.type.startsWith('image/')) continue;
        return await toDataURL(blob);
      } catch {
        // Try the next available preview, then report an unavailable image.
      } finally {
        clearTimeout(timeout);
      }
    }
    return '';
  }

  async function exportChat(button) {
    const root = document.querySelector('#main');
    if (!root) throw new Error('Open a WhatsApp conversation first, then click Export chat.');
    // Snapshot all text and image URLs before asynchronous image work begins.
    const { conversation, headerDetails, messages: loadedMessages } = snapshot(root);
    if (!loadedMessages.length) throw new Error('No loaded messages found. WhatsApp’s page structure may have changed.');
    const exportedAt = new Date();
    const selection = await confirmExport(loadedMessages, conversation, exportedAt);
    if (!selection) return null;
    const { messages } = selection;
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'Local time';
    const exportLabel = exportedAt.toLocaleString(undefined, {
      year: 'numeric', month: 'short', day: 'numeric',
      hour: '2-digit', minute: '2-digit', second: '2-digit', timeZoneName: 'short'
    });
    const timestamps = messages.map(message => message.timestamp).filter(Boolean);
    const range = timestamps.length ? `${timestamps[0]} → ${timestamps[timestamps.length - 1]}` : 'Not available';
    const senders = [...new Set(messages.map(message => message.sender).filter(Boolean))];
    let saved = 0;
    let missing = 0;
    const articles = [];

    // WhatsApp's normal page order is oldest to newest. Reverse that order without
    // parsing locale-dependent dates, preserving the original message numbers.
    for (const [displayIndex, message] of [...messages].reverse().entries()) {
      const index = messages.length - 1 - displayIndex;
      button.textContent = `Exporting ${displayIndex + 1}/${messages.length}…`;
      const pictures = [];
      for (const candidates of message.pictures) {
        const dataURL = await embedImage(candidates);
        if (dataURL) {
          saved++;
          pictures.push(`<figure><a href="${escape(dataURL)}" target="_blank" rel="noopener"><img src="${escape(dataURL)}" alt="Image preview in message ${index + 1}" loading="lazy"></a><figcaption>Image preview · open to inspect</figcaption></figure>`);
        } else {
          missing++;
          pictures.push('<p class="unavailable">Image preview unavailable</p>');
        }
      }
      const sender = message.direction === 'outgoing' ? 'You' : message.sender || 'Sender unavailable';
      const stamp = message.timestamp || message.timeFallback || 'Time unavailable';
      articles.push(`<article class="message ${message.direction}" id="message-${index + 1}">
        <div class="message-heading"><strong dir="auto">${escape(sender)}</strong><a class="message-number" href="#message-${index + 1}" aria-label="Message ${index + 1}">#${index + 1}</a></div>
        <div class="message-time">${escape(stamp)}${message.direction === 'outgoing' ? ' · Sent' : message.direction === 'incoming' ? ' · Received' : ' · Direction unavailable'}</div>
        ${message.text ? `<p class="message-text" dir="auto">${escape(message.text)}</p>` : !pictures.length ? '<p class="unavailable">No extractable text or image preview. This may be an unsupported attachment or message type.</p>' : ''}
        ${pictures.join('\n')}
      </article>`);
    }

    const title = `${conversation} — WhatsApp — ${messages.length} messages — ${selection.rangeLabel} — newest first — ${range} — exported ${exportLabel}`;
    const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>${escape(title)}</title>
<style>
  :root { color-scheme: light; --ink:#183c36; --muted:#526961; --line:#d8e3dc; }
  * { box-sizing:border-box; }
  html { scroll-behavior:smooth; }
  body { margin:0; color:var(--ink); background:#f1f5f0; font:16px/1.65 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
  .page { max-width:1040px; margin:auto; padding:44px 24px 64px; }
  .eyebrow { text-transform:uppercase; letter-spacing:.16em; font-size:11px; font-weight:750; }
  .hero { background:#123d32; color:#f4fff7; padding:36px 40px; border-radius:22px 22px 0 0; }
  .hero .eyebrow { color:#acd5b9; }
  h1 { margin:10px 0 8px; font-size:clamp(27px,5vw,42px); line-height:1.2; letter-spacing:-.035em; overflow-wrap:anywhere; }
  .subtitle { margin:0; color:#d3e6d9; font-size:14px; overflow-wrap:anywhere; }
  .stats { display:flex; flex-wrap:wrap; gap:12px 30px; margin-top:28px; }
  .stat b { font-size:25px; line-height:1.2; display:block; }
  .stat span { color:#c6ded0; font-size:12px; }
  .metadata { background:white; padding:26px 40px; border:1px solid var(--line); border-top:0; border-radius:0 0 22px 22px; }
  dl { display:grid; grid-template-columns:145px minmax(0,1fr); gap:10px 22px; margin:0; font-size:13px; }
  dt { color:var(--muted); } dd { margin:0; overflow-wrap:anywhere; }
  .notice { margin:22px 0 0; padding:14px 16px; border-left:3px solid #b28733; background:#faf6e9; color:#665324; font-size:12px; }
  .toolbar { display:flex; flex-wrap:wrap; justify-content:space-between; align-items:center; gap:10px; margin:32px 0 20px; }
  h2 { margin:0; font-size:17px; } .toolbar nav { display:flex; gap:20px; font-size:12px; }
  a { color:inherit; text-underline-offset:3px; }
  .messages { display:flex; flex-direction:column; gap:18px; }
  .message { width:86%; padding:19px 24px; border:1px solid var(--line); border-radius:4px 18px 18px; background:white; box-shadow:0 2px 4px #183c3605; scroll-margin-top:20px; overflow-wrap:anywhere; }
  .message.outgoing { align-self:flex-end; background:#dcf0e2; border-color:#b3d5bf; border-right:4px solid #27805b; border-radius:18px 4px 18px 18px; }
  .message.unknown { align-self:center; }
  .message:target { outline:2px solid #438869; outline-offset:4px; }
  .message-heading { display:flex; justify-content:space-between; align-items:baseline; gap:16px; font-size:14px; }
  .message-number { font-size:11px; color:var(--muted); text-decoration:none; }
  .message-time { color:var(--muted); font-size:11px; margin-top:2px; }
  .message-text { white-space:pre-wrap; margin:13px 0 0; line-height:1.75; }
  figure { margin:16px 0 0; } figure a { display:block; }
  img { display:block; max-width:100%; max-height:680px; width:auto; height:auto; object-fit:contain; border-radius:10px; }
  figcaption { font-size:10px; color:var(--muted); margin-top:6px; }
  .unavailable { font-size:13px; font-style:italic; color:var(--muted); }
  footer { margin-top:32px; padding-top:20px; border-top:1px solid var(--line); font-size:11px; color:var(--muted); }
  @media(max-width:600px) { .page { padding:16px 12px 32px; } .hero,.metadata { padding:24px; } dl { grid-template-columns:1fr; gap:2px; } dd { margin-bottom:10px; } .message { width:95%; padding:16px 18px; } }
  @media print { body { background:white; font-size:11pt; } .page { max-width:none; padding:0; } .hero { background:white; color:#183c36; padding:20px 0; } .hero .eyebrow,.subtitle,.stat span { color:#526961; } .metadata { padding:16px; } .toolbar nav { display:none; } .message { box-shadow:none; break-inside:avoid; } img { max-height:170mm; } a { text-decoration:none; } }
</style></head><body><main class="page" id="top">
  ${selection.includeDetails ? `<header class="hero"><div class="eyebrow">WhatsApp / Conversation archive</div>
    <h1 dir="auto">${escape(conversation)}</h1>
    <p class="subtitle">Newest messages first · Loaded-message snapshot · ${escape(exportLabel)}</p>
    <div class="stats">
      <div class="stat"><b>${messages.length}</b><span>Messages</span></div>
      <div class="stat"><b>${saved}</b><span>Image previews saved</span></div>
      <div class="stat"><b>${missing}</b><span>Image previews unavailable</span></div>
      <div class="stat"><b>${senders.length}</b><span>Named senders found</span></div>
    </div>
  </header>
  <section class="metadata" aria-label="Export details"><dl>
    <dt>Conversation</dt><dd dir="auto">${escape(conversation)}</dd>
    ${headerDetails ? `<dt>Header at export</dt><dd dir="auto">${escape(headerDetails)}</dd>` : ''}
    <dt>First → last timestamp</dt><dd>${escape(range)}</dd>
    <dt>Selected range</dt><dd>${escape(selection.rangeLabel)} · ${escape(selection.windowLabel)}</dd>
    <dt>Loaded snapshot</dt><dd>${messages.length} selected from ${loadedMessages.length} loaded messages${selection.missingDates ? ` · ${selection.missingDates} excluded with unreadable dates` : ''}</dd>
    <dt>Reading order</dt><dd>Newest to oldest · Scroll down for earlier messages</dd>
    <dt>Exported</dt><dd>${escape(exportLabel)}</dd>
    <dt>Export time zone</dt><dd>${escape(timezone)}</dd>
    <dt>Exported (UTC)</dt><dd>${escape(exportedAt.toISOString())}</dd>
    <dt>Named senders found</dt><dd dir="auto">${escape(senders.join(' · ') || 'Not available')}</dd>
    <dt>Source</dt><dd>WhatsApp Web · web.whatsapp.com</dd>
  </dl><p class="notice"><strong>Snapshot scope.</strong> Only message elements present in the page when Export chat was clicked are included. This is not a full conversation backup. Dates are preserved as displayed by WhatsApp; the range uses the first and last available timestamps in page order. Named senders are not a full participant list. Images may be low-resolution previews. Videos, audio, documents, stickers, reactions, and other message details are not reliably captured.</p></section>
  <div class="toolbar"><h2>Conversation <span style="font-weight:400;color:var(--muted)">/ Newest first · ${messages.length} messages</span></h2>
    <nav aria-label="Jump to message"><a href="#message-${messages.length}">Newest message ↓</a><a href="#message-1">Oldest message ↓</a></nav>
  </div>` : ''}
  <section class="messages" aria-label="Messages">${articles.join('\n')}</section>
  ${selection.includeDetails ? '<footer>Local HTML export · Embedded image previews · Use your browser’s Find to search or Print to save a PDF. <a href="#top">Back to top ↑</a></footer>' : ''}
</main></body></html>`;

    const url = URL.createObjectURL(new Blob([html], { type: 'text/html;charset=utf-8' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = `WhatsApp_${safeFilename(conversation)}_${fileTimestamp(exportedAt)}_${messages.length}-messages.html`;
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    return `Exported ${messages.length} messages, ${saved} image previews; ${missing} unavailable.`;
  }

  const button = document.createElement('button');
  button.id = BUTTON_ID;
  button.type = 'button';
  button.textContent = 'Export chat';
  button.title = 'Export the current conversation’s loaded messages to an HTML file';
  // A normal toolbar item: no fixed coordinates or overlay on the messages.
  button.style.cssText = 'position:relative;flex:0 0 auto;align-self:center;margin-inline:8px 16px;white-space:nowrap;background:#146b50;color:white;border:1px solid #92c4ab;border-radius:999px;padding:8px 14px;font:600 13px system-ui;line-height:20px;cursor:pointer;';
  button.addEventListener('click', async event => {
    event.preventDefault();
    event.stopPropagation();
    if (button.disabled) return;
    button.disabled = true;
    button.textContent = 'Preparing export…';
    try {
      const result = await exportChat(button);
      if (!result) { button.textContent = 'Export cancelled'; return; }
      console.info(result);
      button.textContent = 'Export downloaded ✓';
      button.title = result;
    } catch (error) {
      console.error('WhatsApp export failed:', error);
      alert(`WhatsApp export failed: ${error.message || error}`);
      button.textContent = 'Export failed';
    } finally {
      setTimeout(() => {
        button.disabled = false;
        button.textContent = 'Export chat';
      }, 2500);
    }
  });
  function placeExportButton() {
    const header = document.querySelector('#main header');
    if (!header) {
      button.remove();
      return;
    }
    const actionSelector = 'button, [role="button"]';
    const actions = [...header.querySelectorAll(actionSelector)].filter(element => element !== button);
    const videoAction = actions.find(element =>
      /video/i.test(`${element.getAttribute('aria-label') || ''} ${element.getAttribute('title') || ''} ${element.getAttribute('data-testid') || ''}`) ||
      element.querySelector('[data-icon*="video" i], [data-testid*="video" i]'));
    const videoIcon = header.querySelector('[data-icon*="video" i], [data-testid*="video" i]');
    let anchor = videoAction || videoIcon?.closest(actionSelector);
    if (!anchor || !header.contains(anchor)) {
      // If video calling is unavailable, stay inside the header beside other actions.
      anchor = actions.find(element =>
        element.querySelector('[data-icon*="call" i], [data-icon*="search" i], [data-icon*="menu" i]') ||
        /call|search|menu/i.test(element.getAttribute('aria-label') || ''));
    }
    if (anchor) {
      // Step outside single-control wrappers so Export chat is a sibling in the
      // toolbar, never a child of the video button or its clickable wrapper.
      while (anchor.parentElement && anchor.parentElement !== header) {
        const parent = anchor.parentElement;
        const hasOtherAction = [...parent.querySelectorAll(actionSelector)].some(element =>
          element !== button && element !== anchor && !anchor.contains(element));
        if (hasOtherAction) break;
        anchor = parent;
      }
      if (button.parentElement !== anchor.parentElement || button.nextSibling !== anchor) {
        anchor.before(button);
      }
    } else if (button.parentElement !== header) {
      header.append(button);
    }
  }

  // WhatsApp replaces its header when switching chats or updating call controls.
  let placementQueued = false;
  const observer = new MutationObserver(() => {
    if (placementQueued) return;
    placementQueued = true;
    requestAnimationFrame(() => {
      placementQueued = false;
      placeExportButton();
    });
  });
  observer.observe(document.body, { childList: true, subtree: true });
  placeExportButton();
})();
