## Summary

<!-- What changed and why. Keep it short. -->

## Test plan

- [ ] `swift test --package-path Packages/HushKit` passes
- [ ] App builds: `xcodegen generate && xcodebuild -project Hush.xcodeproj -scheme Hush -configuration Debug -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation build`
- [ ] Snapshots re-rendered (`--render-snapshots`) if UI changed
- [ ] No transcript text added to logs; no new network calls
