## 1. Decide

- [ ] 1.1 Owner chooses Apache-2.0, MIT or proprietary, plus the copyright holder name (person or company); verify the "Decision" line in proposal.md is filled in

## 2. Apply

- [ ] 2.1 Replace `LICENSE` with the full license text and `Copyright 2026 <holder>`; verify the file no longer contains "TODO"
- [ ] 2.2 If proprietary, keep `publish_to: none`; otherwise remove it and set `repository` / `homepage`. Verify `~/fvm/versions/3.44.2/bin/flutter pub publish --dry-run` reports no license or metadata errors (open-source only)
- [ ] 2.3 Add a "License" section to README.md; verify it names the license and links `LICENSE`
- [ ] 2.4 Confirm there is no third-party code needing attribution (`grep -ri "copyright" lib test example/lib backend` shows only the new holder); record the result here

## 3. Wrap-up

- [ ] 3.1 Update AGENTS.md ("What this is": license status; remove this change from the backlog at archive); verify the text matches the chosen license
