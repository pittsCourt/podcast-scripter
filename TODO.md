# To do

Things we've decided to tackle later. Newest decisions at the top of each section.

## Next up

### Back up the Newsdesk database (OptiPlex)
Newsdesk's database (inbox and history, news, power-ranking history, project settings) lives only on the OptiPlex's disk, in `services/newsdesk/data/notes.db`.

- [ ] Put `newsdesk-backup.sh` in the server's backup-scripts folder. It makes a safe copy while Newsdesk runs, checks it, saves `newsdesk-YYYY-MM-DD_HHMM.db.gz` and keeps 30 days.
- [ ] Set `NEWSDESK_DIR` to the absolute path of `services/newsdesk`, and pass the RAID folder as the argument
- [ ] Run it once by hand and check the "saved …" line. The path for when Newsdesk is running (copying from inside the container) hasn't been tested yet.
- [ ] Add the nightly cron job (e.g. `15 3 * * *`). Make sure the cron user can run Docker.
- [ ] Decide whether to also back up `.env` (`INCLUDE_ENV=1`). It holds the passwords and keys.
- [ ] Test a restore: unzip a backup over `data/notes.db` on a copy and open it.

### Back up the Mac app's data
Scripts and the Story Tracker live only in `~/Library/Application Support/PodcastScripter/data.json` on the MacBook.

- [ ] Either confirm Time Machine covers it, or move the app's data to iCloud Drive. That's a small app change and would also make it available on another Mac.

### Clean up after moving Newsdesk to the OptiPlex
- [ ] OptiPlex: delete `services/newsdesk/newsdesk-from-mac.db`, and later the `services/newsdesk/backups/` folder
- [ ] Mac: once the OptiPlex backups are running, decide whether to keep the old copy in `services/newsdesk/data/`. Don't start Newsdesk on the Mac again.
- [ ] Reserve the OptiPlex's address (`192.168.10.135`) in the router or Pi-hole, so the app and the Shortcut keep finding it

## Open questions
- [ ] iPhone share sheet: the share options looked "huge" after setting up Send to Newsdesk. Not yet diagnosed; check Display Zoom and Larger Text first.

## Ideas for later
- [ ] **Search script titles and content properly.** The home search already filters the Scripts list by title and text. It doesn't yet show the matching passage (with the words highlighted), open the script at the match, work from the editor, or search across projects. Tracked-story mentions and resolution notes could be included too.
- [ ] **Gemma: quote-backed answers.** Each claim quotes its source passage, and the app flags quotes that aren't actually in your scripts.
- [ ] **Gemma: meaning-based search.** Gemini embeddings, so "the keeper" finds passages about the goalkeeper by name.
- [ ] **Full article text:** save the readable text of shared articles, so Gemma can answer from them and the reader works offline.
- [ ] **Editor:** bulleted and numbered lists.
- [ ] **Newsdesk image on GitHub's registry (ghcr.io),** for Intel and ARM, so a server can update with `docker compose pull` instead of building.
- [ ] **Power rankings:** the Opta reader depends on how Opta's page is built and is the most likely to break. Consider a fallback.
