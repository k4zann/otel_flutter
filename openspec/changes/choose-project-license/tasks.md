## 1. Decide

- [x] 1.1 Owner chooses Apache-2.0, MIT or proprietary, plus the copyright holder name (person or company); verify the "Decision" line in proposal.md is filled in

## 2. Apply

- [x] 2.1 Replace `LICENSE` with the full license text and `Copyright 2026 <holder>`; verify the file no longer contains "TODO"
- [x] 2.2 If proprietary, keep `publish_to: none`; otherwise remove it and set `repository` / `homepage`. Verify `~/fvm/versions/3.44.2/bin/flutter pub publish --dry-run` reports no license or metadata errors (open-source only)
- [x] 2.3 Add a "License" section to README.md; verify it names the license and links `LICENSE`
- [x] 2.4 Confirm there is no third-party code needing attribution (`grep -ri "copyright" lib test example/lib backend` shows only the new holder); record the result here
  - Result (2026-10-12): no matches (grep exit 1). A broader search for `copyright|spdx|licensed under|all rights reserved|(c) <year>` over the same directories plus the plugin's `lib`, `test`, `android/src`, `ios` and `example/lib` also found nothing. No third-party code or notices, so no NOTICE file is needed; the only holder is the one in `LICENSE`.
- [x] 2.5 Apply the same license to `packages/otel_flutter_native` (`LICENSE`, README "License" section, `repository` / `homepage`; keep `publish_to: none` because of the path dependency); verify its `LICENSE` matches the root one and no longer contains "TODO"

## 3. Wrap-up

- [x] 3.1 Update AGENTS.md ("What this is": license status; remove this change from the backlog at archive); verify the text matches the chosen license
