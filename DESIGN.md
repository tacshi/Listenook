# Listenook design

Listenook is a quiet reading-and-listening tool. The transcript is the
product; everything else gets out of its way.

## Structure

A recording lives in one place. The Library lists every recording whatever
its state (not transcribed, transcribing, ready); "In progress", groups and
tags are filters in the sidebar, not other lists. Opening a recording covers
the list with the reader, and Back returns. Podcasts is for finding and
following shows; an episode sent to the Library is a recording like any
other.

The Library syncs with another device on the same network from its top bar:
one dialog chooses the device and follows the sync, and the other device
asks its user before anything is copied. Both Libraries end as their union;
whether this device can be found is set in that dialog, where it matters.

The reader has one transport and one side panel showing one thing at a time:
Practice (mimic or dictation), the AI Brief, or the video. A setting is made
where it is used: how to transcribe in the Library's options, what a
transcript shows in the reader's menu, accounts and defaults in Settings.

## Targets

Desktop first (macOS, then Windows and Linux): pointer and keyboard, 32pt
controls, a persistent sidebar, anchored menus, centered dialogs. The layout
holds from 760pt wide; the reader's side panel is 400pt.

## Visual language

Neutral paper and ink with one violet accent (`primary`). Flat surfaces
separated by hairlines; shadows only on what floats (menus, dialogs, toasts).

| Token | Role |
| --- | --- |
| `background`, `foreground` | The page and its text |
| `card`, `popover`, `sidebar` | Their surfaces |
| `muted`, `muted-foreground` | Supporting regions and text |
| `primary` (+ `-hover`, `-active`) | The default commit, the play button, selection emphasis |
| `hover` | The wash under the pointer, weaker than a selection |
| `accent` | Selected rows and open triggers |
| `control-border` | The edge of fields, selects and checkboxes (3:1 against the page) |
| `destructive` | Destructive actions and errors |
| `success`, `warning` | A finished job, a job that needs attention |
| `highlight`, `highlight-foreground` | The sentence being played |
| `scrim` | The layer behind a dialog |

Colors live in `theme.json` and are read through `nsh_base::theme()` and
`src/ui/tokens.rs`. No color literal appears in page or component code.

- **Radius:** `radius` 8 for controls and popups, `radius-sm` 6 for small
  parts (badges, checkboxes, inset rows), `radius-lg` 12 for cards and
  dialogs. Full circles only for status dots, switch thumbs and artwork-less
  avatars.
- **Type:** the platform UI font. `text-lg` page titles, `text-lg`
  transcript text, `text-sm` interface text, `text-xs` metadata. Two weights:
  regular and medium/semibold. Times use tabular figures.
- **Spacing:** Tailwind's 4pt scale. 24pt page inset shared by every region
  of a page (`ui::PAGE_INSET`); 4 / 8 / 12 / 16 / 24 for parts of a control,
  related controls, one group, groups in a section, sections.
- **Density:** medium. On a computer controls are 32pt (28pt small) and
  fields and selects share those heights; on a phone or tablet 40pt (32pt
  small). Rows 32–60pt.
- **Icons:** Lucide outlines, 1.75 stroke, 16pt in controls (14pt small;
  18–20pt under a finger).
- **Focus:** the keyboard's ring (`focus_visible`) on every control, outside
  its edge; a field's own edge turns `ring` on any focus.

## The `ui` layer

`src/ui/` is the only place `nsh_base` controls are styled. Pages compose:

| Component | Variants and states |
| --- | --- |
| `button`, `icon_text_button`, `icon_button`, `icon_button_as`, `toggle_icon_button` | Primary, Default, Outline, Ghost, Picture (over a video) × Sm, Md; hover, pressed (scale 0.97 / 0.94), focus ring, disabled |
| `toggle_button` | An icon button that is on or off (a side panel, repeat): tinted and announced as selected while on |
| `menu_trigger` | The square button a menu or popover opens from; pressed while it is open |
| `text_field`, `bound_field`, `text_area`, `search_field`, `field`, `hint` | One look: `control-border` edge on `card`, focus edge, placeholder |
| `switch`, `checkbox`, `select`, `segmented`, `slider`, `progress_bar` | Checked, disabled, indeterminate |
| `menu`, `menu_with`, `context_menu`, `menu_action`, `menu_choice`, `menu_danger`, `menu_toggle`, `menu_divider` | One popup surface (`tokens::popup_surface`) |
| `modal`, `modal_actions`, `confirm_destructive` | Centered dialog; the system's alert for confirmations |
| `toast`, `toast_host` | Info, Success, Error |
| `page_header`, `card`, `section`, `separator`, `list_row`, `badge`, `empty_state`, `spinner`, `key_cap` | |

