# WhatsApp readable chat export

Personal Tampermonkey userscript for WhatsApp Web. Version `2026.11.07.7`.

Exports messages currently loaded in the conversation to a standalone HTML file with embedded available image previews. No build step or external libraries are required.

## Install

1. Create a new script in Tampermonkey.
2. Replace its contents with `whatsapp-export.user.js` and save.
3. Reload WhatsApp Web and open a conversation.
4. Click **Export chat** in the header, before the video call button.

Replace the existing installed script when upgrading; do not enable multiple copies.

## Export options

- Range: all loaded messages, today, since yesterday, from two or three days ago, or the last seven calendar days. Ranges include today and use the device’s local timezone.
- The dialog previews how many loaded messages match. Messages with unreadable dates are excluded from bounded ranges and reported in the count.
- Date format is automatic, using unambiguous dates, chronological context, recency, and page/browser locale. Fully ambiguous dates remain a best-effort interpretation; inspect the displayed calendar range.
- When needed, the sender choice is prefilled from outgoing messages, a saved choice for that conversation, or the personal initial preference `Robert B.`. Change it in the dialog if necessary. A choice confirmed by exporting is stored in the browser’s local storage.
- **Include conversation details** defaults to off. Off produces only message bubbles. On adds the conversation heading, export metadata, counts, navigation, and footer.

## Output

Messages appear newest first. Your messages are labeled **You** and aligned right in green; other senders appear on the left. Original raw message labels are not included. The filename and browser document title contain conversation/export information even when the visible details section is off.

The HTML works offline and supports browser Find and Print. Message text is escaped before it is inserted into HTML.

## Limits

Only message elements present in WhatsApp’s page when Export chat is clicked are captured. Selecting a date range does not load earlier history. Images may be low-resolution previews. Videos, audio, documents, stickers, reactions, and other details are not reliably captured. WhatsApp markup changes can require updates to the selectors.

The script reads the page and available local blob/data image URLs; it does not upload exports. Exported files contain conversation content and any captured images.

## Validation

```sh
node --check whatsapp-export.user.js
```

During development, sample-browser checks covered toolbar insertion and recovery when switching chats, sender selection/persistence, date filtering, newest-first output, escaping, and details on/off. Date checks also covered calendar boundaries and daylight-saving changes. These checks used fictional conversations and are not a guarantee of compatibility with every live WhatsApp layout.
