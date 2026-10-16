# Send to Riot Report from iPhone

An Apple Shortcut that appears in the iPhone share menu. Share an X post, a Safari page, or text, and it lands in the Story Queue.

The phone needs to reach the notes service: on home Wi-Fi directly, or from anywhere over your WireGuard connection to home.

## Before you start

1. **Service address.** This is the address of the machine running the notes service, on your home network, for example `http://192.168.10.50:3030`.
   - On the Mac: System Settings → Wi-Fi → Details → IP address, while you're connected to home Wi-Fi.
   - Use the IP address, not `something.local`. `.local` names don't resolve over WireGuard.
   - **Reserve that IP** in your router's DHCP settings (or Pi-hole's, if it does DHCP) so it doesn't change. Otherwise the Shortcut breaks whenever the Mac gets a new address.
   - When the service moves to the OptiPlex, use its address (`http://192.168.10.135:3030`) instead.
2. **Token.** The value of `NOTES_TOKEN` in the repo's `.env` file. The Shortcut uses this token instead of your login, so it never asks for a password.
3. **Quick check.** On the phone, open Safari to `http://<address>:3030` and log in with `NOTES_USER` / `NOTES_PASSWORD`. Let Safari save the password. You should see the Riot Report Inbox page. If you don't, fix that first: check the address, that WireGuard is connected, and that the service is running.
   - If you use a VPN on the Mac, make sure it allows local network (LAN) connections, or nothing on your network can reach the Mac.

## Build the Shortcut

In the **Shortcuts** app on the iPhone:

1. Tap **+** to create a new shortcut. Tap the name at the top and rename it **Send to Riot Report**. This name is what appears in the share menu and what you say to Siri.
2. In the same menu, choose **Choose Icon** and pick a glyph and color, for example the claret color with a microphone or soccer-ball icon.
3. Tap the **ⓘ** (Details) button:
   - Turn on **Show in Share Sheet**.
   - Back in the editor, tap the **Receive _Any_ input from Share Sheet** line at the top. Limit it to **URLs, Text, Safari web pages** so the shortcut only shows up where it makes sense.
   - Set **If there's no input** to **Ask For → Text**. Then running the shortcut from the Home Screen or Siri asks you for a note.
4. Add the action **Get Contents of URL** and configure it:
   - URL: `http://<address>:3030/api/items`
   - Tap **Show More**.
   - Method: **POST**
   - Headers: add `Authorization` with the value `Bearer <your token>`. There's a single space after `Bearer`.
   - Request Body: **JSON**. Add a field: key `input`, type **Text**, value **Shortcut Input** (pick it from the variables bar).
5. Add **Get Dictionary Value**. Set it to get **Value** for key `title` in **Contents of URL**.
6. Add **Show Notification**. Set the text to `Added: ` followed by the **Dictionary Value** variable.

Done. In X, tap **Share → Send to Riot Report**. You'll see "Added: Real Salt Lake (@realsaltlake)", and within a minute the post is in the Mac app's Story Queue. Click the refresh button in the queue's header to see it immediately.

## Making it yours

- **Position in the share menu:** in any share sheet, scroll the app/action row to the end → **Edit Actions** → add it to **Favorites** and drag it to the top.
- **Siri:** say "Send to Riot Report" and dictate a note.
- **Action Button / Back Tap:** Settings → Action Button (iPhone 15 Pro and later), or Settings → Accessibility → Touch → Back Tap, and pick the shortcut. Useful for quick voice notes during a match.
- **A dedicated "quick note" shortcut:** duplicate the shortcut, rename it **Riot Note**, and put **Dictate Text** at the top. Use **Dictated Text** as the `input` value, then add it to your Home Screen.
- **Inbox page on the Home Screen:** open `http://<address>:3030` in Safari → Share → **Add to Home Screen**. It works like a small app for reviewing or deleting what's queued.

## What gets created

The service decides from what you send:

| You share | Becomes |
|---|---|
| An X post link, even with text around it | **X post**: author, handle, post text and date, using X's public embed feature (oEmbed) |
| Any other link | **Article**: page title, summary, site name and image. If the site blocks the fetch, the link is still saved. |
| Anything else | **Note**: the first line becomes the title |

Sharing a link that's already saved doesn't create a duplicate. If the link was already used in a project, it goes back into the queue.