A look a page needs becomes a variant here first.

## Motion tokens

`tokens::motion`: `INSTANT` 120ms (hover washes, colors), `FAST` 180ms
(presses, control state), `BASE` 240ms (a selection moving, a popup leaving). Pressed buttons scale to 0.97, icon buttons to 0.94.
With reduced motion, presses do not scale, entrances land at once
(`Motion::play` does this itself) and lists jump instead of scrolling.

## Motion inventory

### Shell

| Change | Motion | Reduced |
| --- | --- | --- |
| Hover / press on a sidebar row | Wash in `INSTANT`; deeper wash on press | Instant |
| Current place or filter changes | The row's fill cross-fades, `INSTANT` | Instant |
| Page changes | The new page fades in (sibling sections cross-fade) | Instant |
| Podcast starts playing | The mini player rises in from the bottom edge | Appears |
| Play ↔ pause | Glyph swap on the button; the button presses to 0.94 | No scale |
| A toast arrives / leaves | Rises 16pt and fades in, `BASE`; fades and shrinks out | Instant |

### Library

| Change | Motion | Reduced |
| --- | --- | --- |
| A job is added | Its card rises in | Appears |
| A job's status changes | The status dot's color cross-fades, `BASE`; the glyph swaps | Instant |
| Work runs | The progress bar's fill glides between values, `BASE`; indeterminate while the length is unknown | Static bar |
| Row menu opens | Grows from 0.95 and fades, 200ms; leaves in 150ms; its button stays pressed while it is open | Instant |
| Empty Library | The empty state fades in | Appears |

### Reader

| Change | Motion | Reduced |
| --- | --- | --- |
| The played sentence changes | The highlight fill cross-fades between rows, `BASE`; the list scrolls it to a third of the way down | Jumps |
| Hover on a sentence | Wash `INSTANT`; its commands fade in, `INSTANT` (they are also on its context menu and on E / R) | Instant |
| Sentence menu opens (secondary click) | As a row menu | Instant |
| Words selected in a sentence | The platform's selection; a Bold toggle fades in among the sentence's own commands, `INSTANT`, tinted while the selected words are bold. Highlighted words turn bold at once (also from the sentence menu and ⌘B) | Instant |
| Full screen | The transport turns light on the picture; it fades out while playing and back on pointer movement, `BASE` | Instant |
| Repeat on / off | The repeat button's tint cross-fades, `FAST` | Instant |
| A side panel opens or changes | Its toolbar toggle's fill cross-fades, `FAST`; the panel takes its width at once | Instant |
| Position | No motion: the slider follows playback 10 times a second and the thumb 1:1 while dragged | — |
| Search opens | The search bar drops in from the header | Appears |
| Dictation checked | Right: the verdict rises in. Wrong: it shakes once | Appears |
| Mimic between passes | The reps badge turns to the accent while it is the user's turn | Same |
| AI Brief generating | Progress bar, indeterminate for a single request | Static |
| Evidence chip pressed | Wash; the transcript scrolls to the sentence | Jumps |

### Sync

| Change | Motion | Reduced |
| --- | --- | --- |
| The Sync dialog or a sync request opens | As every dialog: fades in whole, the card rising a little | Appears |
| A device is found | Its row rises in | Appears |
| Looking for devices | A spinner beside the hint while none is listed | Static glyph |
| Visible on / off | The switch as in Settings; the name field appears under it without motion | Instant |
| Waiting for the other device | Progress bar, indeterminate | Static bar |
| Copying | The bar's fill glides between values, `BASE`; the counts change in place | Static bar |
| The sync ends | The dialog's content swaps to the result, which rises in; a toast on the device that answered | Appears |

### Podcast

| Change | Motion | Reduced |
| --- | --- | --- |
| Featured shows arrive | Cards rise in | Appear |
| Hover / press on a card or row | Wash `INSTANT`; deeper on press | Instant |
| Searching | A spinner while the first results load; results replace it without motion (they change per keystroke) | Static glyph |
| An episode plays | Its row takes the highlight fill, `INSTANT`; play ↔ pause glyph swap | Instant |

### Settings

| Change | Motion | Reduced |
| --- | --- | --- |
| Tab changes | The segmented indicator slides; the panel swaps without motion (its content is already there) | Jumps |
| A switch flips | The thumb slides and the track's color cross-fades, `FAST` | Instant |
| Theme changes | Colors follow the theme natively | Same |
