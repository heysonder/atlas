# Atlas design principles

Simple rule: **be as native as possible.**

## Language

- Swift, modern Swift.
- SwiftUI first for everything.
- UIKit / AVKit when SwiftUI can't do it (video transport, some presentation and focus behavior). Wrapping UIKit in a `UIViewRepresentable` is normal and fine, not a failure.

## Components

- Use Apple's components. `NavigationStack`, `List`, `TabView`, `.searchable`, `.sheet`, `AVPlayerViewController`, SF Symbols, system materials, system colors.
- Don't rebuild a control that already ships with the OS. No custom tab bars, custom sliders, custom nav bars, custom scroll views, custom video transport rows.
- Build something custom only when the platform genuinely has no answer — and when you do, keep it small and make it look and behave like the system control it sits next to.

## Look and feel

- Adopt whatever the current OS gives us: Liquid Glass, new materials, new layout behavior. Track the platform; don't freeze a look.
- No hardcoded colors or fonts when a semantic one exists (`.primary`, `.secondary`, `.tint`, `.body`, `.headline`).
- Layout adapts to available width, not to size classes or device names.

## Behavior

- Let the frameworks do their job. AVPlayer picks its own bitrate. `List` handles its own recycling. Don't second-guess with caps and manual tuning unless there's a measured problem.
- Follow the platform's conventions for gestures, navigation depth, and where controls live. Users already know them.

## When in doubt

Ask: "would Apple ship this control, or did I invent it?"

Then go look it up rather than guessing — the APIs move faster than any model's training data.

Use current, official Apple documentation as the authority for exact API
signatures, availability, platform differences, and interaction guidance:

- [SwiftUI documentation](https://developer.apple.com/documentation/swiftui)
  for implementation APIs.
- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
  for platform conventions, components, and interaction patterns.
- [Apple Design Resources](https://developer.apple.com/design/resources/)
  for current visual-system and icon guidance.
- [The Swift Programming Language](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/)
  for language behavior.

Treat summaries and search results as discovery aids. Confirm the actual Apple
or Swift documentation before turning guidance into a rule.
