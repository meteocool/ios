# Agents' notes

## Design: Apple's guidelines first

The native map (`meteocool/NativeMap/`) ports core's web frontend. Keep
core's behaviour, data and wording, but the look and feel may deviate from
core: where core's web design and Apple's Human Interface Guidelines
disagree, follow Apple. The app should feel like a modern iOS app, not a web
page in a frame.

Summary of the HIG as of iOS 26/27 (Liquid Glass), from
developer.apple.com/design/human-interface-guidelines (materials, sheets,
buttons, sliders, layout, color, typography, accessibility, motion, haptics,
maps) and "Adopting Liquid Glass":

### Layers and Liquid Glass
- Two layers: content (the map, the storm panel's body) and a functional
  layer of controls and navigation that floats above it in Liquid Glass.
- No Liquid Glass in the content layer. The one exception is a transient
  control (a slider's or toggle's knob) while it is being touched. In the
  content layer, use standard materials (ultraThin … thick) and vibrant
  semantic colours (`label`, `secondaryLabel`, `fill`, `secondaryFill`, …).
- Use glass sparingly, only on the most important controls. Don't stack
  glass on glass or crowd glass elements together.
- Prefer system components and styles, which adopt glass automatically:
  bars, sheets, popovers, menus, `Slider`, `Toggle`, `Picker`,
  `.buttonStyle(.glass)` / `.glassProminent`, `glassEffect(_:in:)`,
  `GlassEffectContainer`. Remove custom backgrounds from bars, sheets and
  popovers; they fight the system's glass and scroll-edge effects.
- Regular glass by default, especially over busy backgrounds or with a lot
  of text. Clear glass only over visually rich media. Over bright content it
  needs a dark dimming layer of about 35 %.
- Colour on glass is for emphasis only: a primary action or a status. Glass
  takes its colour from the content behind it.
- Rounded shapes are concentric with their container and the hardware
  (`ConcentricRectangle`, `containerShape`). Don't hard-code control
  metrics the system already provides.
- Respect the system's glass settings: Reduce Transparency, Increase
  Contrast, and the iOS 27 Liquid Glass opacity preference. Custom glass
  must look right under each.

### Sheets and panels
- On iPhone, a resizable sheet has a grabber, medium and large detents for
  progressive disclosure, and swipe to dismiss. It also has a Close button,
  because a gesture needs an onscreen alternative.
- Show one sheet at a time. Keep the selected thing on the map visible while
  its sheet or card is up.
- Half sheets are inset and let the map peek through. Keep content clear of
  the rounder corners. On iPad, prefer form or page sheets, or a floating
  panel.

### Controls
- Prefer system controls. Customise a control only when it adds value, as
  the cut dial does (an angle has no ends). A custom control still needs a
  press state, VoiceOver support and familiar directions.
- Hit regions are at least 44×44 pt. Leave about 12 pt around bezelled
  controls and about 24 pt around unbezelled ones.
- Mark the preferred choice with style (prominent vs. bordered), not size.
  Use SF Symbols for common actions, each with an accessibility label.
  Don't mix text and icons within one group.
- Use segmented controls for mutually exclusive modes and menus for longer
  lists. Toolbars group related items.

### Type, colour, layout
- Use system text styles (`.body`, `.subheadline`, `.footnote`, …) so
  Dynamic Type works, and check the largest accessibility sizes. Avoid fixed
  point sizes for text people read. Section headers use title-style
  capitalisation, never all caps.
- Use system and semantic colours, with light, dark and increased-contrast
  variants. Meet contrast minimums (WCAG/APCA) in both appearances, and
  don't convey anything by colour alone.
- Lay out by size class, not device type, and use safe areas and layout
  guides. Order content by importance, group related items, and use
  progressive disclosure.

### Motion and haptics
- Motion should be purposeful, brief and cancellable, and should follow the
  finger. Avoid animating frequent interactions. Honour Reduce Motion: a
  still alternative, never a broken one.
- Use system haptic patterns for their documented meaning, such as
  selection for detents and success or error for outcomes. Use them
  sparingly and always together with something visible.

### Maps
- The map stays interactive (pan, zoom, rotate). Mark the selected element
  clearly, and cluster overlapping annotations.
- Keep Apple's logo and legal link visible, padded from custom controls, and
  not moving with the interface.
- Make sure custom controls contrast enough with the map below them.

### Accessibility, always
- VoiceOver labels, values and adjustable actions on every custom control.
  Every gesture has an onscreen alternative. Support Voice Control, Switch
  Control and keyboard navigation through standard controls.
