# MReader Icon Composer App Icon Design

## Goal

Replace MReader's current detailed raster icon with a clearer layered icon built in
Icon Composer. The new icon must remain recognizable at small sizes and support the
system default, dark, and monochrome appearances.

## Approved Direction

The approved design is **B2-B: Silver Glass, Balanced Proportions**.

The icon combines:

- a silver-blue glass background;
- a dark rounded book frame;
- a blue-to-purple open-book shape that also reads as the letter M;
- a small four-point sparkle in the upper-right area.

The design deliberately removes detailed manga panels. The simplified silhouette
must remain legible in the Home Screen, Settings, Spotlight, and notification-sized
presentations.

## Layer Structure

The Icon Composer document contains four independently positioned layers:

1. **Silver glass background**
   - cool silver-blue base;
   - restrained diagonal highlight from the upper-left;
   - no baked-in app-icon corner mask.
2. **Dark book frame**
   - balanced stroke weight;
   - centered with adequate safe-area margins;
   - provides the primary small-size silhouette.
3. **M-shaped book pages**
   - cyan/blue on the left and violet on the right;
   - shaped as an open book and a capital M;
   - slightly raised from the frame to create depth.
4. **Sparkle**
   - small four-point mark in the upper-right;
   - lower visual priority than the book;
   - subtle depth and highlight only.

## Appearance Variants

- **Default:** silver glass, charcoal frame, blue-violet pages.
- **Dark:** darker graphite glass, light frame, brighter blue-violet pages.
- **Monochrome/tinted:** preserve the book-frame and M-page silhouettes without
  depending on gradients for recognition.

## Composition

- Use the approved balanced B2-B proportions.
- The main frame occupies roughly two-thirds of the canvas.
- Maintain generous optical margins around the frame.
- The sparkle must not touch the icon crop or dominate the book.
- Do not pre-render rounded corners or a platform-specific outer mask.

## Project Integration

- Save the editable Icon Composer source inside the repository.
- Configure the Xcode project to use the composed icon.
- Preserve the current PNG temporarily as a source/reference asset until the new
  icon builds successfully.
- Do not modify unrelated application UI or behavior.

## Verification

1. Open the source successfully in Icon Composer.
2. Verify default, dark, and monochrome previews.
3. Inspect at both large preview and small Home Screen/Settings sizes.
4. Build the `mreader` scheme with `xcodebuild`.
5. Build against the connected device destination named `郑云凯`.
6. Confirm the build has no app-icon catalog errors.

